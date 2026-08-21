import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenUsageLinuxCore

@Suite("Cursor and Copilot Linux parity")
struct CursorCopilotParityTests {
    @Test("Cursor discovers Linux state DB credentials and derives account identity")
    func cursorCredentialDiscovery() throws {
        let token = jwt(["sub": "google-oauth2|user_abc123", "exp": 9_999_999_999])
        let store = CursorLinuxCredentialStore(
            environment: ["HOME": "/home/tester", "XDG_CONFIG_HOME": "/xdg"],
            stateValue: { path, key in
                #expect(path == "/xdg/Cursor/User/globalStorage/state.vscdb")
                return [
                    "cursorAuth/accessToken": token,
                    "cursorAuth/refreshToken": "refresh-secret",
                ][key]
            }
        )

        let credentials = try store.load()
        #expect(credentials.accessToken == token)
        #expect(credentials.refreshToken == "refresh-secret")
        #expect(credentials.accountLabel == "user_abc123")
        #expect(store.stateDatabaseCandidates.map(\.path) == [
            "/xdg/Cursor/User/globalStorage/state.vscdb",
            "/xdg/cursor/User/globalStorage/state.vscdb",
        ])
    }

    @Test("Copilot discovery follows editor then gh precedence and scopes github.com")
    func copilotCredentialDiscovery() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(#"{"ghe.corp":{"oauth_token":"enterprise"},"github.com:Iv1.x":{"user":"editor-user","oauth_token":" editor-secret "}}"#,
                  to: root.appendingPathComponent("github-copilot/apps.json"))
        try write("ghe.corp:\n    oauth_token: enterprise\ngithub.com:\n    user: gh-user\n    oauth_token: gh-secret\n",
                  to: root.appendingPathComponent("gh/hosts.yml"))

        let credential = try CopilotLinuxCredentialStore(environment: [
            "HOME": "/home/tester", "XDG_CONFIG_HOME": root.path,
        ]).load()

        #expect(credential.token == "editor-secret")
        #expect(credential.accountLabel == "editor-user")
        #expect(String(describing: credential) == "CopilotLinuxCredential(accountLabel: editor-user, token: <redacted>)")
    }

    @Test("Cursor fixture preserves plan, every live meter, links, and widget descriptors")
    func cursorFixtureParity() throws {
        let snapshot = try CursorLinuxMapper.map(
            usage: object("""
            {
              "enabled": true,
              "billingCycleStart": 1770000000000,
              "billingCycleEnd": 1772592000000,
              "planUsage": {"limit":40000,"remaining":32000,"totalPercentUsed":20,"autoPercentUsed":12.5,"apiPercentUsed":7.5},
              "spendLimitUsage": {"individualLimit":5000,"individualRemaining":1000}
            }
            """),
            planName: "pro plan",
            creditGrants: object(#"{"hasCreditGrants":true,"totalCents":"1000000","usedCents":"264729"}"#),
            stripeBalanceCents: 991_544,
            accountLabel: "user_abc123",
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        #expect(snapshot.plan == "Pro Plan")
        #expect(snapshot.accountLabel == "user_abc123")
        #expect(snapshot.metrics.map(\.label) == ["Credits", "Cursor Models", "Other Models", "On-demand"])
        #expect(snapshot.metrics.map(\.used) == [17268.15, 20, 7.5, 40])
        #expect(snapshot.metrics.last?.limit == 50)
        #expect(snapshot.metrics.contains { $0.label == "Grok Bot weekly" } == false)
        #expect(snapshot.metrics.contains { $0.label == "Auto usage" } == false)
        #expect(snapshot.links == CursorLinuxProvider.links)
        #expect(snapshot.widgets.map(\.id) == [
            "cursor.cursorModels", "cursor.otherModels", "cursor.grokBotWeekly", "cursor.onDemand",
            "cursor.requests", "cursor.credits", "cursor.usage", "cursor.usageTrend", "cursor.today",
            "cursor.yesterday", "cursor.last30",
        ])
    }

    @Test("Cursor request fallback keeps both total and request meters")
    func cursorRequestFallbackParity() throws {
        let snapshot = try CursorLinuxMapper.mapRequestBased(
            summary: object("""
            {"membershipType":"enterprise","billingCycleStart":"2026-02-01T00:00:00Z","billingCycleEnd":"2026-03-01T00:00:00Z",
             "individualUsage":{"plan":{"totalPercentUsed":9,"autoPercentUsed":12,"apiPercentUsed":7},"onDemand":{"enabled":true,"used":1250,"limit":5000}}}
            """),
            requests: object(#"{"gpt-4":{"numRequests":39,"maxRequestUsage":500}}"#),
            planName: "Enterprise",
            accountLabel: "user_abc123"
        )

        #expect(snapshot.metrics.map(\.label) == ["Total usage", "Requests", "Cursor Models", "Other Models", "On-demand"])
        #expect(snapshot.metrics[0].used == 39)
        #expect(snapshot.metrics[0].limit == 500)
        #expect(snapshot.metrics.last?.used == 12.5)
    }

    @Test("Copilot paid and free fixtures preserve exact quota semantics")
    func copilotMapperParity() throws {
        let paid = try CopilotLinuxMapper.map(
            body: object("""
            {"copilot_plan":"pro","quota_reset_date":"2099-01-15T00:00:00Z","quota_snapshots":{
              "premium_interactions":{"entitlement":300,"remaining":123,"percent_remaining":41,"overage_permitted":true,"overage_count":36},
              "chat":{"entitlement":-1,"remaining":-1},"completions":{"unlimited":true,"entitlement":0,"remaining":0}}}
            """),
            accountLabel: "octocat"
        )
        #expect(paid.plan == "Pro")
        #expect(paid.metrics.map(\.label) == ["Credits", "Extra Usage"])
        #expect(paid.metrics.map(\.used) == [59, 36])
        #expect(paid.accountLabel == "octocat")
        #expect(paid.links == CopilotLinuxProvider.links)
        #expect(paid.widgets.map(\.id) == ["copilot.premium", "copilot.extra", "copilot.orgCredits", "copilot.orgSpend", "copilot.chat", "copilot.completions"])

        let free = try CopilotLinuxMapper.map(
            body: object(#"{"copilot_plan":"individual","limited_user_quotas":{"chat":250,"completions":2000},"monthly_quotas":{"chat":500,"completions":4000},"limited_user_reset_date":"2099-02-15"}"#),
            accountLabel: nil
        )
        #expect(free.metrics.map(\.label) == ["Chat", "Completions"])
        #expect(free.metrics.map(\.used) == [50, 50])
    }

    @Test("Copilot org billing fixture maps credits and billed spend")
    func copilotOrgBillingParity() throws {
        let metrics = try #require(CopilotLinuxMapper.mapOrganizationBilling(body: object("""
        {"usageItems":[
          {"product":"Copilot","unitType":"ai-units","grossQuantity":298.698546,"netAmount":0},
          {"product":"Copilot","unitType":"ai-credits","grossQuantity":50,"netAmount":1.75},
          {"product":"Copilot","unitType":"user-months","grossQuantity":10,"netAmount":190}
        ]}
        """)))
        #expect(abs(metrics[0].used - 348.698546) < 0.000001)
        #expect(metrics[1].used == 1.75)
    }

    @Test("Provider clients send exact auth semantics without putting secrets in URLs")
    func requestParityAndSecretBoundaries() throws {
        let cursor = try CursorLinuxClient.usageRequest(accessToken: "cursor-secret")
        let copilot = try CopilotLinuxClient.usageRequest(token: "github-secret")

        #expect(cursor.httpMethod == "POST")
        #expect(cursor.value(forHTTPHeaderField: "Authorization") == "Bearer cursor-secret")
        #expect(cursor.value(forHTTPHeaderField: "Connect-Protocol-Version") == "1")
        #expect(cursor.url?.absoluteString.contains("cursor-secret") == false)
        #expect(copilot.value(forHTTPHeaderField: "Authorization") == "token github-secret")
        #expect(copilot.value(forHTTPHeaderField: "X-Github-Api-Version") == "2025-04-01")
        #expect(copilot.url?.absoluteString.contains("github-secret") == false)
    }

    @Test("Provider boundaries throw provider-specific typed errors")
    func typedErrors() async throws {
        let missingCursor = CursorLinuxProvider(
            credentials: CursorLinuxCredentialStore(environment: ["HOME": temporaryDirectory().path]),
            transport: FixtureTransport([:])
        )
        await #expect(throws: CursorLinuxError.credentialsMissing) { try await missingCursor.refresh() }

        let missingCopilot = CopilotLinuxProvider(
            credentials: CopilotLinuxCredentialStore(environment: ["HOME": temporaryDirectory().path]),
            transport: FixtureTransport([:])
        )
        await #expect(throws: CopilotLinuxError.credentialsMissing) { try await missingCopilot.refresh() }
    }
}

private actor FixtureTransport: HTTPTransport {
    let responses: [String: HTTPResult]
    init(_ responses: [String: HTTPResult]) { self.responses = responses }
    func execute(_ request: URLRequest) async throws -> HTTPResult {
        responses.first(where: { request.url?.absoluteString.contains($0.key) == true })?.value
            ?? HTTPResult(data: Data(), statusCode: 404)
    }
}

private func object(_ json: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}

private func jwt(_ payload: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: payload)
    let encoded = data.base64EncodedString()
        .replacingOccurrences(of: "=", with: "")
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
    return "a.\(encoded).c"
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}
