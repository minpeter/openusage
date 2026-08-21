import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenUsageLinuxCore

@Suite("Cursor Grok Bot weekly")
struct CursorGrokBotWeeklyTests {
    @Test("Sand usage fixture maps percent, weekly reset, and week-long period")
    func mapsWeeklyPool() throws {
        let reset = try #require(isoDate("2026-08-27T00:00:00.000Z"))
        let snapshot = try CursorLinuxMapper.map(
            usage: object("""
            {
              "enabled": true,
              "billingCycleStart": 1770000000000,
              "billingCycleEnd": 1772592000000,
              "planUsage": {"limit":40000,"totalPercentUsed":20,"autoPercentUsed":12.5,"apiPercentUsed":7.5}
            }
            """),
            planName: "Ultra",
            creditGrants: nil,
            stripeBalanceCents: 0,
            accountLabel: "user_abc123",
            sandUsage: object("""
            {
              "currentPeriodStart": "2026-08-20T00:00:00.000Z",
              "nextResetTimestampUtc": "2026-08-27T00:00:00.000Z",
              "usagePercent": 13,
              "hasAvailableUsage": true,
              "hasNonZeroIncludedLimit": true
            }
            """)
        )

        let metric = try #require(snapshot.metrics.first { $0.label == "Grok Bot weekly" })
        #expect(metric.kind == .progress)
        #expect(metric.used == 13)
        #expect(metric.limit == 100)
        #expect(metric.resetsAt == reset)
        #expect(metric.periodDurationMilliseconds == 7 * 24 * 3_600 * 1_000)
        #expect(metric.detail == "percent")
        #expect(snapshot.metrics.map(\.label).contains("Cursor Models"))
        #expect(snapshot.metrics.map(\.label).contains("Other Models"))
        #expect(snapshot.metrics.map(\.label).contains("Auto usage") == false)
        #expect(snapshot.widgets.contains { $0.id == "cursor.grokBotWeekly" && $0.title == "Grok Bot Weekly" })
    }

    @Test("Missing Grok Bot weekly field stays No data instead of inventing 0%")
    func omitsWhenCursorOmitsThePool() throws {
        let snapshot = try CursorLinuxMapper.map(
            usage: object("""
            {
              "enabled": true,
              "planUsage": {"limit":40000,"totalPercentUsed":20,"autoPercentUsed":4,"apiPercentUsed":8}
            }
            """),
            planName: "Pro",
            creditGrants: nil,
            stripeBalanceCents: 0,
            accountLabel: nil,
            sandUsage: nil
        )

        #expect(snapshot.metrics.contains { $0.label == "Grok Bot weekly" } == false)
        #expect(snapshot.metrics.map(\.label) == ["Cursor Models", "Other Models"])
    }

    @Test("Zero-limit sand payload does not invent a 0% Grok Bot weekly tile")
    func omitsWhenPoolIsDisabled() throws {
        let snapshot = try CursorLinuxMapper.map(
            usage: object(#"{"enabled":true,"planUsage":{"limit":40000,"totalPercentUsed":8}}"#),
            planName: "Pro",
            creditGrants: nil,
            stripeBalanceCents: 0,
            accountLabel: nil,
            sandUsage: object("""
            {
              "usagePercent": 0,
              "hasNonZeroIncludedLimit": false,
              "includedLimitZero": true
            }
            """)
        )

        #expect(snapshot.metrics.contains { $0.label == "Grok Bot weekly" } == false)
        #expect(snapshot.metrics.contains { $0.label == "Cursor Models" })
    }

    @Test("Entitled 0% week is real data, not omitted")
    func keepsRealZeroPercent() throws {
        let metric = try #require(CursorLinuxMapper.grokBotWeeklyMetric(from: object("""
        {
          "currentPeriodStart": "2026-08-20T00:00:00.000Z",
          "nextResetTimestampUtc": "2026-08-27T00:00:00.000Z",
          "usagePercent": 0,
          "hasNonZeroIncludedLimit": true
        }
        """)))
        #expect(metric.used == 0)
        #expect(metric.limit == 100)
        #expect(metric.label == "Grok Bot weekly")
    }

    @Test("Request-based fallback still attaches the weekly Grok Bot pool")
    func requestFallbackKeepsWeeklyPool() throws {
        let snapshot = try CursorLinuxMapper.mapRequestBased(
            summary: object("""
            {"membershipType":"enterprise","billingCycleStart":"2026-02-01T00:00:00Z","billingCycleEnd":"2026-03-01T00:00:00Z",
             "individualUsage":{"plan":{"totalPercentUsed":9,"autoPercentUsed":12,"apiPercentUsed":7}}}
            """),
            requests: object(#"{"gpt-4":{"numRequests":39,"maxRequestUsage":500}}"#),
            planName: "Enterprise",
            accountLabel: "user_abc123",
            sandUsage: object("""
            {
              "currentPeriodStart": 1787184000000,
              "nextResetTimestampUtc": 1787788800000,
              "usagePercent": 13,
              "hasNonZeroIncludedLimit": true
            }
            """)
        )

        #expect(snapshot.metrics.map(\.label) == [
            "Total usage", "Requests", "Cursor Models", "Other Models", "Grok Bot weekly",
        ])
        let metric = try #require(snapshot.metrics.last)
        #expect(metric.used == 13)
        #expect(metric.resetsAt == Date(timeIntervalSince1970: 1_787_788_800))
    }

    @Test("GetSandUsageStatus uses the same sanctioned Connect RPC session as dashboard usage")
    func sandUsageRequestParity() {
        let request = CursorLinuxClient.sandUsageRequest(accessToken: "cursor-secret")
        #expect(request.url == CursorLinuxClient.sandUsageURL)
        #expect(request.url?.absoluteString.contains("GetSandUsageStatus") == true)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer cursor-secret")
        #expect(request.value(forHTTPHeaderField: "Connect-Protocol-Version") == "1")
        #expect(request.url?.absoluteString.contains("cursor-secret") == false)
        #expect(request.url?.absoluteString.contains("grok.com") == false)
    }

    @Test("Refresh maps GetSandUsageStatus and stays healthy when Cursor omits the pool")
    func refreshMapsOptionalSandUsage() async throws {
        let token = jwt(["sub": "google-oauth2|user_abc123", "exp": 9_999_999_999])
        let credentials = CursorLinuxCredentialStore(
            environment: ["HOME": "/home/tester", "XDG_CONFIG_HOME": "/xdg"],
            stateValue: { _, key in ["cursorAuth/accessToken": token][key] }
        )
        let usage = Data(#"{"enabled":true,"planUsage":{"limit":40000,"totalPercentUsed":20,"autoPercentUsed":12,"apiPercentUsed":7}}"#.utf8)
        let present = try await CursorLinuxProvider(
            credentials: credentials,
            transport: FixtureTransport([
                "GetCurrentPeriodUsage": HTTPResult(data: usage, statusCode: 200),
                "GetPlanInfo": HTTPResult(data: Data(#"{"planInfo":{"planName":"Ultra"}}"#.utf8), statusCode: 200),
                "GetSandUsageStatus": HTTPResult(data: Data("""
                {"usagePercent":13,"hasNonZeroIncludedLimit":true,"currentPeriodStart":"2026-08-20T00:00:00.000Z","nextResetTimestampUtc":"2026-08-27T00:00:00.000Z"}
                """.utf8), statusCode: 200),
                "GetCreditGrantsBalance": HTTPResult(data: Data(#"{"hasCreditGrants":false}"#.utf8), statusCode: 200),
            ])
        ).refresh()
        #expect(present.metrics.contains { $0.label == "Grok Bot weekly" && $0.used == 13 })

        let omitted = try await CursorLinuxProvider(
            credentials: credentials,
            transport: FixtureTransport([
                "GetCurrentPeriodUsage": HTTPResult(data: usage, statusCode: 200),
                "GetPlanInfo": HTTPResult(data: Data(#"{"planInfo":{"planName":"Pro"}}"#.utf8), statusCode: 200),
                "GetSandUsageStatus": HTTPResult(data: Data(#"{"includedLimitZero":true}"#.utf8), statusCode: 200),
                "GetCreditGrantsBalance": HTTPResult(data: Data(#"{"hasCreditGrants":false}"#.utf8), statusCode: 200),
            ])
        ).refresh()
        #expect(omitted.metrics.contains { $0.label == "Grok Bot weekly" } == false)
        #expect(omitted.metrics.contains { $0.label == "Cursor Models" })
    }
}

private func object(_ json: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}

private func isoDate(_ raw: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
}

private actor FixtureTransport: HTTPTransport {
    let responses: [String: HTTPResult]
    init(_ responses: [String: HTTPResult]) { self.responses = responses }
    func execute(_ request: URLRequest) async throws -> HTTPResult {
        responses.first(where: { request.url?.absoluteString.contains($0.key) == true })?.value
            ?? HTTPResult(data: Data(), statusCode: 404)
    }
}

private func jwt(_ payload: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: payload)
    let encoded = data.base64EncodedString()
        .replacingOccurrences(of: "=", with: "")
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
    return "a.\(encoded).c"
}
