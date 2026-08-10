import Foundation

public enum TrayUsageDisplayMode: String, Codable, CaseIterable, Sendable {
    case mostUrgent
    case iconOnly

    public static let defaultValue = Self.mostUrgent
}

public struct UsageToolbarSummary: Equatable, Sendable {
    public enum Severity: Equatable, Sendable {
        case normal
        case warning
        case critical
    }

    public let providerID: String
    public let providerName: String
    public let metricLabel: String
    public let percentUsed: Int
    public let severity: Severity

    public var compactLabel: String {
        "\(providerName) · \(percentUsed)%"
    }

    public var accessibilityDescription: String {
        "\(providerName), \(metricLabel), \(percentUsed)% used"
    }

    public static func mostUrgent(in snapshots: [ProviderUsageSnapshot]) -> Self? {
        var selected: (snapshot: ProviderUsageSnapshot, metric: UsageMetric, fraction: Double)?

        for snapshot in snapshots where snapshot.errorMessage == nil {
            for metric in snapshot.metrics where metric.kind == .progress {
                guard let fraction = metric.fraction, fraction.isFinite else { continue }
                if selected == nil || fraction > selected?.fraction ?? 0 {
                    selected = (snapshot, metric, fraction)
                }
            }
        }

        guard let selected else { return nil }
        let fraction = min(max(selected.fraction, 0), 1)
        let percentUsed = Int((fraction * 100).rounded())
        let severity: Severity
        if fraction >= 0.9 {
            severity = .critical
        } else if fraction >= 0.75 {
            severity = .warning
        } else {
            severity = .normal
        }
        return Self(
            providerID: selected.snapshot.providerID,
            providerName: selected.snapshot.displayName,
            metricLabel: selected.metric.label,
            percentUsed: percentUsed,
            severity: severity
        )
    }
}

public extension StatusNotifierItemConfiguration {
    static func usage(
        snapshots: [ProviderUsageSnapshot],
        displayMode: TrayUsageDisplayMode
    ) -> Self {
        guard let summary = UsageToolbarSummary.mostUrgent(in: snapshots) else {
            return Self(label: "", tooltip: "No active usage quotas")
        }
        switch displayMode {
        case .mostUrgent:
            return Self(
                title: summary.compactLabel,
                label: summary.compactLabel,
                tooltip: "\(summary.metricLabel) · \(summary.percentUsed)% used"
            )
        case .iconOnly:
            return Self(
                label: "",
                tooltip: "\(summary.providerName) · \(summary.metricLabel) · "
                    + "\(summary.percentUsed)% used"
            )
        }
    }
}
