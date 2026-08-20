import Foundation

public enum GrokLinuxMapper {
    public static func mapCredits(
        data: Data,
        auth: GrokCredential,
        plan: String? = nil,
        localMetrics: [UsageMetric] = [],
        now: Date = Date()
    ) throws -> ProviderUsageSnapshot {
        guard data.count <= 512 * 1024,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = body["config"] as? [String: Any],
              let period = config["currentPeriod"] as? [String: Any],
              let periodType = grokTrimmed(period["type"] as? String),
              let start = grokDate(period["start"] as? String),
              let end = grokDate(period["end"] as? String), end > start
        else { throw GrokLinuxError.invalidResponse }

        let usedPercent: Double
        if let raw = config["creditUsagePercent"] {
            guard let number = linuxNumber(raw), number.isFinite else { throw GrokLinuxError.invalidResponse }
            usedPercent = min(max(number, 0), 100)
        } else { usedPercent = 0 }

        let cap: Double
        if let raw = config["onDemandCap"] {
            guard let object = raw as? [String: Any],
                  let number = linuxNumber(object["val"] ?? 0), number.isFinite
            else { throw GrokLinuxError.invalidResponse }
            cap = number
        } else { cap = 0 }

        var metrics: [UsageMetric] = []
        if periodType == "USAGE_PERIOD_TYPE_WEEKLY" {
            let periodMilliseconds = Int((end.timeIntervalSince(start) * 1000).rounded())
            metrics.append(UsageMetric(
                kind: .progress, label: "Weekly limit", used: usedPercent, limit: 100,
                resetsAt: end,
                periodDurationMilliseconds: periodMilliseconds,
                detail: LinuxDurationFormat.period(milliseconds: periodMilliseconds)
            ))
        }
        metrics.append(UsageMetric(
            kind: .badge, label: "Pay as you go", used: 0,
            detail: cap > 0 ? "#22c55e" : "#a3a3a3",
            text: cap > 0 ? "\(formatGrokUnits(cap)) cap" : "Disabled"
        ))
        metrics.append(contentsOf: localMetrics)
        return ProviderUsageSnapshot(
            providerID: "grok", instanceID: auth.instanceID, displayName: "Grok",
            accountLabel: auth.accountLabel, plan: grokTrimmed(plan), metrics: metrics,
            links: GrokLinuxProvider.links, widgets: GrokLinuxProvider.widgetDescriptors,
            refreshedAt: now
        )
    }
}

private func formatGrokUnits(_ value: Double) -> String { value.rounded() == value ? String(Int(value)) : String(value) }
