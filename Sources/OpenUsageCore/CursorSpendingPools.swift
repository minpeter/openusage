import Foundation

/// Current Cursor Spending dashboard pools (Cursor Models + Other Models).
///
/// Factory QA on linux `4653391` (Ultra, 2026-08-21) showed official **Cursor Models 1%**
/// matching `planUsage.totalPercentUsed`, not leftover `autoPercentUsed` (2%). Official
/// **Other Models 0%** can be missing from `apiPercentUsed` even when the plan includes
/// the pool (Pro / Pro+ / Ultra). Auto/API labels are stale Spending copy.
public enum CursorSpendingPools {
    public static let cursorModelsLabel = "Cursor Models"
    public static let otherModelsLabel = "Other Models"
    public static let totalUsageLabel = "Total usage"
    public static let cursorModelsDetail = "Includes Cursor Grok and Composer"

    public static let cursorModelsWidgetID = "cursor.cursorModels"
    public static let otherModelsWidgetID = "cursor.otherModels"
    public static let legacyTotalWidgetID = "cursor.usage"
    public static let legacyAutoWidgetID = "cursor.auto"
    public static let legacyAPIWidgetID = "cursor.api"

    /// Persisted layout IDs from the Total / Auto / API card.
    public static let layoutIDAliases: [String: String] = [
        legacyAutoWidgetID: cursorModelsWidgetID,
        legacyTotalWidgetID: cursorModelsWidgetID,
        legacyAPIWidgetID: otherModelsWidgetID,
    ]

    /// Persisted GTK metric labels from the Total / Auto / API card.
    public static let layoutLabelAliases: [String: String] = [
        "Auto usage": cursorModelsLabel,
        "Total usage": cursorModelsLabel,
        "API usage": otherModelsLabel,
    ]

    private static let cursorModelsPercentKeys = [
        "cursorModelsPercentUsed",
        "cursorModelPercentUsed",
        "includedPercentUsed",
        "firstPartyPercentUsed",
        "totalPercentUsed",
    ]

    private static let otherModelsPercentKeys = [
        "otherModelsPercentUsed",
        "otherModelPercentUsed",
        "namedPercentUsed",
        "thirdPartyPercentUsed",
        "apiPercentUsed",
    ]

    private static let cursorModelsObjectKeys = [
        "cursorModels", "cursorModelUsage", "includedUsage",
    ]

    private static let otherModelsObjectKeys = [
        "otherModels", "otherModelUsage", "namedModels",
    ]

    public static func remapLayoutID(_ id: String) -> String {
        layoutIDAliases[id] ?? id
    }

    public static func remapLayoutIDs(_ ids: [String]) -> [String] {
        uniqued(ids.map(remapLayoutID))
    }

    public static func remapLayoutLabel(_ label: String) -> String {
        layoutLabelAliases[label] ?? label
    }

    public static func summaryPlan(_ summary: [String: Any]?) -> [String: Any]? {
        (summary?["individualUsage"] as? [String: Any])?["plan"] as? [String: Any]
    }

    /// First-party monthly pool. Prefer a dedicated field, then `totalPercentUsed`.
    /// Never `autoPercentUsed` — that leftover Auto-mode slice disagreed with Spending.
    public static func cursorModelsPercent(
        planUsage: [String: Any]?,
        summaryPlan: [String: Any]? = nil
    ) -> Double? {
        firstPercent(in: [planUsage, summaryPlan], keys: cursorModelsPercentKeys)
            ?? firstNestedPercent(in: [planUsage, summaryPlan], objects: cursorModelsObjectKeys)
    }

    /// Third-party monthly pool. A real 0 is kept. Missing `apiPercentUsed` still
    /// shows 0% when the plan includes the pool (Pro / Pro+ / Ultra). Start and
    /// unknown plans omit the tile — we do not invent 0% for an absent pool.
    public static func otherModelsPercent(
        planUsage: [String: Any]?,
        summaryPlan: [String: Any]? = nil,
        planName: String?
    ) -> Double? {
        if let value = firstPercent(in: [planUsage, summaryPlan], keys: otherModelsPercentKeys)
            ?? firstNestedPercent(in: [planUsage, summaryPlan], objects: otherModelsObjectKeys)
        {
            return value
        }
        return includesOtherModelsPool(planName) == true ? 0 : nil
    }

    /// `true` when the plan includes Other Models, `false` for Start, `nil` when unknown.
    public static func includesOtherModelsPool(_ planName: String?) -> Bool? {
        let normalized = planName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "+", with: " plus ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            ?? ""
        guard !normalized.isEmpty else { return nil }
        if normalized.contains("start") { return false }
        if normalized == "hobby" || normalized == "free" { return false }
        if normalized.contains("ultra") { return true }
        if normalized.contains("pro plus") { return true }
        if normalized == "pro" || normalized.hasPrefix("pro ") { return true }
        return nil
    }

    public static func firstPercent(in objects: [[String: Any]?], keys: [String]) -> Double? {
        for object in objects {
            guard let object else { continue }
            for key in keys {
                if let value = spendingPercent(object[key]) { return value }
            }
        }
        return nil
    }

    private static func firstNestedPercent(
        in objects: [[String: Any]?],
        objects objectKeys: [String]
    ) -> Double? {
        let nestedKeys = ["percentUsed", "percent", "usedPercent", "totalPercentUsed"]
        for object in objects {
            guard let object else { continue }
            for key in objectKeys {
                guard let nested = object[key] as? [String: Any] else { continue }
                if let value = firstPercent(in: [nested], keys: nestedKeys) { return value }
            }
        }
        return nil
    }

    /// JSON `0` can bridge as an `NSNumber` that `is Bool`. Keep a real 0% and ignore booleans.
    public static func spendingPercent(_ value: Any?) -> Double? {
        if let value, type(of: value) == Bool.self { return nil }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func uniqued(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        return ids.filter { seen.insert($0).inserted }
    }
}
