import Foundation
import OpenUsageLinuxCore

enum PanelUsagePresentation {
    static func configuration(
        snapshots: [ProviderUsageSnapshot],
        pins: PanelMetricPins,
        style: MenuBarStyle,
        displayMode: TrayUsageDisplayMode
    ) -> StatusNotifierItemConfiguration {
        let pinnedMetrics = selectedMetrics(from: snapshots, pins: pins)
        guard !pinnedMetrics.isEmpty else {
            return .usage(snapshots: snapshots, displayMode: displayMode)
        }

        let displayedMetrics: [PinnedPanelMetric]
        switch style {
        case .text:
            displayedMetrics = pinnedMetrics
        case .bars:
            displayedMetrics = Array(pinnedMetrics.filter { $0.fraction != nil }.prefix(4))
        }
        guard !displayedMetrics.isEmpty else {
            return .usage(snapshots: snapshots, displayMode: displayMode)
        }

        let tooltip = displayedMetrics.map(\.tooltip).joined(separator: " | ")
        guard displayMode == .mostUrgent else {
            return .init(label: "", tooltip: tooltip)
        }

        let label: String
        switch style {
        case .text:
            label = textLabel(for: displayedMetrics)
        case .bars:
            label = displayedMetrics.compactMap(\.fraction).map(bar).joined(separator: " ")
        }
        return .init(title: label, label: label, tooltip: tooltip)
    }

    private static func selectedMetrics(
        from snapshots: [ProviderUsageSnapshot],
        pins: PanelMetricPins
    ) -> [PinnedPanelMetric] {
        var providerOrder: [String] = []
        var seenProviders: Set<String> = []
        for snapshot in snapshots where seenProviders.insert(snapshot.providerID).inserted {
            providerOrder.append(snapshot.providerID)
        }

        return providerOrder.flatMap { providerID in
            let providerSnapshots = snapshots.filter { $0.providerID == providerID }
            return pins.pins(for: providerID).compactMap { key in
                selectedMetric(for: key, snapshots: providerSnapshots)
            }
        }
    }

    private static func selectedMetric(
        for key: MetricPreferenceKey,
        snapshots: [ProviderUsageSnapshot]
    ) -> PinnedPanelMetric? {
        let candidates = snapshots.flatMap { snapshot in
            snapshot.metrics.compactMap { metric -> PinnedPanelMetric? in
                guard MetricPreferenceKey(metric: metric) == key else { return nil }
                return PinnedPanelMetric(snapshot: snapshot, metric: metric)
            }
        }
        return candidates.max { lhs, rhs in
            switch (lhs.fraction, rhs.fraction) {
            case let (left?, right?):
                left < right
            case (nil, _?):
                true
            default:
                false
            }
        }
    }

    private static func textLabel(for metrics: [PinnedPanelMetric]) -> String {
        var providerOrder: [String] = []
        var valuesByProvider: [String: [String]] = [:]
        var namesByProvider: [String: String] = [:]
        for metric in metrics {
            if valuesByProvider[metric.providerID] == nil {
                providerOrder.append(metric.providerID)
            }
            valuesByProvider[metric.providerID, default: []].append(metric.displayValue)
            namesByProvider[metric.providerID] = metric.providerName
        }
        return providerOrder.map { providerID in
            let values = valuesByProvider[providerID, default: []].joined(separator: " ")
            return "\(namesByProvider[providerID] ?? providerID) \(values)"
        }.joined(separator: " · ")
    }

    private static func bar(_ fraction: Double) -> String {
        let levels = Array("▁▂▃▄▅▆▇█")
        let clamped = min(max(fraction, 0), 1)
        let index = Int((clamped * Double(levels.count - 1)).rounded())
        return String(levels[index])
    }
}

private struct PinnedPanelMetric {
    let providerID: String
    let providerName: String
    let accountLabel: String?
    let metricLabel: String
    let displayValue: String
    let fraction: Double?
    let staleReason: String?

    init(snapshot: ProviderUsageSnapshot, metric: UsageMetric) {
        providerID = snapshot.providerID
        providerName = snapshot.displayName
        accountLabel = snapshot.accountLabel
        metricLabel = metric.label
        fraction = metric.fraction
        staleReason = snapshot.errorMessage
        if let fraction {
            displayValue = "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
        } else if let detail = metric.detail, !detail.isEmpty {
            displayValue = detail
        } else {
            displayValue = String(format: "%.0f", metric.used)
        }
    }

    var tooltip: String {
        let identity = [providerName, accountLabel].compactMap { $0 }.joined(separator: " · ")
        let staleSuffix = staleReason.map { " · Stale — \($0)" } ?? ""
        return "\(identity) · \(metricLabel) · \(displayValue) used\(staleSuffix)"
    }
}
