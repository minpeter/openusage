import Adwaita
import OpenUsageLinuxCore

extension DashboardController {
    func updateToolbarSummary(
        snapshots: [ProviderUsageSnapshot],
        isRefreshing: Bool
    ) {
        toolbarSummaryValueLabel.removeCSSClass(.warning)
        toolbarSummaryValueLabel.removeCSSClass(.error)

        if let summary = UsageToolbarSummary.mostUrgent(in: snapshots) {
            toolbarSummaryProviderLabel.text = summary.providerName
            toolbarSummaryValueLabel.text = "\(summary.percentUsed)%"
            toolbarSummaryButton.tooltipText =
                "Open Overview · \(summary.metricLabel) · \(summary.percentUsed)% used"
            toolbarSummaryButton.setAccessibleLabel("Open Overview, \(summary.compactLabel)")
            toolbarSummaryButton.setAccessibleDescription(summary.accessibilityDescription)
            switch summary.severity {
            case .normal:
                break
            case .warning:
                toolbarSummaryValueLabel.addCSSClass(.warning)
            case .critical:
                toolbarSummaryValueLabel.addCSSClass(.error)
            }
        } else {
            toolbarSummaryProviderLabel.text = "Usage"
            toolbarSummaryValueLabel.text = "—"
            toolbarSummaryButton.tooltipText = "Open Overview · No active quotas"
            toolbarSummaryButton.setAccessibleLabel("Open Overview, no active usage quotas")
            toolbarSummaryButton.setAccessibleDescription("No healthy progress quotas are available")
        }

        toolbarSummaryButton.opacity = isRefreshing ? 0.64 : 1
    }
}
