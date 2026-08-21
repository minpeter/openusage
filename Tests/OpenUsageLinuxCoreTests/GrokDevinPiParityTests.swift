import Foundation
import Testing
@testable import OpenUsageLinuxCore

@Suite("Grok, Devin, and Pi Linux parity")
struct GrokDevinPiParityTests {
    private let now = Date(timeIntervalSince1970: 1_783_510_400) // 2026-07-08T12:00:00Z

    @Test("Grok discovers Linux auth, identity, remote metrics, links, and widgets")
    func grokParity() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let authURL = root.appendingPathComponent(".grok/auth.json")
        try write(
            """
            {"https://auth.x.ai::client":{"key":"access-token","refresh_token":"refresh-token",\
            "id_token":"\(jwt(email: "grok@example.com"))","expires_at":"2026-08-01T00:00:00Z"}}
            """,
            to: authURL
        )
        let store = GrokLinuxCredentialStore(environment: ["HOME": root.path])
        let auth = try #require(try store.loadCandidates().first)
        #expect(auth.accountLabel == "grok@example.com")
        #expect(auth.instanceID.hasPrefix("grok:"))

        let payload = Data("""
        {"config":{"creditUsagePercent":99.0,"currentPeriod":{
          "type":"USAGE_PERIOD_TYPE_WEEKLY",
          "start":"2026-06-30T21:36:52.140114+00:00",
          "end":"2026-07-07T21:36:52.140114+00:00"},
          "onDemandCap":{"val":2500}}}
        """.utf8)
        let snapshot = try GrokLinuxMapper.mapCredits(
            data: payload,
            auth: auth,
            plan: "SuperGrok Heavy",
            now: now
        )

        #expect(snapshot.accountLabel == "grok@example.com")
        #expect(snapshot.plan == "SuperGrok Heavy")
        #expect(snapshot.metrics.map(\.label) == ["Weekly limit", "Pay as you go"])
        #expect(snapshot.metrics[0].used == 99)
        #expect(snapshot.metrics[0].limit == 100)
        #expect(snapshot.metrics[0].detail == "1 week")
        #expect(snapshot.metrics[0].periodDurationMilliseconds == 604_800_000)
        #expect(snapshot.metrics[0].detail?.contains("ms") != true)
        #expect(snapshot.metrics[1].text == "2500 cap")
        #expect(snapshot.links == [ProviderLink(label: "Usage", url: "https://grok.com/?_s=usage")])
        #expect(snapshot.widgets.map(\.id) == [
            "grok.weekly", "grok.usageLimitResets", "grok.payAsYouGo", "grok.trend",
            "grok.today", "grok.yesterday", "grok.last30",
        ])
    }

    @Test("Grok usage-limit resets map 0, N, and a missing field")
    func grokUsageLimitResets() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let authURL = root.appendingPathComponent(".grok/auth.json")
        try write(
            """
            {"https://auth.x.ai::client":{"key":"access-token","refresh_token":"refresh-token",\
            "id_token":"\(jwt(email: "grok@example.com"))","expires_at":"2026-08-01T00:00:00Z"}}
            """,
            to: authURL
        )
        let auth = try #require(try GrokLinuxCredentialStore(environment: ["HOME": root.path]).loadCandidates().first)
        let billing = Data("""
        {"config":{"creditUsagePercent":5.0,"currentPeriod":{
          "type":"USAGE_PERIOD_TYPE_WEEKLY",
          "start":"2026-06-30T21:36:52.140114+00:00",
          "end":"2026-07-07T21:36:52.140114+00:00"}}}
        """.utf8)
        let liveResets = Data([
            0x00, 0x00, 0x00, 0x00, 0x23,
            0x52, 0x21, 0x52, 0x0D, 0x72, 0x65, 0x73, 0x74, 0x6F, 0x6B, 0x5F,
            0x76, 0x70, 0x59, 0x44, 0x71, 0x6F,
            0xA2, 0x01, 0x06, 0x08, 0x9C, 0x80, 0xF3, 0xD3, 0x06,
            0xF2, 0x01, 0x06, 0x08, 0x9C, 0xBD, 0x96, 0xD5, 0x06,
            0x80, 0x00, 0x00, 0x00, 0x0F,
            0x67, 0x72, 0x70, 0x63, 0x2D, 0x73, 0x74, 0x61, 0x74, 0x75, 0x73, 0x3A, 0x30, 0x0D, 0x0A
        ])
        let now = Date(timeIntervalSince1970: 1_786_536_000)

        let withOne = try GrokLinuxMapper.mapCredits(
            data: billing, auth: auth, remainingResets: liveResets, now: now
        )
        let reset = try #require(withOne.metrics.first { $0.label == GrokRemainingResets.metricLabel })
        #expect(reset.used == 1)
        #expect(reset.values == [UsageValue(label: "available", value: 1, unit: .count)])
        #expect(reset.expiriesAt == [Date(timeIntervalSince1970: 1_789_238_940)])
        #expect(withOne.metrics.map(\.label).prefix(3) == [
            "Weekly limit", GrokRemainingResets.metricLabel, "Pay as you go"
        ])

        let withZero = try GrokLinuxMapper.mapCredits(
            data: billing, auth: auth, remainingResets: GrokRemainingResets.emptyRequest, now: now
        )
        let zero = try #require(withZero.metrics.first { $0.label == GrokRemainingResets.metricLabel })
        #expect(zero.used == 0)
        #expect(zero.expiriesAt?.isEmpty != false)

        let missing = try GrokLinuxMapper.mapCredits(data: billing, auth: auth, now: now)
        #expect(missing.metrics.contains { $0.label == GrokRemainingResets.metricLabel } == false)
        #expect(missing.metrics.map(\.label) == ["Weekly limit", "Pay as you go"])
    }

    @Test("Grok local log contributes every spend metric and a bounded trend")
    func grokLocalMetrics() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let logURL = root.appendingPathComponent("custom-grok/logs/unified.jsonl")
        try write(
            """
            {"ts":"2026-07-08T09:00:00Z","pid":1,"msg":"model changed","ctx":{"model":"grok-build"}}
            {"ts":"2026-07-08T10:00:00Z","pid":1,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"cached_prompt_tokens":0,"completion_tokens":0,"reasoning_tokens":0}}
            {"ts":"2026-07-07T09:00:00Z","pid":2,"msg":"model changed","ctx":{"model":"grok-fast"}}
            {"ts":"2026-07-07T10:00:00Z","pid":2,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":0,"cached_prompt_tokens":0,"completion_tokens":1000000,"reasoning_tokens":0}}
            """,
            to: logURL
        )
        let scanner = GrokLinuxLogScanner(
            environment: ["HOME": root.path, "GROK_HOME": root.appendingPathComponent("custom-grok").path],
            pricing: LinuxModelPricing(rates: [
                "grok-build": .init(inputPerMillion: 1, outputPerMillion: 1),
                "grok-fast": .init(inputPerMillion: 1, outputPerMillion: 15),
            ])
        )

        let metrics = try scanner.scan(now: now)
        #expect(metrics.filter { $0.kind == .values }.map(\.label) == ["Today", "Yesterday", "Last 30 Days"])
        #expect(metrics.first { $0.label == "Today" }?.values == [
            UsageValue(label: "Cost", value: 1, unit: .dollars),
            UsageValue(label: "Tokens", value: 1_000_000, unit: .tokens),
        ])
        #expect(metrics.first { $0.label == "Yesterday" }?.values?.first?.value == 15)
        let trend = try #require(metrics.first { $0.label == "Usage Trend" })
        #expect(trend.points?.count == 31)
        #expect(trend.points?.suffix(2).map(\.value) == [1_000_000, 1_000_000])
    }

    @Test("Grok rejects oversized local auth without reading it unbounded")
    func grokBoundedAuthRead() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(".grok/auth.json")
        try write(String(repeating: "x", count: 513 * 1024), to: url)
        let store = GrokLinuxCredentialStore(environment: ["HOME": root.path])

        #expect(throws: GrokLinuxError.localDataTooLarge) {
            try store.loadCandidates()
        }
    }

    @Test("Devin discovers Linux credentials and maps all quota fields with account identity")
    func devinParity() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataRoot = root.appendingPathComponent("share")
        try write(
            """
            windsurf_api_key = "devin-session-token$cli"
            api_server_url = "https://server.codeium.test/"
            """,
            to: dataRoot.appendingPathComponent("devin/credentials.toml")
        )
        let store = DevinLinuxCredentialStore(environment: [
            "HOME": root.path,
            "XDG_DATA_HOME": dataRoot.path,
            "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
        ])
        let credential = try store.loadCredentials()
        #expect(credential.apiKey == "devin-session-token$cli")
        #expect(credential.apiServerURL == "https://server.codeium.test")

        let body = Data("""
        {"userStatus":{"email":"devin@example.com","planStatus":{
          "planInfo":{"planName":"Max","hideDailyQuota":false},
          "dailyQuotaRemainingPercent":100,
          "weeklyQuotaRemainingPercent":40,
          "overageBalanceMicros":"964220000",
          "dailyQuotaResetAtUnix":"1774080000",
          "weeklyQuotaResetAtUnix":"1774166400"}}}
        """.utf8)
        let snapshot = try DevinLinuxMapper.mapUserStatus(data: body, credential: credential, now: now)

        #expect(snapshot.accountLabel == "devin@example.com")
        #expect(snapshot.metrics.map(\.label) == ["Daily quota", "Weekly quota", "Extra usage balance"])
        #expect(snapshot.metrics.map(\.used) == [0, 60, 964.22])
        #expect(snapshot.metrics[0].detail == "1 day")
        #expect(snapshot.metrics[1].detail == "1 week")
        #expect(snapshot.metrics[0].periodDurationMilliseconds == 86_400_000)
        #expect(snapshot.metrics[1].periodDurationMilliseconds == 604_800_000)
        #expect(snapshot.links == [ProviderLink(label: "Dashboard", url: "https://app.devin.ai/settings/plans")])
        #expect(snapshot.widgets.map(\.id) == ["devin.daily", "devin.weekly", "devin.extra"])
    }

    @Test("Devin hidden daily quota fills weekly and errors stay typed")
    func devinFallbackAndErrors() throws {
        let body = Data("""
        {"userStatus":{"planStatus":{"planInfo":{"planName":"Max","hideDailyQuota":true},
          "dailyQuotaRemainingPercent":30,"overageBalanceMicros":"0"}}}
        """.utf8)
        let credential = DevinCredential(apiKey: "key", apiServerURL: nil, source: .credentialsFile)
        let snapshot = try DevinLinuxMapper.mapUserStatus(data: body, credential: credential, now: now)
        #expect(snapshot.metrics.map(\.label) == ["Weekly quota", "Extra usage balance"])
        #expect(snapshot.metrics.map(\.used) == [70, 0])

        #expect(throws: DevinLinuxError.quotaUnavailable) {
            try DevinLinuxMapper.mapUserStatus(
                data: Data(#"{"userStatus":{"planStatus":{"planInfo":{"planName":"Max"}}}}"#.utf8),
                credential: credential
            )
        }
    }

    @Test("Pi discovers overrides, deduplicates sessions, maps cards, and prices carried or fallback cost")
    func piParity() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("pi-sessions")
        let first = sessions.appendingPathComponent("project/one.jsonl")
        let duplicate = sessions.appendingPathComponent("project/two.jsonl")
        let line = piLine(id: "same", provider: "anthropic", model: "claude-opus", cost: 0.5)
        try write(line, to: first)
        try write(line + "\n" + piLine(id: "codex", provider: "openai-codex", model: "gpt-5", cost: 0), to: duplicate)
        let scanner = PiLinuxUsageScanner(
            environment: ["HOME": root.path, "PI_CODING_AGENT_SESSION_DIR": sessions.path],
            pricing: LinuxModelPricing(rates: ["gpt-5": .init(inputPerMillion: 10, outputPerMillion: 20)])
        )

        #expect(scanner.sessionsDirectory.path == sessions.path)
        let claude = try scanner.scan(cardID: "claude", now: now)
        #expect(claude.first { $0.label == "Today" }?.values?.first?.value == 0.5)
        #expect(claude.first { $0.label == "Today" }?.values?.last?.value == 150)
        let codex = try scanner.scan(cardID: "codex", now: now)
        #expect(codex.first { $0.label == "Today" }?.values?.first?.value == 0.002)
        #expect(PiLinuxUsageScanner.cardID(forProvider: "zhipu") == "zai")
        #expect(PiLinuxUsageScanner.cardID(forProvider: "nvidia-nim") == nil)
        #expect(PiLinuxUsageScanner.widgetDescriptors(forCardID: "claude").map(\.id) == [
            "claude.trend", "claude.today", "claude.yesterday", "claude.last30",
        ])
    }

    @Test("Pi rejects an oversized session file")
    func piBoundedReads() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        try write(String(repeating: "x", count: 513 * 1024), to: sessions.appendingPathComponent("huge.jsonl"))
        let scanner = PiLinuxUsageScanner(environment: [
            "HOME": root.path,
            "PI_CODING_AGENT_SESSION_DIR": sessions.path,
        ])

        #expect(throws: PiLinuxError.localDataTooLarge) {
            try scanner.scan(cardID: "claude", now: now)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ string: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(string.utf8).write(to: url)
    }

    private func jwt(email: String) -> String {
        let payload = Data(#"{"email":"\#(email)"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(payload).signature"
    }

    private func piLine(id: String, provider: String, model: String, cost: Double) -> String {
        "{\"type\":\"message\",\"id\":\"\(id)\",\"timestamp\":\"2026-07-08T10:00:00Z\",\"message\":{" +
            "\"role\":\"assistant\",\"provider\":\"\(provider)\",\"model\":\"\(model)\",\"usage\":{" +
            "\"input\":100,\"output\":50,\"cacheRead\":0,\"cacheWrite\":0,\"cacheWrite1h\":0," +
            "\"totalTokens\":150,\"cost\":{\"total\":\(cost)}}}}"
    }
}
