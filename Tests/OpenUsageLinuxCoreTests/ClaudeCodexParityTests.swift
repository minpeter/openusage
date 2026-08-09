import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenUsageLinuxCore

@Suite("Claude and Codex macOS parity")
struct ClaudeCodexParityTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Claude maps every live metric and preserves period metadata")
    func claudeMetrics() throws {
        let response = ProviderHTTPResponse(statusCode: 200, body: Data("""
        {
          "five_hour":{"utilization":10,"resets_at":2099010100},
          "seven_day":{"utilization":20,"resets_at":"2099-01-01T00:00:00Z"},
          "seven_day_sonnet":{"utilization":5},
          "limits":[
            {"kind":"weekly_scoped","percent":99,"scope":{"model":{"display_name":"Other"}}},
            {"kind":"weekly_scoped","percent":7,"scope":{"model":{"display_name":"Fable"}}}
          ],
          "extra_usage":{"is_enabled":true,"used_credits":123456}
        }
        """.utf8))
        let snapshot = try ClaudeUsageMapper.map(
            response: response,
            credentials: ClaudeCredentials(accessToken: "a", refreshToken: nil, expiresAt: nil,
                subscriptionType: "max", rateLimitTier: "default_claude_max_20x", scopes: ["user:profile"]),
            now: now
        )

        #expect(snapshot.metrics.map(\.label) == ["Session", "Weekly", "Sonnet", "Fable", "Extra usage spent"])
        #expect(snapshot.metrics[0].periodDurationMs == 18_000_000)
        #expect(snapshot.metrics[1].periodDurationMs == 604_800_000)
        #expect(snapshot.metrics.last?.kind == .values)
        #expect(snapshot.metrics.last?.values == [UsageValue(label: "", value: 1234.56, unit: .dollars)])
        #expect(snapshot.plan == "Max 20x")
        #expect(snapshot.links == ProviderDefinitions.claudeLinks)
        #expect(snapshot.widgets.map(\.id) == ProviderDefinitions.claudeWidgets(instanceID: "claude").map(\.id))
    }

    @Test("Claude config dirs discover and isolate multiple account identities")
    func claudeAccounts() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent(".claude-work")
        let xdg = root.appendingPathComponent(".config/claude-side")
        for (directory, account, org, email) in [
            (work, "ACCT", "ORG-A", "dev@example.com"),
            (xdg, "ACCT", "ORG-B", "dev@example.com"),
        ] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let identity = "{\"oauthAccount\":{\"accountUuid\":\"\(account)\",\"organizationUuid\":\"\(org)\",\"organizationName\":\"\(org)\",\"emailAddress\":\"\(email)\"}}"
            try Data(identity.utf8).write(to: directory.appendingPathComponent(".claude.json"))
            try Data(#"{"claudeAiOauth":{"accessToken":"token","scopes":["user:profile"]}}"#.utf8)
                .write(to: directory.appendingPathComponent(".credentials.json"))
        }
        let paths = LinuxPaths(environment: ["HOME": root.path])
        let accounts = ClaudeConfigDirDiscovery(paths: paths).discover()

        #expect(accounts.map(\.identityKey) == ["acct|org-a", "acct|org-b"])
        #expect(Set(accounts.map(\.instanceID)).count == 2)
        #expect(accounts.allSatisfy { $0.accountLabel?.contains("dev@example.com") == true })
        #expect(try LinuxCredentialStore(paths: paths).loadClaude(configDirectory: work).accessToken == "token")
    }

    @Test("Claude client gates scopes, refreshes, retries, and persists rotation")
    func claudeRefresh() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try Data(#"{"claudeAiOauth":{"accessToken":"old","refreshToken":"refresh","expiresAt":1,"subscriptionType":"pro","scopes":["user:profile"]}}"#.utf8)
            .write(to: config.appendingPathComponent(".credentials.json"))
        let transport = ScriptedProviderTransport([
            .init(statusCode: 200, body: Data(#"{"access_token":"fresh","refresh_token":"rotated","expires_in":3600}"#.utf8)),
            .init(statusCode: 200, body: Data(#"{"five_hour":{"utilization":25}}"#.utf8)),
        ])
        let client = ClaudeProviderClient(transport: transport, now: { now })
        let snapshot = try await client.refresh(configDirectory: config, store: LinuxCredentialStore(paths: LinuxPaths(environment: ["HOME": root.path])))

        #expect(snapshot.metrics.first?.used == 25)
        #expect(await transport.methods() == ["POST", "GET"])
        let persisted = try String(contentsOf: config.appendingPathComponent(".credentials.json"), encoding: .utf8)
        #expect(persisted.contains("fresh") && persisted.contains("rotated"))
    }

    @Test("Claude missing profile scope is a typed soft failure")
    func claudeScope() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try Data(#"{"claudeAiOauth":{"accessToken":"token","scopes":["user:inference"]}}"#.utf8)
            .write(to: config.appendingPathComponent(".credentials.json"))
        let transport = ScriptedProviderTransport([])
        do {
            _ = try await ClaudeProviderClient(transport: transport).refresh(
                configDirectory: config,
                store: LinuxCredentialStore(paths: LinuxPaths(environment: ["HOME": root.path]))
            )
            Issue.record("expected missingProfileScope")
        } catch let error as ClaudeProviderError {
            #expect(error == .missingProfileScope)
        }
        #expect(await transport.methods().isEmpty)
    }

    @Test("Codex maps windows, Spark, resets, credits, headers, and descriptors")
    func codexMetrics() throws {
        let usage = ProviderHTTPResponse(statusCode: 200, headers: [
            "x-codex-primary-used-percent": "11",
            "x-codex-secondary-used-percent": "22",
            "x-codex-credits-balance": "9.9",
        ], body: Data("""
        {
          "plan_type":"prolite",
          "rate_limit":{},
          "additional_rate_limits":[{"metered_feature":"codex_spark_preview","rate_limit":{
            "primary_window":{"used_percent":30,"limit_window_seconds":18000},
            "secondary_window":{"used_percent":40,"limit_window_seconds":604800}
          }}],
          "rate_limit_reset_credits":{"available_count":1}
        }
        """.utf8))
        let resets = ProviderHTTPResponse(statusCode: 200, body: Data("""
        {"available_count":2,"credits":[
          {"expires_at":"2027-01-15T08:00:00Z"},
          {"status":"consumed","expires_at":"2027-01-14T08:00:00Z"},
          {"status":"available","expires_at":1900000000}
        ]}
        """.utf8))
        let snapshot = try CodexUsageMapper.map(response: usage, resetCredits: resets, now: now)

        #expect(snapshot.metrics.map(\.label) == ["Session", "Weekly", "Spark", "Spark Weekly", "Rate Limit Resets", "Credits"])
        #expect(snapshot.metrics[0].used == 11)
        #expect(snapshot.metrics[4].values?.first?.value == 2)
        #expect(snapshot.metrics[4].expiriesAt?.count == 2)
        #expect(snapshot.metrics[5].values == [
            UsageValue(label: "", value: 0.36, unit: .dollars),
            UsageValue(label: "credits", value: 9, unit: .count),
        ])
        #expect(snapshot.plan == "Pro 5x")
        #expect(snapshot.links == ProviderDefinitions.codexLinks)
        #expect(snapshot.widgets.map(\.id) == ProviderDefinitions.codexWidgets.map(\.id))
    }

    @Test("Codex refresh errors remain typed")
    func codexTypedRefreshError() async throws {
        let transport = ScriptedProviderTransport([
            .init(statusCode: 401, body: Data()),
            .init(statusCode: 400, body: Data(#"{"error":"refresh_token_reused"}"#.utf8)),
        ])
        let credentials = CodexCredentials(accessToken: "old", refreshToken: "refresh", idToken: nil, accountID: "acct", apiKey: nil)
        do {
            _ = try await CodexProviderClient(transport: transport, now: { now }).refresh(credentials: credentials)
            Issue.record("expected token conflict")
        } catch let error as CodexProviderError {
            #expect(error == .tokenConflict)
        }
    }

    @Test("Codex reset claim matches expiry and uses an idempotency key")
    func codexResetClaim() async throws {
        let expiry = Date(timeIntervalSince1970: 1_900_000_000)
        let transport = ScriptedProviderTransport([
            .init(statusCode: 200, body: Data(#"{"available_count":1,"credits":[{"id":"credit-1","expires_at":1900000000}]}"#.utf8)),
            .init(statusCode: 200, body: Data(#"{"code":"already_redeemed"}"#.utf8)),
        ])
        let client = CodexProviderClient(transport: transport)
        let outcome = try await client.claimResetCredit(
            credentials: CodexCredentials(accessToken: "token", refreshToken: nil, idToken: nil, accountID: "acct", apiKey: nil),
            expiringAt: expiry,
            redeemRequestID: "request-1"
        )

        #expect(outcome == .success)
        let bodies = await transport.bodies()
        let body = try #require(bodies.last ?? nil)
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(payload == ["credit_id": "credit-1", "redeem_request_id": "request-1"])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor ScriptedProviderTransport: ProviderHTTPTransport {
    private var responses: [ProviderHTTPResponse]
    private var requests: [URLRequest] = []

    init(_ responses: [ProviderHTTPResponse]) { self.responses = responses }

    func execute(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return responses.removeFirst()
    }

    func methods() -> [String] { requests.map { $0.httpMethod ?? "" } }
    func bodies() -> [Data?] { requests.map(\.httpBody) }
}
