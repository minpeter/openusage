import Foundation
import CoreFoundation

public enum OpenRouterLinuxMapper {
    public static func map(
        creditsBody: Data?,
        keyBody: Data?,
        now: Date = Date()
    ) throws -> ProviderUsageSnapshot {
        var metrics: [UsageMetric] = []
        var plan: String?
        if let creditsBody {
            metrics += try creditsMetrics(from: dataObject(creditsBody))
        }
        if let keyBody {
            let mapped = try keyMetrics(from: dataObject(keyBody))
            plan = mapped.plan
            metrics += mapped.metrics
        }
        guard !metrics.isEmpty else { throw OpenRouterProviderError.invalidResponse }
        return ProviderUsageSnapshot(
            providerID: "openrouter",
            displayName: "OpenRouter",
            accountLabel: nil,
            plan: plan,
            metrics: metrics,
            links: OpenRouterLinuxProvider.links,
            widgets: OpenRouterLinuxProvider.widgetDescriptors,
            refreshedAt: now
        )
    }

    public static func creditsMetrics(from data: [String: Any]) throws -> [UsageMetric] {
        guard let totalUsage = providerNumber(data["total_usage"]) else { return [] }
        let used = max(0, totalUsage)
        let totalCredits = max(0, providerNumber(data["total_credits"]) ?? 0)
        var metrics: [UsageMetric] = []
        if totalCredits > 0 {
            metrics.append(UsageMetric(kind: .progress, label: "Credits", used: used, limit: totalCredits))
        }
        metrics.append(UsageMetric(kind: .value, label: "Balance", used: max(0, totalCredits - used)))
        return metrics
    }

    public static func keyMetrics(from data: [String: Any]) throws -> (plan: String?, metrics: [UsageMetric]) {
        var metrics: [UsageMetric] = []
        appendSpend(data["usage_daily"], label: "Today", into: &metrics)
        appendSpend(data["usage_weekly"], label: "This Week", into: &metrics)
        appendSpend(data["usage_monthly"], label: "This Month", into: &metrics)
        if let limit = providerNumber(data["limit"]), limit > 0 {
            metrics.append(UsageMetric(
                kind: .progress,
                label: "Key Limit",
                used: max(0, providerNumber(data["usage"]) ?? 0),
                limit: limit
            ))
        }
        let plan = (data["is_free_tier"] as? Bool).map { $0 ? "Free tier" : "Pay as you go" }
        return (plan, metrics)
    }

    private static func dataObject(_ body: Data) throws -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let data = root["data"] as? [String: Any]
        else { throw OpenRouterProviderError.invalidResponse }
        return data
    }

    private static func appendSpend(_ raw: Any?, label: String, into metrics: inout [UsageMetric]) {
        guard let amount = providerNumber(raw) else { return }
        metrics.append(UsageMetric(kind: .value, label: label, used: max(0, amount)))
    }
}

private func providerNumber(_ raw: Any?) -> Double? {
    let value: Double?
    switch raw {
    case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID(): value = number.doubleValue
    case let string as String: value = Double(string)
    default: value = nil
    }
    guard let value, value.isFinite else { return nil }
    return value
}
