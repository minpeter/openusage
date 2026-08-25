import Foundation
import Testing
@testable import OpenUsageLinuxCore

/// Weekday `sync/YYYY-MM-DD` merges can restore upstream Total / Auto / API.
/// Do not rewrite these expectations to match that card — linux keeps the
/// Spending IDs and labels reviewed on `3bfc9bf`.
@Suite("Linux Cursor spending identity lock")
struct CursorSpendingIdentityLockTests {
    @Test("Catalog keeps Cursor Models, Other Models, and default-on Grok Bot Weekly")
    func catalogKeepsSpendingIdentity() throws {
        let widgets = CursorLinuxProvider.widgets
        let byID = Dictionary(uniqueKeysWithValues: widgets.map { ($0.id, $0) })

        #expect(widgets.prefix(3).map(\.id) == [
            CursorSpendingPools.cursorModelsWidgetID,
            CursorSpendingPools.otherModelsWidgetID,
            "cursor.grokBotWeekly",
        ])
        #expect(widgets.prefix(3).map(\.title) == [
            "Cursor Models",
            "Other Models",
            "Grok Bot Weekly",
        ])

        let cursorModels = try #require(byID["cursor.cursorModels"])
        #expect(cursorModels.title == "Cursor Models")
        #expect(cursorModels.metricLabel == "Cursor Models")
        #expect(cursorModels.metricLabel == CursorSpendingPools.cursorModelsLabel)
        #expect(CursorSpendingPools.cursorModelsWidgetID == "cursor.cursorModels")
        #expect(CursorSpendingPools.cursorModelsLabel == "Cursor Models")

        let otherModels = try #require(byID["cursor.otherModels"])
        #expect(otherModels.title == "Other Models")
        #expect(otherModels.metricLabel == "Other Models")
        #expect(otherModels.metricLabel == CursorSpendingPools.otherModelsLabel)
        #expect(CursorSpendingPools.otherModelsWidgetID == "cursor.otherModels")
        #expect(CursorSpendingPools.otherModelsLabel == "Other Models")

        let grokBot = try #require(byID["cursor.grokBotWeekly"])
        #expect(grokBot.title == "Grok Bot Weekly")
        #expect(grokBot.metricLabel == "Grok Bot Weekly")
        #expect(grokBot.metricLabel == CursorSpendingPools.grokBotWeeklyLabel)
        #expect(CursorSpendingPools.grokBotWeeklyLabel == "Grok Bot Weekly")
        #expect(CursorSpendingPools.remapLayoutID("cursor.grokBotWeekly") == "cursor.grokBotWeekly")
        #expect(CursorSpendingPools.layoutIDAliases["cursor.grokBotWeekly"] == nil)

        #expect(byID["cursor.auto"] == nil)
        #expect(byID["cursor.api"] == nil)
    }

    @Test("Cursor Models reads totalPercentUsed and refuses leftover autoPercentUsed")
    func cursorModelsRefusesAutoSlice() throws {
        #expect(CursorSpendingPools.cursorModelsPercent(
            planUsage: ["totalPercentUsed": 1, "autoPercentUsed": 2]
        ) == 1)
        #expect(CursorSpendingPools.cursorModelsPercent(
            planUsage: ["autoPercentUsed": 2]
        ) == nil)

        let snapshot = try CursorLinuxMapper.map(
            usage: object("""
            {
              "enabled": true,
              "planUsage": {"limit":40000,"remaining":39600,"totalPercentUsed":1,"autoPercentUsed":2}
            }
            """),
            planName: "Ultra",
            creditGrants: nil,
            stripeBalanceCents: 0,
            accountLabel: nil
        )

        let models = try #require(snapshot.metrics.first { $0.label == "Cursor Models" })
        #expect(models.used == 1)
        #expect(snapshot.metrics.contains { $0.label == "Other Models" })
        #expect(snapshot.metrics.contains { $0.label == "Auto usage" } == false)
        #expect(snapshot.metrics.contains { $0.label == "API usage" } == false)
        #expect(snapshot.metrics.contains { $0.label == "Total usage" } == false)
        #expect(snapshot.widgets.contains {
            $0.id == "cursor.grokBotWeekly" && $0.title == "Grok Bot Weekly"
        })
    }
}

private func object(_ json: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}
