import Foundation
import OpenUsageLinuxCore

/// Human copy for `.values` metrics. The generic renderer used to join every
/// `UsageValue` as `"label number"`, which leaked Codex's internal `available`
/// key and stacked `$0.00 · credits 0` on top of the leftover `0 credits` detail.
enum GNOMEValuesCopy {
    static let empty = "—"

    static func primary(for metric: UsageMetric, now: Date = Date()) -> String {
        let values = metric.values ?? []
        if isRateLimitResets(metric) {
            return rateLimitResetsPrimary(metric, values: values, now: now)
        }
        if isUsageLimitResets(metric) {
            return usageLimitResetsPrimary(metric, values: values)
        }
        if let credits = creditsPair(values) {
            if credits.dollars == 0 && credits.count == 0 {
                return GNOMEFormat.currency(0)
            }
            return "\(GNOMEFormat.currency(credits.dollars)) · \(GNOMEFormat.tokens(credits.count)) credits"
        }
        let parts = values.map(formatValue(_:))
        return parts.isEmpty ? GNOMEFormat.currency(metric.used) : parts.joined(separator: " · ")
    }

    static func caption(
        for metric: UsageMetric,
        presentation: GNOMEMetricPresentation,
        now: Date = Date()
    ) -> String? {
        let expiry = soonestExpiryText(metric, now: now)
        let detail = GNOMEFormat.metricDetail(metric.detail).flatMap { text in
            isRedundantCreditsDetail(text, metric: metric) ? nil : text
        }
        return [detail, presentation.resetText, presentation.pacingText, expiry]
            .compactMap { $0 }
            .joined(separator: " · ")
            .nilIfEmpty
    }

    static func formatValue(_ value: UsageValue) -> String {
        switch value.unit {
        case .dollars:
            let number = value.label.isEmpty ? "" : "\(value.label) "
            return number + GNOMEFormat.currency(value.value)
        case .tokens, .count:
            let unitWord = value.unit == .tokens ? "tokens" : nil
            return countCopy(value, unitWord: unitWord)
        case .credits:
            return "\(GNOMEFormat.tokens(value.value)) credits"
        case .percent:
            return "\(Int(value.value.rounded()))%"
        }
    }

    static func shouldDisplay(_ metric: UsageMetric) -> Bool {
        guard metric.kind == .chart else { return true }
        return (metric.points ?? []).contains { $0.value.isFinite && $0.value > 0 }
    }

    private static func rateLimitResetsPrimary(
        _ metric: UsageMetric,
        values: [UsageValue],
        now: Date
    ) -> String {
        let count = values.first?.value ?? metric.used
        let expiries = metric.expiriesAt ?? []
        if count <= 0 && expiries.isEmpty {
            return empty
        }
        if count <= 0, let expiry = expiries.first {
            return relativeExpiry(expiry, now: now)
        }
        let n = max(0, Int(count.rounded(.down)))
        return n == 1 ? "1 reset" : "\(GNOMEFormat.tokens(Double(n))) resets"
    }

    private static func usageLimitResetsPrimary(
        _ metric: UsageMetric,
        values: [UsageValue]
    ) -> String {
        let count = values.first?.value ?? metric.used
        let n = max(0, Int(count.rounded(.down)))
        return "\(GNOMEFormat.tokens(Double(n))) available"
    }

    private static func soonestExpiryText(_ metric: UsageMetric, now: Date) -> String? {
        guard showsResetExpiries(metric), let expiry = metric.expiriesAt?.first else {
            return nil
        }
        let count = metric.values?.first?.value ?? metric.used
        if count <= 0 {
            return nil
        }
        return relativeExpiry(expiry, now: now)
    }

    private static func relativeExpiry(_ date: Date, now: Date) -> String {
        GNOMEFormat.relativeReset(date, now: now).replacingOccurrences(of: "Resets", with: "Expires")
    }

    private static func countCopy(_ value: UsageValue, unitWord: String?) -> String {
        let number = GNOMEFormat.tokens(value.value)
        let raw = value.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = raw.lowercased()
        if raw.isEmpty || isInternalCountKey(lowered) {
            return unitWord.map { "\(number) \($0)" } ?? number
        }
        if lowered == "credits" || lowered == unitWord {
            return "\(number) \(lowered)"
        }
        if let unitWord, lowered == unitWord {
            return "\(number) \(unitWord)"
        }
        return "\(raw) \(number)"
    }

    private static func isInternalCountKey(_ label: String) -> Bool {
        ["available", "available_count", "count", "value"].contains(label)
    }

    private static func isRateLimitResets(_ metric: UsageMetric) -> Bool {
        metric.label == "Rate Limit Resets"
    }

    private static func isUsageLimitResets(_ metric: UsageMetric) -> Bool {
        metric.label == GrokRemainingResets.metricLabel
    }

    /// Codex Rate Limit Resets and Grok Usage Limit Resets share the same
    /// `expiriesAt` caption path (`Expires in …`).
    private static func showsResetExpiries(_ metric: UsageMetric) -> Bool {
        isRateLimitResets(metric) || isUsageLimitResets(metric)
    }

    private static func creditsPair(_ values: [UsageValue]) -> (dollars: Double, count: Double)? {
        guard values.count == 2,
              let dollars = values.first(where: { $0.unit == .dollars }),
              let credits = values.first(where: {
                  $0.unit == .credits || ($0.unit == .count && $0.label.lowercased() == "credits")
              })
        else {
            return nil
        }
        return (dollars.value, credits.value)
    }

    private static func isRedundantCreditsDetail(_ detail: String, metric: UsageMetric) -> Bool {
        let normalized = detail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.range(of: #"^\d+ credits$"#, options: .regularExpression) != nil else {
            return false
        }
        return metric.label == "Credits" || creditsPair(metric.values ?? []) != nil
    }
}
