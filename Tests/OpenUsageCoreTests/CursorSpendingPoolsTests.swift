import Foundation
import Testing
import OpenUsageCore

@Suite("Cursor Spending pool decode")
struct CursorSpendingPoolDecodeTests {
    @Test("Cursor Models prefers totalPercentUsed over leftover autoPercentUsed")
    func cursorModelsIgnoresAutoSlice() {
        let planUsage: [String: Any] = ["totalPercentUsed": 1, "autoPercentUsed": 2]
        #expect(CursorSpendingPools.cursorModelsPercent(planUsage: planUsage) == 1)
        #expect(CursorSpendingPools.cursorModelsPercent(planUsage: ["autoPercentUsed": 2]) == nil)
        #expect(CursorSpendingPools.cursorModelsPercent(
            planUsage: ["cursorModelsPercentUsed": 1, "totalPercentUsed": 9]
        ) == 1)
    }

    @Test("Other Models keeps a reported 0 and does not invent one for Start")
    func otherModelsPresence() {
        #expect(CursorSpendingPools.otherModelsPercent(
            planUsage: ["apiPercentUsed": 0],
            planName: "Start"
        ) == 0)
        #expect(CursorSpendingPools.otherModelsPercent(planUsage: [:], planName: "Ultra") == 0)
        #expect(CursorSpendingPools.otherModelsPercent(planUsage: [:], planName: "Start") == nil)
        #expect(CursorSpendingPools.otherModelsPercent(planUsage: [:], planName: nil) == nil)
    }

    @Test("Layout IDs remap without duplicating Cursor Models")
    func remapsLegacyIDs() {
        #expect(CursorSpendingPools.remapLayoutIDs([
            "cursor.usage", "cursor.auto", "cursor.api", "cursor.grokBotWeekly",
        ]) == [
            "cursor.cursorModels", "cursor.otherModels", "cursor.grokBotWeekly",
        ])
        #expect(CursorSpendingPools.remapLayoutLabel("Auto usage") == "Cursor Models")
        #expect(CursorSpendingPools.remapLayoutLabel("API usage") == "Other Models")
        #expect(CursorSpendingPools.remapLayoutLabel("Total usage") == "Cursor Models")
        #expect(CursorSpendingPools.remapLayoutLabel("Grok Bot weekly") == "Grok Bot Weekly")
    }
}
