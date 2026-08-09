import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum CopilotLinuxMapper {
    public struct Mapped: Sendable {
        public let snapshot: ProviderUsageSnapshot
        public let isOrganizationManaged: Bool
    }

    public static func map(body: [String: Any], accountLabel: String?, now: Date = Date()) throws -> ProviderUsageSnapshot {
        try mapped(body: body, accountLabel: accountLabel, now: now).snapshot
    }

    public static func mapped(body: [String: Any], accountLabel: String?, now: Date = Date()) throws -> Mapped {
        let plan = copilotMapperTitle(body["copilot_plan"] as? String)
        let reset = resetDate(body["quota_reset_date"]) ?? resetDate(body["limited_user_reset_date"])
        let snapshots = body["quota_snapshots"] as? [String: Any]
        var metrics: [UsageMetric] = []
        let credits = quota(label: "Credits", raw: snapshots?["premium_interactions"], reset: reset)
        if let credits {
            metrics.append(credits)
            if let premium = snapshots?["premium_interactions"] as? [String: Any], copilotMapperBool(premium["overage_permitted"]) == true {
                metrics.append(UsageMetric(kind: .values, label: "Extra Usage", used: max(0, copilotMapperNumber(premium["overage_count"]) ?? 0),
                                           values: [UsageValue(label: "count", value: max(0, copilotMapperNumber(premium["overage_count"]) ?? 0), unit: .count)]))
            }
        }
        if let metric = quota(label: "Chat", raw: snapshots?["chat"], reset: reset) { metrics.append(metric) }
        if let metric = quota(label: "Completions", raw: snapshots?["completions"], reset: reset) { metrics.append(metric) }
        if metrics.isEmpty {
            let limited = body["limited_user_quotas"] as? [String: Any]
            let monthly = body["monthly_quotas"] as? [String: Any]
            if let metric = limitedQuota(label: "Chat", remaining: limited?["chat"], total: monthly?["chat"], reset: reset) { metrics.append(metric) }
            if let metric = limitedQuota(label: "Completions", remaining: limited?["completions"], total: monthly?["completions"], reset: reset) { metrics.append(metric) }
        }
        let orgManaged = metrics.isEmpty && copilotMapperBool(body["token_based_billing"]) == true
        guard !metrics.isEmpty || orgManaged else { throw CopilotLinuxError.quotaUnavailable }
        let snapshot = ProviderUsageSnapshot(providerID: "copilot", displayName: "Copilot", accountLabel: accountLabel,
                                             plan: plan, metrics: metrics, links: CopilotLinuxProvider.links,
                                             widgets: CopilotLinuxProvider.widgets, refreshedAt: now)
        return Mapped(snapshot: snapshot, isOrganizationManaged: orgManaged)
    }

    public static func mapOrganizationBilling(body: [String: Any]) -> [UsageMetric]? {
        guard let items = body["usageItems"] as? [[String: Any]] else { return nil }
        let credits = items.filter {
            ($0["product"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "copilot"
                && ["ai-units", "ai-credits"].contains(($0["unitType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "")
        }
        guard !credits.isEmpty else { return nil }
        let quantity = credits.reduce(0.0) { $0 + max(0, copilotMapperNumber($1["grossQuantity"]) ?? 0) }
        let spend = credits.reduce(0.0) { $0 + max(0, copilotMapperNumber($1["netAmount"]) ?? 0) }
        return [
            UsageMetric(kind: .values, label: "Org Credits", used: quantity,
                        values: [UsageValue(label: "credits", value: quantity, unit: .credits)]),
            UsageMetric(kind: .values, label: "Org Spend", used: spend,
                        values: [UsageValue(label: "dollars", value: spend, unit: .dollars)]),
        ]
    }

    public static func organizationLogins(data: Data) -> [String] {
        guard let values = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return values.compactMap { copilotMapperNonEmpty(($0["login"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private static func quota(label: String, raw: Any?, reset: Date?) -> UsageMetric? {
        guard let bucket = raw as? [String: Any] else { return nil }
        let entitlement = copilotMapperNumber(bucket["entitlement"]), remaining = copilotMapperNumber(bucket["remaining"])
        if copilotMapperBool(bucket["unlimited"]) == true || entitlement == -1 || remaining == -1 || entitlement == 0 { return nil }
        let used: Double
        if let percentRemaining = copilotMapperNumber(bucket["percent_remaining"]) { used = clamp(100 - percentRemaining) }
        else if let entitlement, entitlement > 0, let remaining { used = clamp(100 - remaining / entitlement * 100) }
        else { return nil }
        return UsageMetric(kind: .progress, label: label, used: used, limit: 100, resetsAt: reset, detail: "percent")
    }

    private static func limitedQuota(label: String, remaining: Any?, total: Any?, reset: Date?) -> UsageMetric? {
        guard let total = copilotMapperNumber(total), total > 0, let remaining = copilotMapperNumber(remaining) else { return nil }
        return UsageMetric(kind: .progress, label: label, used: clamp(max(0, total - remaining) / total * 100), limit: 100, resetsAt: reset, detail: "percent")
    }

    private static func resetDate(_ value: Any?) -> Date? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let date = copilotMapperISODate(raw) { return date }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: raw)
    }

    private static func clamp(_ value: Double) -> Double { min(max(value, 0), 100) }
}

private func copilotMapperNumber(_ value: Any?) -> Double? {
    if value is Bool { return nil }
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? String { return Double(value) }
    return nil
}

private func copilotMapperISODate(_ value: Any?) -> Date? {
    guard let raw = value as? String else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
}

private func copilotMapperTitle(_ value: String?) -> String? {
    guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
    return raw.split(whereSeparator: { $0.isWhitespace || $0 == "_" || $0 == "-" }).map {
        $0.prefix(1).uppercased() + $0.dropFirst().lowercased()
    }.joined(separator: " ")
}

private func copilotMapperNonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
}

private func copilotMapperBool(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    if let value = value as? String {
        switch value.lowercased() { case "true", "1": return true; case "false", "0": return false; default: return nil }
    }
    return nil
}
