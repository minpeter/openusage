import Adwaita
import Foundation
import OpenUsageLinuxCore

// MARK: - Section data

extension OverviewView {
    /// Aggregates the Today / Yesterday / Last 30 Days spend rows the core's
    /// spend aggregator emits as `values` metrics, summed across providers.
    func spendSummary(_ snapshots: [ProviderUsageSnapshot]) -> [(String, Double)] {
        var totals: [(String, Double)] = []
        for period in ["Today", "Yesterday", "Last 30 Days"] {
            let sum = snapshots.reduce(0.0) { partial, snapshot in
                partial + snapshot.metrics
                    .filter { $0.kind == .values && $0.label == period }
                    .reduce(0.0) { $0 + $1.used }
            }
            if sum > 0 {
                totals.append((period, sum))
            }
        }
        return totals
    }

    /// Progress metrics closest to exhaustion, most urgent first.
    func urgentQuotas(
        _ snapshots: [ProviderUsageSnapshot],
        metricLayouts: [String: ProviderMetricLayout]
    )
        -> [(provider: String, metric: UsageMetric)] {
        snapshots
            .filter { $0.errorMessage == nil }
            .flatMap { snapshot in
                var layout = metricLayouts[snapshot.providerID] ?? .init()
                layout.reconcile(with: snapshot.metrics)
                return layout.displayedMetrics(
                    from: snapshot.metrics,
                    in: .alwaysVisible
                )
                    .filter { $0.kind == .progress && $0.fraction != nil }
                    .map { (provider: snapshot.displayName, metric: $0) }
            }
            .sorted { ($0.metric.fraction ?? 0) > ($1.metric.fraction ?? 0) }
            .prefix(4)
            .map { $0 }
    }
}
