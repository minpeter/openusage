import Foundation

public enum DevinLinuxMapper {
    public static func mapUserStatus(
        data: Data,
        credential: DevinCredential,
        now: Date = Date()
    ) throws -> ProviderUsageSnapshot {
        guard data.count <= 512 * 1024,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = root["userStatus"] as? [String: Any]
        else { throw DevinLinuxError.invalidResponse }
        let planStatus = status["planStatus"] as? [String: Any] ?? [:]
        let planInfo = planStatus["planInfo"] as? [String: Any] ?? [:]
        let plan = devinTrimmed(planInfo["planName"] as? String) ?? "Unknown"
        let hideDaily = linuxBool(planInfo["hideDailyQuota"]) == true
        let daily = linuxNumber(planStatus["dailyQuotaRemainingPercent"])
        let weekly = linuxNumber(planStatus["weeklyQuotaRemainingPercent"])
        let dailyReset = hideDaily ? nil : linuxNumber(planStatus["dailyQuotaResetAtUnix"]).map(Date.init(timeIntervalSince1970:))
        let weeklyReset = linuxNumber(planStatus["weeklyQuotaResetAtUnix"]).map(Date.init(timeIntervalSince1970:))
        var metrics: [UsageMetric] = []
        if !hideDaily, let daily {
            metrics.append(quota(label: "Daily quota", remaining: daily, reset: dailyReset, period: 86_400_000))
        }
        if let weekly {
            metrics.append(quota(label: "Weekly quota", remaining: weekly, reset: weeklyReset, period: 604_800_000))
        } else if hideDaily, let daily {
            metrics.append(quota(label: "Weekly quota", remaining: daily, reset: weeklyReset, period: 604_800_000))
        }
        if let micros = linuxNumber(planStatus["overageBalanceMicros"]) {
            let dollars = max(0, micros) / 1_000_000
            metrics.append(UsageMetric(
                kind: .values, label: "Extra usage balance", used: dollars,
                values: [UsageValue(label: "Balance", value: dollars, unit: .dollars)]
            ))
        }
        guard !metrics.isEmpty else { throw DevinLinuxError.quotaUnavailable }
        let account = devinAccountLabel(status)
        return ProviderUsageSnapshot(
            providerID: "devin", instanceID: credential.instanceID, displayName: "Devin",
            accountLabel: account, plan: plan, metrics: metrics,
            links: DevinLinuxProvider.links, widgets: DevinLinuxProvider.widgetDescriptors,
            refreshedAt: now
        )
    }

    private static func quota(label: String, remaining: Double, reset: Date?, period: Int) -> UsageMetric {
        UsageMetric(
            kind: .progress, label: label, used: min(max(100 - remaining, 0), 100), limit: 100,
            resetsAt: reset, detail: "\(period) ms period"
        )
    }
}

private func linuxBool(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    if let value = value as? String { return Bool(value) }
    return nil
}
private func devinAccountLabel(_ status: [String: Any]) -> String? {
    for key in ["email", "userEmail", "name", "displayName"] {
        if let value = devinTrimmed(status[key] as? String) { return value }
    }
    if let profile = status["user"] as? [String: Any] {
        for key in ["email", "name", "displayName"] {
            if let value = devinTrimmed(profile[key] as? String) { return value }
        }
    }
    return nil
}
