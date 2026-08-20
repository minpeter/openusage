import Adwaita
import Foundation
import OpenUsageLinuxCore

/// Providers view: one boxed list of provider/account rows with disclosure
/// into complete metric details. The row tree is persistent — rows survive
/// refreshes, keep their expansion state, and only the metric cluster of a
/// changed snapshot is rebuilt.
@MainActor
final class ProvidersView {
    let root: ScrolledWindow

    let content = Box(orientation: GTK_ORIENTATION_VERTICAL, spacing: GNOMEStyle.sectionSpacing)
    private let group = PreferencesGroup(title: "Connected Accounts")
    private let emptyPage: StatusPage
    private var rows: [String: ProviderRow] = [:]
    private var displayedInstanceIDs: [String] = []
    private var metricPresentationSettings = GNOMEMetricPresentationSettings()
    private var onRefresh: () -> Void = {}
    private var onRenameProvider: (String, String) -> Void = { _, _ in }

    init() {
        root = ScrolledWindow()
        root.setPolicy(horizontal: GTK_POLICY_NEVER, vertical: GTK_POLICY_AUTOMATIC)
        root.kineticScrolling = true

        content.setMargins(GNOMEStyle.outerMargin)
        group.addCSSClass(GNOMEProviderRowLayout.groupCSSClass)
        group.description = "Quotas, spend, and reset windows for every connected account."

        emptyPage = StatusPage(
            title: "No Providers Connected",
            description: "Sign in on this machine with Claude Code or Codex, then refresh. "
                + "OpenUsage reads the credentials they already store.",
            iconName: "system-users-symbolic"
        )

        let clamp = Clamp()
        clamp.maximumSize = GNOMEStyle.contentClamp
        clamp.tighteningThreshold = GNOMEStyle.clampTightening
        clamp.child = content
        root.child = clamp
    }

    func setRefreshHandler(_ handler: @escaping @MainActor () -> Void) {
        onRefresh = handler
        let button = Button(label: "Check Again", onClicked: { [weak self] in self?.onRefresh() })
        button.addCSSClass(.suggestedAction)
        button.addCSSClass(.pill)
        button.halign = GTK_ALIGN_CENTER
        button.setAccessibleLabel("Check for provider credentials again")
        emptyPage.child = button
    }

    func setRenameHandler(
        _ handler: @escaping @MainActor (String, String) -> Void
    ) {
        onRenameProvider = handler
    }

    /// Updates the row tree in place. `snapshots` must already be ordered.
    func update(
        snapshots: [ProviderUsageSnapshot],
        isRefreshing: Bool,
        metricPresentationSettings: GNOMEMetricPresentationSettings,
        density: DensitySetting,
        metricLayouts: [String: ProviderMetricLayout]
    ) {
        self.metricPresentationSettings = metricPresentationSettings
        let densityMetrics = density.metrics
        content.spacing = densityMetrics.sectionSpacing
        content.setMargins(densityMetrics.outerMargin)
        let showEmpty = snapshots.isEmpty
        emptyPage.visible = showEmpty
        group.visible = !showEmpty
        if content.firstChild == nil {
            content.append(GNOMEStyle.pageHeader(
                title: "Providers",
                description: "Accounts, quota windows, model usage, and quick links."
            ))
            content.append(emptyPage)
            content.append(group)
        }
        guard !showEmpty else {
            displayedInstanceIDs.compactMap { rows[$0] }.forEach { group.remove($0.expander) }
            displayedInstanceIDs = []
            rows.removeAll()
            return
        }

        let uniqueSnapshots = ProviderSnapshotPresentation.uniqueCards(snapshots)
        let seen = uniqueSnapshots.map(\.instanceID)
        for (id, row) in rows where !seen.contains(id) {
            group.remove(row.expander)
            rows.removeValue(forKey: id)
        }
        var orderedRows: [ProviderRow] = []
        var seenRows: Set<ObjectIdentifier> = []
        for snapshot in uniqueSnapshots {
            let row = rows[snapshot.instanceID] ?? insertRow(for: snapshot)
            let identity = ObjectIdentifier(row)
            guard seenRows.insert(identity).inserted else { continue }
            orderedRows.append(row)
            row.update(
                snapshot: snapshot,
                metricPresentationSettings: metricPresentationSettings,
                density: density,
                metricLayout: metricLayouts[snapshot.providerID] ?? .init()
            )
            if DemoFixtures.expandProviders {
                row.expander.expanded = true
            }
        }
        let nextIDs = orderedRows.map(\.instanceID)
        if displayedInstanceIDs != nextIDs {
            displayedInstanceIDs.compactMap { rows[$0] }.forEach { group.remove($0.expander) }
            orderedRows.forEach { group.add($0.expander) }
            displayedInstanceIDs = nextIDs
        }
    }

    private func insertRow(for snapshot: ProviderUsageSnapshot) -> ProviderRow {
        let row = ProviderRow(
            instanceID: snapshot.instanceID,
            providerID: snapshot.providerID,
            displayName: snapshot.displayName
        ) {
            [weak self] in self?.onRefresh()
        } onRename: { [weak self] name in
            self?.onRenameProvider(snapshot.providerID, name)
        }
        rows[snapshot.instanceID] = row
        return row
    }
}

/// One provider/account row: avatar, name, identity subtitle, state message, and a
/// disclosure with every metric, quick links, and stale/error annotations.
@MainActor
private final class ProviderRow {
    let instanceID: String
    let expander: ExpanderRow

    private let stateIcon = Image()
    private let detail = Box(orientation: GTK_ORIENTATION_VERTICAL, spacing: GNOMEStyle.sectionSpacing)
    private let refreshedLabel = Label("")
    private let onRetry: () -> Void
    private let onRename: (String) -> Void
    private let renameEntry = EntryRow()
    private let contextPopover = Popover()
    private let menuButton = MenuButton(icon: .openMenu)
    private var lastSnapshot: ProviderUsageSnapshot?
    private var lastMetricPresentationSettings: GNOMEMetricPresentationSettings?
    private var lastDensity: DensitySetting?
    private var lastMetricLayout: ProviderMetricLayout?
    private var densityMetrics = DensitySetting.regular.metrics
    private var connections: [SignalConnection] = []

    init(
        instanceID: String,
        providerID: String,
        displayName: String,
        onRetry: @escaping @MainActor () -> Void,
        onRename: @escaping @MainActor (String) -> Void
    ) {
        self.instanceID = instanceID
        self.onRetry = onRetry
        self.onRename = onRename
        expander = ExpanderRow(title: "")
        expander.addCSSClass(GNOMEProviderRowLayout.cssClass)
        expander.titleLines = GNOMEProviderRowLayout.titleLines
        expander.subtitleLines = GNOMEProviderRowLayout.subtitleLines
        expander.addPrefix(ProviderIcon.make(providerID: providerID, displayName: displayName))

        let suffix = Box(orientation: GTK_ORIENTATION_HORIZONTAL, spacing: GNOMEStyle.controlSpacing)
        suffix.valign = GTK_ALIGN_CENTER
        stateIcon.valign = GTK_ALIGN_CENTER
        suffix.append(stateIcon)

        renameEntry.title = "Provider Name"
        renameEntry.text = displayName
        let actions = Box(
            orientation: GTK_ORIENTATION_VERTICAL,
            spacing: GNOMEStyle.rowSpacing
        )
        actions.setMargins(GNOMEStyle.sectionSpacing)
        actions.append(renameEntry)
        let renameButton = Button(label: "Rename Provider", onClicked: { [weak self] in
            guard let self else { return }
            self.contextPopover.popdown()
            self.onRename(self.renameEntry.text)
        })
        renameButton.setAccessibleLabel("Save provider name")
        actions.append(renameButton)
        let resetButton = Button(label: "Use Default Name", onClicked: { [weak self] in
            guard let self else { return }
            self.contextPopover.popdown()
            self.onRename("")
        })
        resetButton.setAccessibleLabel("Restore default provider name")
        actions.append(resetButton)
        contextPopover.child = actions

        menuButton.setPopover(contextPopover)
        menuButton.setSizeRequest(
            width: GNOMEStyle.minimumTargetHeight,
            height: GNOMEStyle.minimumTargetHeight
        )
        menuButton.setAccessibleLabel("Actions for \(displayName)")
        suffix.append(menuButton)
        expander.addSuffix(suffix)

        detail.setMargins(GNOMEStyle.sectionSpacing)
        expander.addRow(detail)
        refreshedLabel.xalign = 0
        refreshedLabel.addCSSClass(.caption)
        refreshedLabel.addCSSClass(.dimLabel)
    }

    func update(
        snapshot: ProviderUsageSnapshot,
        metricPresentationSettings: GNOMEMetricPresentationSettings,
        density: DensitySetting,
        metricLayout: ProviderMetricLayout
    ) {
        refreshedLabel.text = GNOMEFormat.relativeRefresh(snapshot.refreshedAt)
        if let lastSnapshot,
           snapshot.hasSameDisplayContent(as: lastSnapshot),
           metricPresentationSettings == lastMetricPresentationSettings,
           density == lastDensity,
           metricLayout == lastMetricLayout
        {
            self.lastSnapshot = snapshot
            return
        }
        lastSnapshot = snapshot
        lastMetricPresentationSettings = metricPresentationSettings
        lastDensity = density
        lastMetricLayout = metricLayout
        densityMetrics = density.metrics
        detail.spacing = densityMetrics.sectionSpacing
        detail.setMargins(densityMetrics.sectionSpacing)

        expander.title = snapshot.displayName
        renameEntry.text = snapshot.displayName
        menuButton.setAccessibleLabel("Actions for \(snapshot.displayName)")
        expander.subtitle = GNOMEProviderRowLayout.subtitle(
            accountLabel: snapshot.accountLabel,
            plan: snapshot.plan,
            collapsedStatus: collapsedStatus(for: snapshot)
        )

        if snapshot.errorMessage != nil {
            stateIcon.iconName = "dialog-error-symbolic"
            stateIcon.addCSSClass(.error)
            stateIcon.removeCSSClass("warning")
            stateIcon.visible = true
            stateIcon.setAccessibleLabel("Provider error")
        } else if snapshot.warning != nil {
            stateIcon.iconName = "dialog-warning-symbolic"
            stateIcon.addCSSClass(.warning)
            stateIcon.removeCSSClass("error")
            stateIcon.visible = true
            stateIcon.setAccessibleLabel("Provider warning")
        } else {
            stateIcon.visible = false
        }

        rebuildDetail(
            snapshot,
            metricPresentationSettings: metricPresentationSettings,
            metricLayout: metricLayout
        )
    }

    private func stateSummary(_ snapshot: ProviderUsageSnapshot) -> String {
        if let error = snapshot.errorMessage { return error }
        if let warning = snapshot.warning { return warning }
        return "Usage up to date"
    }

    private func collapsedStatus(for snapshot: ProviderUsageSnapshot) -> String? {
        if let error = snapshot.errorMessage {
            return collapsedError(error)
        }
        return snapshot.warning
    }

    private func collapsedError(_ error: String) -> String {
        if error.contains("401") {
            return "HTTP 401 · Check credentials"
        }
        if error.contains("403") {
            return "HTTP 403 · Access denied"
        }
        return "Provider error · Open for details"
    }

    private func rebuildDetail(
        _ snapshot: ProviderUsageSnapshot,
        metricPresentationSettings: GNOMEMetricPresentationSettings,
        metricLayout: ProviderMetricLayout
    ) {
        connections.forEach { $0.disconnect() }
        connections.removeAll(keepingCapacity: true)
        while let child = detail.firstChild {
            detail.remove(child)
        }

        let stale = snapshot.errorMessage != nil && !snapshot.metrics.isEmpty
        if stale, let error = snapshot.errorMessage {
            detail.append(annotationRow(
                icon: "dialog-warning-symbolic", cssClass: .warning,
                message: "Showing the last successful values. \(error)"))
        } else if let error = snapshot.errorMessage {
            detail.append(annotationRow(
                icon: "dialog-error-symbolic", cssClass: .error,
                message: actionableError(providerID: snapshot.providerID, message: error)))
        }

        if let warning = snapshot.warning {
            detail.append(annotationRow(
                icon: "dialog-information-symbolic", cssClass: .warning, message: warning))
        }

        var reconciledLayout = metricLayout
        reconciledLayout.reconcile(with: snapshot.metrics)
        let displayedMetrics =
            reconciledLayout.displayedMetrics(from: snapshot.metrics, in: .alwaysVisible)
            + reconciledLayout.displayedMetrics(from: snapshot.metrics, in: .onDemand)
        for metric in displayedMetrics {
            detail.append(MetricViews.widget(
                for: metric,
                providerName: snapshot.displayName,
                metricPresentationSettings: metricPresentationSettings
            ))
        }

        if snapshot.errorMessage == nil && snapshot.metrics.isEmpty {
            let label = Label("No quota metrics were returned.")
            label.xalign = 0
            label.wrap = true
            label.addCSSClass(.dimLabel)
            detail.append(label)
        }

        for link in snapshot.links {
            detail.append(linkRow(link))
        }

        detail.append(refreshedLabel)
    }

    private func annotationRow(icon: String, cssClass: CSSClass, message: String) -> Widget {
        let row = Box(
            orientation: GTK_ORIENTATION_HORIZONTAL,
            spacing: densityMetrics.controlSpacing
        )
        row.setSizeRequest(height: densityMetrics.minimumTargetHeight)

        let image = Image(iconName: icon)
        image.addCSSClass(cssClass)
        image.valign = GTK_ALIGN_CENTER
        row.append(image)

        let label = Label(message)
        label.wrap = true
        label.xalign = 0
        label.hexpand = true
        label.addCSSClass(cssClass)
        row.append(label)

        let retry = Button(label: "Retry", onClicked: { [weak self] in self?.onRetry() })
        retry.addCSSClass(.flat)
        retry.valign = GTK_ALIGN_CENTER
        retry.setAccessibleLabel("Retry refreshing this provider")
        row.append(retry)
        return row
    }

    private func linkRow(_ link: ProviderLink) -> Widget {
        let row = ActionRow(title: link.label)
        row.subtitle = link.url
        row.addSuffix(Image(iconName: "adw-external-link-symbolic"))
        row.setAccessibleLabel("Open \(link.label) in the browser")
        connections.append(row.onActivated {
            UriLauncher(uri: link.url).launch()
        })
        return row
    }

    private func actionableError(providerID: String, message: String) -> String {
        if providerID == "claude", message.contains("credentials were not found") {
            return "Sign in with Claude Code, then refresh. Credentials were not found in ~/.claude."
        }
        if providerID == "codex", message.contains("HTTP 401") {
            return "Your Codex session expired. Sign in with Codex again, then refresh."
        }
        return message
    }
}
