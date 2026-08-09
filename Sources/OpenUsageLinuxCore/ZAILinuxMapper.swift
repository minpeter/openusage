import Foundation
import CoreFoundation

public enum ZAILinuxMapper {
    public static let monthlyPeriodMilliseconds = 30 * 24 * 60 * 60 * 1000

    public static func map(
        quotaBody: Data,
        subscriptionBody: Data?,
        now: Date = Date()
    ) throws -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            providerID: "zai",
            displayName: "Z.ai",
            accountLabel: nil,
            plan: subscriptionBody.flatMap(planName),
            metrics: try mapQuota(quotaBody),
            links: ZAILinuxProvider.links,
            widgets: ZAILinuxProvider.widgetDescriptors,
            refreshedAt: now
        )
    }

    public static func isNoCodingPlan(_ body: Data) -> Bool {
        guard let root = jsonObject(body), root["success"] as? Bool == false else { return false }
        return ((root["msg"] as? String) ?? "").lowercased().contains("coding plan")
    }

    public static func mapQuota(_ body: Data) throws -> [UsageMetric] {
        guard let root = jsonObject(body) else { throw ZAIProviderError.invalidResponse }
        let container: [String: Any]
        if let wrapped = root["data"] {
            guard let data = wrapped as? [String: Any] else { throw ZAIProviderError.invalidResponse }
            container = data
        } else {
            container = root
        }
        guard let limits = container["limits"] as? [[String: Any]] else {
            throw ZAIProviderError.invalidResponse
        }
        guard !limits.isEmpty else { return [noUsageMetric] }

        var metrics: [UsageMetric] = []
        var sawRecognized = false
        for entry in limits where isType(entry, "TOKENS_LIMIT") {
            guard let window = try classifyTokenWindow(entry) else { continue }
            sawRecognized = true
            switch window {
            case .session(let period):
                metrics.append(try percentMetric(entry, label: "Session", period: period))
            case .weekly(let period):
                metrics.append(try percentMetric(entry, label: "Weekly", period: period))
            }
        }
        if let entry = limits.first(where: { isType($0, "TIME_LIMIT") }) {
            sawRecognized = true
            metrics.append(try webSearchMetric(entry))
        }
        if metrics.isEmpty {
            if sawRecognized { throw ZAIProviderError.invalidResponse }
            return [noUsageMetric]
        }
        return metrics
    }

    public static func planName(from body: Data) -> String? {
        guard let root = jsonObject(body),
              let list = root["data"] as? [[String: Any]],
              let value = list.first?["productName"] as? String
        else { return nil }
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private enum TokenWindow {
        case session(Int)
        case weekly(Int)
    }

    private static func classifyTokenWindow(_ entry: [String: Any]) throws -> TokenWindow? {
        guard let unit = zaiNumber(entry["unit"]),
              let number = zaiNumber(entry["number"]), number > 0
        else { throw ZAIProviderError.invalidResponse }
        let unitMilliseconds: Double
        switch unit {
        case 3: unitMilliseconds = 60 * 60 * 1000
        case 4: unitMilliseconds = 24 * 60 * 60 * 1000
        case 5: unitMilliseconds = 30 * 24 * 60 * 60 * 1000
        case 6: unitMilliseconds = 7 * 24 * 60 * 60 * 1000
        default: return nil
        }
        let duration = unitMilliseconds * number
        guard duration >= 1, duration < Double(Int.max) else { throw ZAIProviderError.invalidResponse }
        let milliseconds = Int(duration)
        return milliseconds < 24 * 60 * 60 * 1000 ? .session(milliseconds) : .weekly(milliseconds)
    }

    private static func percentMetric(
        _ entry: [String: Any],
        label: String,
        period: Int
    ) throws -> UsageMetric {
        guard let raw = zaiNumber(entry["percentage"]) else { throw ZAIProviderError.invalidResponse }
        return UsageMetric(
            kind: .progress,
            label: label,
            used: min(max(raw, 0), 100),
            limit: 100,
            resetsAt: zaiNumber(entry["nextResetTime"]).map(epochMilliseconds),
            periodDurationMilliseconds: period
        )
    }

    private static func webSearchMetric(_ entry: [String: Any]) throws -> UsageMetric {
        guard let used = zaiNumber(entry["currentValue"]),
              let limit = zaiNumber(entry["usage"]), used >= 0, limit >= 0
        else { throw ZAIProviderError.invalidResponse }
        return UsageMetric(
            kind: .progress,
            label: "Web Searches",
            used: used,
            limit: limit,
            resetsAt: zaiNumber(entry["nextResetTime"]).map(epochMilliseconds),
            periodDurationMilliseconds: monthlyPeriodMilliseconds,
            detail: "searches"
        )
    }

    private static var noUsageMetric: UsageMetric {
        UsageMetric(kind: .badge, label: "Status", used: 0, text: "No usage data")
    }

    private static func isType(_ entry: [String: Any], _ type: String) -> Bool {
        entry["type"] as? String == type || entry["name"] as? String == type
    }

    private static func epochMilliseconds(_ milliseconds: Double) -> Date {
        Date(timeIntervalSince1970: milliseconds / 1000)
    }

    private static func jsonObject(_ body: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }
}

private func zaiNumber(_ raw: Any?) -> Double? {
    let value: Double?
    switch raw {
    case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID(): value = number.doubleValue
    case let string as String: value = Double(string)
    default: value = nil
    }
    guard let value, value.isFinite else { return nil }
    return value
}
