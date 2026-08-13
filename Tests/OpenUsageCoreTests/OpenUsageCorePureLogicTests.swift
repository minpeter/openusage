import Foundation
import OpenUsageCore
import Testing

@Suite("OpenUsageCore pricing")
struct OpenUsageCorePricingTests {
    @Test("token cost includes input output cache and reasoning rates")
    func tokenCost() {
        let rates = ModelRates(
            inputPerMillion: 2,
            outputPerMillion: 8,
            cacheWritePerMillion: 1,
            cacheReadPerMillion: 1)
        let tokens = TokenBreakdown(
            input: 1_000_000,
            cacheWrite5m: 0,
            cacheWrite1h: 0,
            cacheRead: 1_000_000,
            output: 500_000,
            isFast: false)

        #expect(rates.costDollars(for: tokens) == 7)
    }
}

@Suite("OpenUsageCore analytics")
struct OpenUsageCoreAnalyticsTests {
    @Test("provider shares are ranked and normalized")
    func providerShares() {
        let records = [
            ProviderSpendRecord(
                providerID: "claude",
                providerName: "Claude",
                period: .today,
                cost: 6,
                tokens: 3_000_000),
            ProviderSpendRecord(
                providerID: "codex",
                providerName: "Codex",
                period: .today,
                cost: 4,
                tokens: 2_000_000),
        ]

        let projection = TotalSpendAnalytics.project(
            records: records,
            metric: .cost,
            period: .today)

        #expect(projection.total == 10)
        #expect(projection.slices.map(\.providerID) == ["claude", "codex"])
        #expect(projection.slices.map(\.wholePercent) == [60, 40])
    }
}

@Suite("OpenUsageCore export")
struct OpenUsageCoreExportTests {
    @Test("JSON round-trip preserves provider snapshots")
    func roundTrip() throws {
        let service = UsageExportService(maximumImportBytes: 1_024)
        let snapshot = ProviderUsageSnapshot(
            providerID: "codex",
            displayName: "Codex",
            plan: "Pro",
            metrics: [],
            refreshedAt: Date(timeIntervalSince1970: 1_700_000_000))

        let data = try service.encode([snapshot], format: .json)
        #expect(try service.decodeJSON(data) == [snapshot])
    }

    @Test("oversized imports fail before decoding")
    func oversizedImport() {
        let service = UsageExportService(maximumImportBytes: 4)

        #expect(throws: UsageImportError.fileTooLarge(maximumBytes: 4)) {
            try service.decodeJSON(Data(repeating: 0, count: 5))
        }
    }
}

@Suite("OpenUsageCore notification policy")
struct OpenUsageCoreNotificationTests {
    @Test("almost-out transition fires only on threshold crossing")
    func thresholdCrossing() {
        let first = UsageThresholdNotificationPolicy.transitions(
            bucket: .healthy,
            remainingFraction: 0.11,
            resetsAt: nil,
            previous: .init(),
            toggles: .allEnabled)
        let crossed = UsageThresholdNotificationPolicy.transitions(
            bucket: .healthy,
            remainingFraction: 0.09,
            resetsAt: nil,
            previous: first.state,
            toggles: .allEnabled)

        #expect(first.milestones.isEmpty)
        #expect(crossed.milestones == [.almostOut])
    }
}

@Suite("OpenUsageCore provider parser")
struct OpenUsageCoreProviderParserTests {
    @Test("delimited usage parser rejects malformed numeric input")
    func malformedInput() {
        #expect(throws: DelimitedUsageParser.Error.invalidNumber("oops")) {
            try DelimitedUsageParser.parse("tokens,cost\n100,1.25\n200,oops\n")
        }
    }

    @Test("delimited usage parser returns typed rows")
    func validInput() throws {
        let rows = try DelimitedUsageParser.parse(
            "tokens,cost\n100,1.25\n200,2.75\n")

        #expect(rows == [
            .init(tokens: 100, cost: 1.25),
            .init(tokens: 200, cost: 2.75),
        ])
    }
}
