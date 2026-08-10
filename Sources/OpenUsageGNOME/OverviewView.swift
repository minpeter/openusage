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
    let spendGroup = PreferencesGroup(title: "Spend")
    private let spendButtons = [
        ToggleButton(label: "Today"),
        ToggleButton(label: "Yesterday"),
        ToggleButton(label: "30 Days"),
    ]
    private let urgentGroup = PreferencesGroup(title: "Most Urgent Quotas")
    private let healthGroup = PreferencesGroup(title: "Provider Health")
    var onRefresh: () -> Void = {}
    private var currentSpend: [(String, Double)] = []
    private var selectedSpendPeriod = "Today"
    private var connections: [SignalConnection] = []
    private var urgentRows: [Widget] = []
    var metricPresentationSettings = GNOMEMetricPresentationSettings()

    init() {
        root = ScrolledWindow()
        root.setPolicy(horizontal: GTK_POLICY_NEVER, vertical: GTK_POLICY_AUTOMATIC)
        root.kineticScrolling = true

        content.setMargins(GNOMEStyle.outerMargin)
        let spendSelector = Box(orientation: GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        spendSelector.addCSSClass(.linked)
        let periods = ["Today", "Yesterday", "Last 30 Days"]
        for (index, button) in spendButtons.enumerated() {
            if index > 0 {
                button.setGroup(spendButtons[0])
            }
            button.active = index == 0
            let period = periods[index]
            connections.append(button.onToggled { [weak self, weak button] in
                guard let self, button?.active == true else { return }
                self.selectedSpendPeriod = period
                self.renderSpend()
            })
            spendSelector.append(button)
        }
        spendGroup.headerSuffix = spendSelector

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

    /// Rebuilds the three sections. `snapshots` must already be ordered.
    func update(
        snapshots: [ProviderUsageSnapshot],
        isRefreshing: Bool,
        metricPresentationSettings: GNOMEMetricPresentationSettings
    ) {
        self.metricPresentationSettings = metricPresentationSettings
        while let child = content.firstChild {
            content.remove(child)
        }

        if snapshots.isEmpty {
            rebuildOnboarding(isRefreshing: isRefreshing)
            return
        }

        let spend = spendSummary(snapshots)
        currentSpend = spend
        spendGroup.visible = !spend.isEmpty
        renderSpend()

        let urgent = urgentQuotas(snapshots)
        urgentGroup.visible = !urgent.isEmpty
        replaceUrgentRows(urgent.map(urgentRow(_:)))

        replaceRows(in: healthGroup, rows: snapshots.map(healthRow(_:)))

        content.append(spendGroup)
        content.append(urgentGroup)
        content.append(healthGroup)
    }

    private func replaceUrgentRows(_ rows: [Widget]) {
        urgentRows.forEach(urgentGroup.remove)
        rows.forEach(urgentGroup.add)
        urgentRows = rows
    }

    private func renderSpend() {
        while let existing = spendGroup.getRow(0) {
            spendGroup.remove(existing)
        }
        if let entry = currentSpend.first(where: { $0.0 == selectedSpendPeriod }) {
            spendGroup.add(spendRow(entry))
        } else {
            spendGroup.add(ActionRow(title: "No spend recorded for this period"))
        }
    }
}
