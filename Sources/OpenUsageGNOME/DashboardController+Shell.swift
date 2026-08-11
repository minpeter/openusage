import Adwaita
import Foundation
import OpenUsageLinuxCore

// MARK: - Shell

extension DashboardController {
    func buildShell() {
        headerSwitcher.stack = stack
        headerSwitcher.policy = .wide

        let header = HeaderBar()
        header.titleWidget = headerSwitcher

        let summaryBox = Box(
            orientation: GTK_ORIENTATION_HORIZONTAL,
            spacing: GNOMEStyle.controlSpacing
        )
        toolbarSummaryProviderLabel.addCSSClass(.caption)
        toolbarSummaryValueLabel.addCSSClass(.numeric)
        toolbarSummaryValueLabel.addCSSClass(.heading)
        summaryBox.append(toolbarSummaryProviderLabel)
        summaryBox.append(toolbarSummaryValueLabel)
        toolbarSummaryButton.child = summaryBox
        toolbarSummaryButton.addCSSClass(.raised)
        toolbarSummaryButton.addCSSClass(.pill)
        toolbarSummaryButton.tooltipText = "Open Overview"
        toolbarSummaryButton.setAccessibleLabel("Usage summary")
        header.packStart(toolbarSummaryButton)

        refreshButton.addCSSClass(.flat)
        refreshButton.setAccessibleLabel("Refresh usage")
        header.packEnd(refreshButton)

        let menu = GMenuRef()
        menu.append("Refresh", action: "app.refresh")
        menu.append("About OpenUsage", action: "app.about")
        let menuButton = MenuButton(icon: .openMenu)
        menuButton.addCSSClass(.flat)
        menuButton.setMenuModel(menu)
        menuButton.setAccessibleLabel("Main menu")
        header.packEnd(menuButton)

        let views: [Widget] = [overview.root, providersView.root, historyView.root, settingsView.root]
        for (page, view) in zip(Self.pageOrder, views) {
            stack.addTitledWithIcon(view, name: page.name, title: page.title, iconName: page.icon)
        }
        stack.vexpand = true

        switcherBar.stack = stack
        let content = Box(orientation: GTK_ORIENTATION_VERTICAL, spacing: 0)
        content.append(stack)
        content.append(switcherBar)

        toastOverlay.child = content
        window.setContent(ToolbarView(content: toastOverlay, topBar: header))

        connections.append(refreshButton.onClicked { [weak self] in
            self?.refresh()
        })
        connections.append(toolbarSummaryButton.onClicked { [weak self] in
            self?.stack.visibleChildName = "overview"
        })
    }

    func buildActions() {
        let refreshAction = SimpleAction(name: "refresh") { [weak self] in
            self?.refresh()
        }
        let aboutAction = SimpleAction(name: "about") { [weak self] in
            guard let self else { return }
            self.application.showAboutDialog(
                parent: self.window,
                name: "OpenUsage",
                version: Self.appVersion,
                website: "https://github.com/minpeter/openusage",
                issueUrl: "https://github.com/minpeter/openusage/issues",
                comments: "AI subscription usage at a glance, natively on GNOME."
            )
        }
        let shareAction = SimpleAction(name: "share-total-spend") { [weak self] in
            self?.overview.shareCurrentSpend()
        }
        let spendRateAction = SimpleAction(name: "spend-cost-per-mtok") { [weak self] in
            self?.overview.selectTotalSpendMetric(.costPerMillionTokens)
        }
        let spendTokensAction = SimpleAction(name: "spend-tokens") { [weak self] in
            self?.overview.selectTotalSpendMetric(.tokens)
        }
        let chooseSyncDirectoryAction = SimpleAction(name: "choose-sync-directory") { [weak self] in
            self?.chooseSyncDirectory()
        }
        let importUsageAction = SimpleAction(name: "import-usage") { [weak self] in
            self?.chooseUsageImport()
        }
        let exportJSONAction = SimpleAction(name: "export-json") { [weak self] in
            self?.exportSnapshots(format: .json)
        }
        let exportCSVAction = SimpleAction(name: "export-csv") { [weak self] in
            self?.exportSnapshots(format: .csv)
        }
        let storeAPIKeyAction = SimpleAction(name: "store-api-key") { [weak self] in
            guard let provider = Self.qaAPIKeyProvider,
                  let value = ProcessInfo.processInfo.environment["OPENUSAGE_API_KEY_VALUE"]
            else {
                return
            }
            self?.storeAPIKey(value, for: provider)
        }
        let clearAPIKeyAction = SimpleAction(name: "clear-api-key") { [weak self] in
            guard let provider = Self.qaAPIKeyProvider else { return }
            self?.clearAPIKey(for: provider)
        }
        let saveProxyAction = SimpleAction(name: "save-proxy") { [weak self] in
            let environment = ProcessInfo.processInfo.environment
            guard let url = environment["OPENUSAGE_PROXY_URL"] else { return }
            self?.saveProxySettings(
                enabled: environment["OPENUSAGE_PROXY_ENABLED"] != "0",
                url: url,
                bypassText: environment["OPENUSAGE_PROXY_BYPASS"] ?? ""
            )
        }
        let setLogLevelAction = SimpleAction(name: "set-log-level") { [weak self] in
            guard let raw = ProcessInfo.processInfo.environment["OPENUSAGE_LOG_LEVEL"],
                  let level = LinuxLogLevel(rawValue: raw)
            else {
                return
            }
            self?.settingsView.onLogLevelChanged(level)
        }
        let showDataSettingsAction = SimpleAction(name: "show-data-settings") { [weak self] in
            self?.settingsView.revealDataSettings()
        }
        let performanceProbeAction = SimpleAction(name: "run-performance-probe") { [weak self] in
            self?.runPerformanceProbe()
        }
        retainedActions = [
            refreshAction,
            aboutAction,
            shareAction,
            spendRateAction,
            spendTokensAction,
            chooseSyncDirectoryAction,
            importUsageAction,
            exportJSONAction,
            exportCSVAction,
            storeAPIKeyAction,
            clearAPIKeyAction,
            saveProxyAction,
            setLogLevelAction,
            showDataSettingsAction,
            performanceProbeAction,
        ]
        for action in retainedActions {
            application.addAction(action)
        }

        let shortcuts = ShortcutController()
        shortcuts.addShortcut("<Control>r") { [weak self] in
            self?.refresh()
            return true
        }
        shortcuts.addShortcut("<Control>q") { [application] in
            application.quit()
            return true
        }
        for (index, page) in Self.pageOrder.enumerated() {
            shortcuts.addShortcut("<Control>\(index + 1)") { [weak self] in
                self?.stack.visibleChildName = page.name
                return true
            }
        }
        window.addController(shortcuts)
    }

    /// Narrow widths move navigation into a bottom ViewSwitcherBar and hide
    /// the header switcher, per the GNOME adaptive view-switcher pattern.
    func installBreakpoint() {
        let narrow = Breakpoint.maxWidth(GNOMEStyle.narrowBreakpointWidth, unit: .px)
        narrow.addSetter(switcherBar, property: .custom("reveal"), value: true)
        narrow.addSetter(headerSwitcher, property: .visible, value: false)
        narrow.addSetter(toolbarSummaryButton, property: .visible, value: false)
        narrow.addSetter(overview.spendGroup, property: .custom("title"), value: "")
        for page in [overview.root, providersView.root, historyView.root, settingsView.root] {
            narrow.addSetter(page, property: .custom("margin-bottom"), value: 56)
        }
        // Balance the transfer-full consumption below with the wrapper's ref.
        _ = g_object_ref(narrow.gobjectPointer)
        adw_application_window_add_breakpoint(window.adwWindowPointer, narrow.opaquePointer)
        breakpoint = narrow
    }
}
