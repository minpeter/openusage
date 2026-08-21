import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenUsageLinuxCore

@Suite("Cursor Spending pools")
struct CursorSpendingPoolsTests {
    @Test("Ultra fixture maps Cursor Models 1% and Other Models 0% without Auto/API/Total")
    func ultraTwoPoolShape() throws {
        let snapshot = try CursorLinuxMapper.map(
            usage: object("""
            {
              "enabled": true,
              "billingCycleStart": 1770000000000,
              "billingCycleEnd": 1772592000000,
              "planUsage": {"limit":40000,"remaining":39600,"totalPercentUsed":1,"autoPercentUsed":2}
            }
            """),
            planName: "Ultra",
            creditGrants: nil,
            stripeBalanceCents: 0,
            accountLabel: "user_abc123",
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        #expect(snapshot.metrics.map(\.label) == ["Cursor Models", "Other Models"])
        let models = try #require(snapshot.metrics.first { $0.label == "Cursor Models" })
        #expect(models.used == 1)
        #expect(models.limit == 100)
        #expect(models.detail == "Includes Cursor Grok and Composer")
        let other = try #require(snapshot.metrics.first { $0.label == "Other Models" })
        #expect(other.used == 0)
        #expect(other.limit == 100)
        #expect(snapshot.metrics.contains { $0.label == "Total usage" } == false)
        #expect(snapshot.metrics.contains { $0.label == "Auto usage" } == false)
        #expect(snapshot.metrics.contains { $0.label == "API usage" } == false)
        #expect(snapshot.widgets.map(\.id) == [
            "cursor.cursorModels", "cursor.otherModels", "cursor.grokBotWeekly", "cursor.onDemand",
            "cursor.requests", "cursor.credits", "cursor.usage", "cursor.usageTrend", "cursor.today",
            "cursor.yesterday", "cursor.last30",
        ])
    }

    @Test("Usage-summary Other Models 0% fills Ultra when planUsage omits apiPercentUsed")
    func usageSummarySuppliesUnusedOtherModels() throws {
        let snapshot = try CursorLinuxMapper.map(
            usage: object(#"{"enabled":true,"planUsage":{"limit":40000,"totalPercentUsed":1}}"#),
            planName: "Pro",
            creditGrants: nil,
            stripeBalanceCents: 0,
            accountLabel: nil,
            usageSummary: object("""
            {"membershipType":"pro","individualUsage":{"plan":{"totalPercentUsed":1,"apiPercentUsed":0}}}
            """)
        )

        #expect(snapshot.metrics.first { $0.label == "Cursor Models" }?.used == 1)
        #expect(snapshot.metrics.first { $0.label == "Other Models" }?.used == 0)
        #expect(snapshot.metrics.contains { $0.label == "Auto usage" } == false)
    }

    @Test("Start omits Other Models when the pool is absent")
    func startOmitsMissingOtherModelsPool() throws {
        let snapshot = try CursorLinuxMapper.map(
            usage: object(#"{"enabled":true,"planUsage":{"limit":40000,"totalPercentUsed":8}}"#),
            planName: "Start",
            creditGrants: nil,
            stripeBalanceCents: 0,
            accountLabel: nil
        )

        #expect(snapshot.metrics.map(\.label) == ["Cursor Models"])
        #expect(snapshot.metrics.contains { $0.label == "Other Models" } == false)
    }

    @Test("Missing pool without plan entitlement is not invented as 0%")
    func unknownPlanDoesNotInventOtherModels() throws {
        let snapshot = try CursorLinuxMapper.map(
            usage: object(#"{"enabled":true,"planUsage":{"limit":40000,"totalPercentUsed":8}}"#),
            planName: nil,
            creditGrants: nil,
            stripeBalanceCents: 0,
            accountLabel: nil
        )

        #expect(snapshot.metrics.map(\.label) == ["Cursor Models"])
        #expect(snapshot.metrics.contains { $0.label == "Other Models" } == false)
    }

    @Test("Reported Other Models 0% is real data")
    func keepsReportedZero() throws {
        let snapshot = try CursorLinuxMapper.map(
            usage: object(#"{"enabled":true,"planUsage":{"limit":40000,"totalPercentUsed":4,"apiPercentUsed":0}}"#),
            planName: "Pro Plus",
            creditGrants: nil,
            stripeBalanceCents: 0,
            accountLabel: nil
        )

        #expect(snapshot.metrics.first { $0.label == "Other Models" }?.used == 0)
    }

    @Test("Grok Bot weekly still maps beside the two monthly pools")
    func grokBotWeeklyStillMaps() throws {
        let snapshot = try CursorLinuxMapper.map(
            usage: object(#"{"enabled":true,"planUsage":{"limit":40000,"totalPercentUsed":1}}"#),
            planName: "Ultra",
            creditGrants: nil,
            stripeBalanceCents: 0,
            accountLabel: nil,
            sandUsage: object("""
            {
              "currentPeriodStart": "2026-08-20T00:00:00.000Z",
              "nextResetTimestampUtc": "2026-08-27T00:00:00.000Z",
              "usagePercent": 13,
              "hasNonZeroIncludedLimit": true
            }
            """)
        )

        #expect(snapshot.metrics.map(\.label) == ["Cursor Models", "Other Models", "Grok Bot weekly"])
        #expect(snapshot.metrics.first { $0.label == "Grok Bot weekly" }?.used == 13)
    }

    @Test("Refresh uses usage-summary Other Models 0% for Ultra")
    func refreshMergesUsageSummary() async throws {
        let token = jwt(["sub": "google-oauth2|user_abc123", "exp": 9_999_999_999])
        let credentials = CursorLinuxCredentialStore(
            environment: ["HOME": "/home/tester", "XDG_CONFIG_HOME": "/xdg"],
            stateValue: { _, key in ["cursorAuth/accessToken": token][key] }
        )
        let snapshot = try await CursorLinuxProvider(
            credentials: credentials,
            transport: FixtureTransport([
                "GetCurrentPeriodUsage": HTTPResult(
                    data: Data(#"{"enabled":true,"planUsage":{"limit":40000,"totalPercentUsed":1,"autoPercentUsed":2}}"#.utf8),
                    statusCode: 200
                ),
                "GetPlanInfo": HTTPResult(data: Data(#"{"planInfo":{"planName":"Ultra"}}"#.utf8), statusCode: 200),
                "GetSandUsageStatus": HTTPResult(data: Data(#"{"includedLimitZero":true}"#.utf8), statusCode: 200),
                "GetCreditGrantsBalance": HTTPResult(data: Data(#"{"hasCreditGrants":false}"#.utf8), statusCode: 200),
                "usage-summary": HTTPResult(
                    data: Data(#"{"individualUsage":{"plan":{"totalPercentUsed":1,"apiPercentUsed":0}}}"#.utf8),
                    statusCode: 200
                ),
            ])
        ).refresh()

        #expect(snapshot.metrics.first { $0.label == "Cursor Models" }?.used == 1)
        #expect(snapshot.metrics.first { $0.label == "Other Models" }?.used == 0)
        #expect(snapshot.metrics.contains { $0.label == "Auto usage" } == false)
        #expect(snapshot.metrics.contains { $0.label == "Total usage" } == false)
    }
}

private func object(_ json: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
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
