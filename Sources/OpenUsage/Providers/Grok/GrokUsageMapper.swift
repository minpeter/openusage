import Foundation
import OpenUsageCore

struct GrokMappedUsage: Equatable, Sendable {
    var lines: [MetricLine]
}

enum GrokUsageMapper {
    /// Map the credits-format billing response into the provider's remote lines: the Weekly meter
    /// plus the pay-as-you-go badge. The Weekly line is omitted (the tile reads "No data") when the
    /// account's current period isn't weekly — an account still on the old monthly-only billing has
    /// no weekly pool, and mislabeling its monthly percent would be worse than an honest blank.
    ///
    /// `remainingResets` is the dedicated `GetRemainingResets` body. A usable 2xx decode appends
    /// Usage Limit Resets (`N available`, including 0). A miss / non-2xx / unparseable body omits
    /// the row — Codex-consistent missing-field behavior. Never derived from `currentPeriod.end`.
    static func mapCreditsConfig(
        _ response: HTTPResponse,
        remainingResets: HTTPResponse? = nil,
        now: Date = Date()
    ) throws -> GrokMappedUsage {
        try ProviderAuthRetry.requireSuccess(
            response,
            authExpired: GrokAuthError.expired,
            requestFailed: { GrokUsageError.requestFailed($0) }
        )
        let config = try GrokCreditsConfigDecoder.decode(responseBody: response.body)

        var lines: [MetricLine] = []
        if config.periodType == GrokCreditsConfigDecoder.weeklyPeriodType {
            lines.append(.progress(
                label: "Weekly limit",
                used: ProviderParse.clampPercent(config.usedPercent),
                limit: 100,
                format: .percent,
                resetsAt: config.periodEnd,
                periodDurationMs: config.periodDurationMs
            ))
        }
        if let resets = remainingResets.flatMap({
            GrokRemainingResets.snapshot(httpStatus: $0.statusCode, body: $0.body, now: now)
        }) {
            lines.append(.values(
                label: GrokRemainingResets.metricLabel,
                values: [MetricValue(number: Double(resets.availableCount), kind: .count, label: "available")],
                expiriesAt: resets.availableExpiries
            ))
        }
        // A missing `onDemandCap` means no pay-as-you-go (proto-JSON also drops a 0 cap) → the
        // Disabled badge, same as a present cap of 0.
        lines.append(.badge(
            label: "Pay as you go",
            text: config.onDemandCap > 0 ? "\(formatUnits(config.onDemandCap)) cap" : "Disabled",
            colorHex: config.onDemandCap > 0 ? "#22c55e" : "#a3a3a3"
        ))
        return GrokMappedUsage(lines: lines)
    }

    static func planName(from response: HTTPResponse) -> String? {
        guard (200..<300).contains(response.statusCode),
              let body = ProviderParse.jsonObject(response.body),
              let plan = body["subscription_tier_display"] as? String
        else {
            return nil
        }
        let trimmed = plan.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func formatUnits(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(value)
    }
}
