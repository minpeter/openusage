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
    public let accountLabel: String?
    public let metricLabel: String
    public let percentUsed: Int
    public let severity: Severity
    public let staleReason: String?

    public var isStale: Bool {
        staleReason != nil
    }

    public var compactLabel: String {
        "\(providerName) · \(percentUsed)%"
    }

    public var identityLabel: String {
        guard let accountLabel else { return providerName }
        return "\(providerName) · \(accountLabel)"
    }

    public var accessibilityDescription: String {
        let identity = [providerName, accountLabel].compactMap { $0 }.joined(separator: ", ")
        let description = "\(identity), \(metricLabel), \(percentUsed)% used"
        guard let staleReason else { return description }
        return "\(description), stale: \(staleReason)"
    }

    public static func mostUrgent(in snapshots: [ProviderUsageSnapshot]) -> Self? {
        var selected: (snapshot: ProviderUsageSnapshot, metric: UsageMetric, fraction: Double)?

        for snapshot in snapshots {
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
        } else if fraction >= 0.8 {
            severity = .warning
        } else {
            severity = .normal
        }
        return Self(
            providerID: selected.snapshot.providerID,
            providerName: selected.snapshot.displayName,
            accountLabel: selected.snapshot.accountLabel,
            metricLabel: selected.metric.label,
            percentUsed: percentUsed,
            severity: severity,
            staleReason: selected.snapshot.errorMessage
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
        let staleSuffix = summary.staleReason.map { " · Stale — \($0)" } ?? ""
        switch displayMode {
        case .mostUrgent:
            return Self(
                title: summary.compactLabel,
                label: summary.compactLabel,
                tooltip: "\(summary.identityLabel) · \(summary.metricLabel) · "
                    + "\(summary.percentUsed)% used\(staleSuffix)"
            )
        case .iconOnly:
            return Self(
                label: "",
                tooltip: "\(summary.identityLabel) · \(summary.metricLabel) · "
                    + "\(summary.percentUsed)% used\(staleSuffix)"
            )
        }
    }
}
