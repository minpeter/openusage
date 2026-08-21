import Adwaita
import Foundation
import OpenUsageLinuxCore

/// Overview view: spend summary, provider health, and the most urgent quota
/// windows. Answers the first-screen questions from DESIGN.md — which
/// account is connected, how much of each limit is used, and when it resets.
/// Onboarding, section data, and row builders live in OverviewView+*.swift.
@MainActor
final class OverviewView {
    let root: ScrolledWindow

    let content = Box(orientation: GTK_ORIENTATION_VERTICAL, spacing: GNOMEStyle.sectionSpacing)
    let statusPage = StatusPage(
        title: "Welcome to OpenUsage",
        description: "Check every AI account, quota, and cost without opening provider "
            + "websites. Sign in with Claude Code or Codex on this machine, then refresh.",
        iconName: "view-grid-symbolic"
    )
    let spinnerBox = Box(orientation: GTK_ORIENTATION_VERTICAL, spacing: GNOMEStyle.sectionSpacing)
    private let totalSpendView = TotalSpendView()
    private let urgentGroup = PreferencesGroup(title: UsageUrgencyCopy.mostUrgent)
    let healthGroup = PreferencesGroup(title: "Provider Health")
    var onRefresh: () -> Void = {}
    private var urgentRows: [Widget] = []
    var healthRows: [Widget] = []
    var metricPresentationSettings = GNOMEMetricPresentationSettings()
    var density: DensitySetting = .regular

    init() {
        root = ScrolledWindow()
        root.setPolicy(horizontal: GTK_POLICY_NEVER, vertical: GTK_POLICY_AUTOMATIC)
        root.kineticScrolling = true

        content.setMargins(GNOMEStyle.outerMargin)

        spinnerBox.valign = GTK_ALIGN_CENTER
        spinnerBox.halign = GTK_ALIGN_CENTER

        let clamp = Clamp()
        clamp.maximumSize = GNOMEStyle.contentClamp
        clamp.tighteningThreshold = GNOMEStyle.clampTightening
        clamp.child = content
        root.child = clamp
    }

    func setRefreshHandler(_ handler: @escaping @MainActor () -> Void) {
        onRefresh = handler
    }

    func setShareHandler(
        _ handler: @escaping @MainActor (BrandedShareCard) -> Void
    ) {
        totalSpendView.setShareHandler(handler)
    }

    func shareCurrentSpend() {
        totalSpendView.shareCurrent()
    }

    func showTotalSpendCopyFeedback() {
        totalSpendView.showCopyFeedback()
    }

    func selectTotalSpendMetric(_ metric: TotalSpendMetric) {
        totalSpendView.selectMetric(metric)
    }

    /// Rebuilds the three sections. `snapshots` must already be ordered.
    func update(
        snapshots: [ProviderUsageSnapshot],
        isRefreshing: Bool,
        metricPresentationSettings: GNOMEMetricPresentationSettings,
        density: DensitySetting,
        metricLayouts: [String: ProviderMetricLayout]
    ) {
        self.metricPresentationSettings = metricPresentationSettings
        self.density = density
        let densityMetrics = density.metrics
        content.spacing = densityMetrics.sectionSpacing
        content.setMargins(densityMetrics.outerMargin)
        spinnerBox.spacing = densityMetrics.sectionSpacing
        while let child = content.firstChild {
            content.remove(child)
        }

        let cards = ProviderSnapshotPresentation.uniqueCards(snapshots)
        if cards.isEmpty {
            rebuildOnboarding(isRefreshing: isRefreshing)
            return
        }

        totalSpendView.update(snapshots: cards)
        let hasSpend = !TotalSpendAnalytics.records(from: cards).isEmpty

        let urgent = urgentQuotas(cards, metricLayouts: metricLayouts)
        urgentGroup.visible = !urgent.isEmpty
        replaceUrgentRows(urgent.map(urgentRow(_:)))

        replaceHealthRows(cards.map(healthRow(_:)))

        content.append(GNOMEStyle.pageHeader(
            title: "Overview",
            description: GNOMEPageCopy.overviewDescription(hasSpend: hasSpend)
        ))
        content.append(totalSpendView.root)
        content.append(urgentGroup)
        content.append(healthGroup)
    }

    private func replaceUrgentRows(_ rows: [Widget]) {
        urgentRows.forEach(urgentGroup.remove)
        rows.forEach(urgentGroup.add)
        urgentRows = rows
    }

}
