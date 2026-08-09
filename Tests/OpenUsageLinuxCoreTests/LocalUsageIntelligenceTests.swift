import Foundation
import Testing
@testable import OpenUsageLinuxCore

@Suite("Linux local usage intelligence")
struct LocalUsageIntelligenceTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    @Test("Bundled pricing preserves aliases, exact precedence, and finite costs")
    func bundledPricingResolution() throws {
        let pricing = try ModelPricing.bundled()
        let canonical = try #require(pricing.supplement.canonicalName(for: "claude-4.6-opus-max-thinking"))
        let rates = try #require(pricing.resolve(model: canonical))
        let cost = rates.costDollars(for: TokenBreakdown(input: 1_000, cacheRead: 500, output: 250))

        #expect(!pricing.primary.entries.isEmpty)
        #expect(!pricing.secondary.entries.isEmpty)
        #expect(cost.isFinite && cost > 0)
        #expect(pricing.resolve(model: "definitely-not-a-real-model") == nil)
    }

    @Test("Claude scanner deduplicates replayed messages and uses carried or model cost")
    func claudeScannerParity() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appendingPathComponent("projects/work", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let fixture = [
            claudeLine(timestamp: "2026-08-09T10:00:00Z", message: "shared", request: "parent", input: 100, output: 50, cost: 0.25),
            claudeLine(timestamp: "2026-08-09T10:00:00Z", message: "shared", request: "replay", input: 90_000, output: 10, cost: 9.99, sidechain: true),
            claudeLine(timestamp: "2026-08-08T10:00:00Z", message: "priced", request: "priced", input: 1_000, output: 500, model: "claude-test"),
        ].joined(separator: "\n")
        try Data(fixture.utf8).write(to: projects.appendingPathComponent("session.jsonl"))
        let pricing = fixturePricing()

        let scan = try ClaudeLocalLogScanner().scan(
            configDirectories: [root],
            now: date("2026-08-09T12:00:00Z"),
            pricing: pricing,
            calendar: calendar
        )

        #expect(scan?.daily.map(\.totalTokens) == [150, 1_500])
        #expect(scan?.daily[0].costUSD == 0.25)
        #expect(abs((scan?.daily[1].costUSD ?? 0) - 0.02) < 0.000_000_001)
    }

    @Test("Codex scanner tracks model, cumulative deltas, stale snapshots, and copied events")
    func codexScannerParity() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let first = [
            #"{"timestamp":"2026-08-09T08:00:00Z","type":"turn_context","payload":{"model":"gpt-test"}}"#,
            codexCount("2026-08-09T08:01:00Z", input: 1_000, cached: 100, output: 200, totalInput: 1_000, totalOutput: 200),
            codexCount("2026-08-09T08:02:00Z", input: 1_000, cached: 100, output: 200, totalInput: 1_000, totalOutput: 200),
            codexCount("2026-08-09T08:03:00Z", input: 500, cached: 50, output: 100, totalInput: 1_500, totalOutput: 300),
        ].joined(separator: "\n")
        try Data(first.utf8).write(to: sessions.appendingPathComponent("rollout.jsonl"))
        try Data(first.utf8).write(to: sessions.appendingPathComponent("copied.jsonl"))

        let scan = try CodexLocalLogScanner().scan(
            homes: [root], now: date("2026-08-09T12:00:00Z"), pricing: fixturePricing(), calendar: calendar
        )

        #expect(scan?.daily.count == 1)
        #expect(scan?.daily.first?.totalTokens == 1_800)
        #expect(scan?.daily.first?.costUSD.isFinite == true)
    }

    @Test("Spend periods and daily history are bounded, finite, calendar-true, and mergeable")
    func boundedSpendAndHistory() {
        let now = date("2026-08-09T12:00:00Z")
        var days: [LocalUsageDay] = []
        for offset in 0..<80 {
            let day = calendar.date(byAdding: .day, value: -offset, to: now)!
            days.append(LocalUsageDay(date: LocalUsageHistory.dayKey(day, calendar: calendar), totalTokens: offset == 2 ? -5 : 100,
                                      costUSD: offset == 3 ? .infinity : 1))
        }
        let merged = LocalUsageHistory.merge([
            LocalUsageScan(daily: days, unknownModelsByDay: [:]),
            LocalUsageScan(daily: [LocalUsageDay(date: "2026-08-09", totalTokens: 50, costUSD: 0.5)], unknownModelsByDay: [:]),
        ], now: now, calendar: calendar)
        let metrics = LocalSpendAggregator.metrics(from: merged, now: now, calendar: calendar)
        let chart = metrics.first { $0.kind == .chart }

        #expect(merged.daily.count == 31)
        #expect(merged.daily.first?.totalTokens == 150)
        #expect(metrics.first { $0.label == "Today" }?.values == [
            UsageValue(label: "", value: 1.5, unit: .dollars),
            UsageValue(label: "tokens", value: 150, unit: .tokens),
        ])
        #expect(chart?.points?.count == 31)
        #expect(chart?.points?.allSatisfy { $0.value.isFinite && $0.value >= 0 } == true)
        #expect(metrics.allSatisfy { $0.used.isFinite && ($0.values ?? []).allSatisfy { $0.value.isFinite } })
    }

    @Test("Scanner rejects a JSONL record over the response-sized line budget")
    func boundedLineMemory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appendingPathComponent("projects/work", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try Data(repeating: UInt8(ascii: "x"), count: 512 * 1_024 + 1)
            .write(to: projects.appendingPathComponent("oversized.jsonl"))

        #expect(throws: LocalLogScanError.lineTooLarge(maximumBytes: 512 * 1_024)) {
            _ = try ClaudeLocalLogScanner().scan(configDirectories: [root], pricing: fixturePricing())
        }
    }

    private func fixturePricing() -> ModelPricing {
        ModelPricing(
            supplement: PricingSupplement(),
            primary: PricingCatalog(entries: [
                "claude-test": ModelRates(inputPerMillion: 10, outputPerMillion: 20,
                    cacheWritePerMillion: 12.5, cacheReadPerMillion: 1),
                "gpt-test": ModelRates(inputPerMillion: 10, outputPerMillion: 20,
                    cacheWritePerMillion: 10, cacheReadPerMillion: 1),
            ]), secondary: PricingCatalog()
        )
    }

    private func claudeLine(timestamp: String, message: String, request: String, input: Int, output: Int,
                            cost: Double? = nil, model: String = "claude-test", sidechain: Bool = false) -> String {
        let carried = cost.map { ",\"costUSD\":\($0)" } ?? ""
        return "{\"timestamp\":\"\(timestamp)\",\"requestId\":\"\(request)\",\"isSidechain\":\(sidechain)\(carried),\"message\":{\"id\":\"\(message)\",\"model\":\"\(model)\",\"usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output)}}}"
    }

    private func codexCount(_ timestamp: String, input: Int, cached: Int, output: Int,
                            totalInput: Int, totalOutput: Int) -> String {
        #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output)},"total_token_usage":{"input_tokens":\#(totalInput),"cached_input_tokens":\#(cached),"output_tokens":\#(totalOutput)}}}}"#
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
