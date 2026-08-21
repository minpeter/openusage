import Adwaita
import Foundation
import OpenUsageLinuxCore

/// Settings view: native preferences groups for appearance, refresh,
/// provider ordering, shortcuts, data/privacy, and about. Every control is
/// wired to a callback; the controller owns persistence and side effects.
/// The settings model lives in GNOMESettings.swift; signal wiring and the
/// provider-ordering group live in SettingsView+*.swift.
@MainActor
final class SettingsView {
    static let pageOrder: [(name: String, title: String, icon: String)] = [
        ("general", "General", "preferences-system-symbolic"),
        ("display", "Display", "video-display-symbolic"),
        ("providers", "Providers", "system-users-symbolic"),
        ("data", "Data", "folder-symbolic"),
    ]

    private let dialog = PreferencesDialog()
    private(set) var isPresented = false
    private var focusDataPageOnMap = false

    var onAppearanceChanged: (GNOMESettings.Appearance) -> Void = { _ in }
    var onTrayUsageDisplayModeChanged: (TrayUsageDisplayMode) -> Void = { _ in }
    var onMenuBarStyleChanged: (MenuBarStyle) -> Void = { _ in }
    var onWidgetDisplayModeChanged: (WidgetDisplayMode) -> Void = { _ in }
    var onResetDisplayModeChanged: (ResetDisplayMode) -> Void = { _ in }
    var onAlwaysShowPacingChanged: (Bool) -> Void = { _ in }
    var onDensityChanged: (DensitySetting) -> Void = { _ in }
    var onTimeFormatChanged: (TimeFormatSetting) -> Void = { _ in }
    var onNotificationTogglesChanged: (UsageNotificationToggles) -> Void = { _ in }
    var onRefreshScheduleChanged: (Bool, Int) -> Void = { _, _ in }
    var onProviderOrderChanged: ([String]) -> Void = { _ in }
    var onProviderVisibilityChanged: (String, Bool) -> Void = { _, _ in }
    var onMetricEnabledChanged: (String, MetricPreferenceKey, Bool) -> Void = { _, _, _ in }
    var onMetricSectionChanged: (
        String,
        MetricPreferenceKey,
        MetricVisibilitySection
    ) -> Void = { _, _, _ in }
    var onMetricMoved: (String, MetricPreferenceKey, Int) -> Void = { _, _, _ in }
    var onPanelPinChanged: (String, MetricPreferenceKey, Bool) -> Bool = { _, _, _ in false }
    var onLaunchAtLoginChanged: (Bool) -> Void = { _ in }
    var onAnalyticsChanged: (Bool) -> Void = { _ in }
    var onLocalAPIChanged: (Bool, Int) -> Void = { _, _ in }
    var onSyncDirectoryRequested: () -> Void = {}
    var onSyncDirectoryReset: () -> Void = {}
    var onImportRequested: () -> Void = {}
    var onExportRequested: (UsageExportFormat) -> Void = { _ in }
    var onAPIKeySave: (ManagedAPIKeyProvider, String) -> Void = { _, _ in }
    var onAPIKeyClear: (ManagedAPIKeyProvider) -> Void = { _ in }
    var onProxySave: (Bool, String, String) -> Void = { _, _, _ in }
    var onLogLevelChanged: (LinuxLogLevel) -> Void = { _ in }
    var onOpenLog: () -> Void = {}

    let appearanceRow: ComboRow
    let trayUsageDisplayRow: ComboRow
    let menuBarStyleRow: ComboRow
    let widgetDisplayModeRow: ComboRow
    let resetDisplayModeRow: ComboRow
    let alwaysShowPacingRow: SwitchRow
    let densityRow: ComboRow
    let timeFormatRow: ComboRow
    let almostOutRow: SwitchRow
    let cuttingItCloseRow: SwitchRow
    let willRunOutRow: SwitchRow
    let periodicRow: SwitchRow
    let intervalRow: SpinRow
    let launchRow = SwitchRow(title: "Launch at Login")
    let analyticsRow = SwitchRow(
        title: "Share Anonymous Usage",
        subtitle: "Send bounded feature counters without accounts, paths, errors, tokens, or usage values."
    )
    let apiRow = SwitchRow(
        title: "Local HTTP API",
        subtitle: "Serve usage data on the IPv4 loopback interface only."
    )
    let apiPortRow = SpinRow(title: "Port", min: 1_024, max: 65_535, step: 1)
    let syncDirectoryRow: ActionRow
    let defaultSyncPath: String
    let openRouterAPIKeyRow = PasswordEntryRow(title: "OpenRouter API Key")
    let zaiAPIKeyRow = PasswordEntryRow(title: "Z.ai API Key")
    let openRouterAPIKeyStatus = Label("Checking…")
    let zaiAPIKeyStatus = Label("Checking…")
    let proxyEnabledRow = SwitchRow(title: "Use Proxy")
    let proxyURLRow = PasswordEntryRow(title: "Proxy URL")
    let proxyBypassRow = EntryRow(title: "Bypass Hosts")
    let logLevelRow = ComboRow()
    let orderGroup = PreferencesGroup(
        title: "Provider Order",
        description: "Controls the order of providers in every view."
    )
    let metricCustomizationGroup = PreferencesGroup(
        title: "Metric Customization",
        description: "Enable, order, reveal on demand, and pin up to two metrics per provider."
    )
    let providersPage = PreferencesPage()
    var order: [String] = []
    var hiddenProviderIDs: Set<String> = []
    var providerNames: [String: String] = [:]
    var providerRows: [String: SwitchRow] = [:]
    var orderRowWidgets: [Widget] = []
    var metricHeaderRows: [Widget] = []
    var metricProviderGroups: [String: PreferencesGroup] = [:]
    var metricGroupRows: [String: [Widget]] = [:]
    var connections: [SignalConnection] = []
    var orderConnections: [SignalConnection] = []
    var metricConnections: [SignalConnection] = []
    var customizationSnapshots: [ProviderUsageSnapshot] = []
    var customizationSettings = GNOMESettings()
    var applyingSettings = false

    init(
        settings: GNOMESettings,
        cachePath: String,
        defaultSyncPath: String,
        version: String
    ) {
        self.defaultSyncPath = defaultSyncPath
        syncDirectoryRow = ActionRow(
            title: "Sync Directory",
            subtitle: settings.syncDirectoryPath ?? defaultSyncPath
        )

        // Appearance group
        appearanceRow = ComboRow(title: "Style")
        appearanceRow.setModel(StringList(["System", "Light", "Dark"]))
        let appearanceGroup = PreferencesGroup(
            title: "Appearance",
            description: "Follows the desktop unless overridden here. High-contrast and font "
                + "scaling always come from the system."
        )
        appearanceGroup.add(appearanceRow)

        trayUsageDisplayRow = ComboRow(title: "Show Usage As")
        trayUsageDisplayRow.setModel(StringList(["Most Urgent Usage", "Icon Only"]))
        let panelIndicatorGroup = PreferencesGroup(
            title: "Panel Indicator",
            description: "Choose whether the GNOME top panel shows the most urgent quota "
                + "next to the OpenUsage icon."
        )
        panelIndicatorGroup.add(trayUsageDisplayRow)

        menuBarStyleRow = ComboRow(title: "Panel Style")
        menuBarStyleRow.setModel(StringList(MenuBarStyle.allCases.map(\.label)))
        widgetDisplayModeRow = ComboRow(title: "Usage Values")
        widgetDisplayModeRow.setModel(StringList(WidgetDisplayMode.allCases.map(\.label)))
        resetDisplayModeRow = ComboRow(title: "Reset Times")
        resetDisplayModeRow.setModel(StringList(ResetDisplayMode.allCases.map(\.label)))
        alwaysShowPacingRow = SwitchRow(
            title: "Always Show Pacing",
            subtitle: "Show projected usage on healthy quotas as well as quotas near their limit."
        )
        densityRow = ComboRow(title: "Density")
        densityRow.setModel(StringList(DensitySetting.allCases.map(\.label)))
        timeFormatRow = ComboRow(title: "Time Format")
        timeFormatRow.setModel(StringList(TimeFormatSetting.allCases.map(\.label)))
        let displayGroup = PreferencesGroup(
            title: "Usage Display",
            description: "Control quota values, reset copy, pacing, and top-panel presentation."
        )
        displayGroup.add(menuBarStyleRow)
        displayGroup.add(widgetDisplayModeRow)
        displayGroup.add(resetDisplayModeRow)
        displayGroup.add(alwaysShowPacingRow)
        displayGroup.add(densityRow)
        displayGroup.add(timeFormatRow)

        almostOutRow = SwitchRow(
            title: UsageNotificationMilestone.almostOut.title,
            subtitle: UsageNotificationMilestone.almostOut.body
        )
        cuttingItCloseRow = SwitchRow(
            title: UsageNotificationMilestone.cuttingItClose.title,
            subtitle: UsageNotificationMilestone.cuttingItClose.body
        )
        willRunOutRow = SwitchRow(
            title: UsageNotificationMilestone.willRunOut.title,
            subtitle: UsageNotificationMilestone.willRunOut.body
        )
        let notificationGroup = PreferencesGroup(
            title: "Usage Notifications",
            description: "Alert once per reset window when quota risk worsens."
        )
        notificationGroup.add(almostOutRow)
        notificationGroup.add(cuttingItCloseRow)
        notificationGroup.add(willRunOutRow)

        // Refresh group
        periodicRow = SwitchRow(
            title: "Refresh Automatically",
            active: settings.periodicRefreshEnabled
        )
        intervalRow = SpinRow(
            title: "Refresh Interval (Minutes)",
            min: Double(GNOMESettings.minimumInterval),
            max: Double(GNOMESettings.maximumInterval),
            step: 1
        )
        intervalRow.value = Double(settings.refreshIntervalMinutes)
        let refreshGroup = PreferencesGroup(
            title: "Refresh",
            description: "A single periodic refresh runs while the window is open."
        )
        refreshGroup.add(periodicRow)
        refreshGroup.add(intervalRow)

        launchRow.active = settings.launchAtLogin ?? false
        let startupGroup = PreferencesGroup(
            title: "Startup",
            description: "Uses the desktop portal in Flatpak, with native systemd and XDG fallbacks."
        )
        startupGroup.add(launchRow)

        apiRow.active = settings.localAPIEnabled ?? false
        apiPortRow.value = Double(settings.localAPIPort ?? LoopbackHTTPServer.defaultPort)
        apiPortRow.sensitive = apiRow.active
        analyticsRow.active = settings.analyticsEnabled ?? true
        let apiGroup = PreferencesGroup(title: "Local API")
        apiGroup.add(apiRow)
        apiGroup.add(apiPortRow)

        // Shortcuts group
        let shortcutsGroup = PreferencesGroup(title: "Keyboard Shortcuts")
        shortcutsGroup.add(shortcutRow(title: "Refresh Usage", accelerator: "<Control>r"))
        shortcutsGroup.add(shortcutRow(title: "Show Overview", accelerator: "<Control>1"))
        shortcutsGroup.add(shortcutRow(title: "Show Providers", accelerator: "<Control>2"))
        shortcutsGroup.add(shortcutRow(title: "Preferences", accelerator: "<Control>comma"))
        shortcutsGroup.add(shortcutRow(title: "Quit", accelerator: "<Control>q"))

        // Data & privacy group
        let privacyGroup = PreferencesGroup(title: "Data &amp; Privacy")
        let cacheRow = ActionRow(title: "Snapshot Cache", subtitle: cachePath)
        cacheRow.subtitleSelectable = true
        privacyGroup.add(cacheRow)
        let secretsRow = ActionRow(
            title: "Credentials",
            subtitle: "Stored in the system Secret Service. They are never written to "
                + "settings or snapshot files."
        )
        privacyGroup.add(secretsRow)
        privacyGroup.add(analyticsRow)
        let syncDirectoryActions = Box(
            orientation: GTK_ORIENTATION_HORIZONTAL,
            spacing: GNOMEStyle.controlSpacing
        )
        syncDirectoryActions.addCSSClass(.linked)
        let chooseSyncDirectory = Button(label: "Choose…", onClicked: { [weak self] in
            self?.onSyncDirectoryRequested()
        })
        chooseSyncDirectory.addCSSClass(.flat)
        syncDirectoryActions.append(chooseSyncDirectory)
        let resetSyncDirectory = Button(label: "Default", onClicked: { [weak self] in
            self?.onSyncDirectoryReset()
        })
        resetSyncDirectory.addCSSClass(.flat)
        syncDirectoryActions.append(resetSyncDirectory)
        syncDirectoryRow.addSuffix(syncDirectoryActions)
        privacyGroup.add(syncDirectoryRow)
        let importRow = ActionRow(
            title: "Import Usage",
            subtitle: "Load a JSON usage export into the local snapshot cache."
        )
        let importButton = Button(label: "Import…", onClicked: { [weak self] in
            self?.onImportRequested()
        })
        importButton.addCSSClass(.flat)
        importRow.addSuffix(importButton)
        privacyGroup.add(importRow)
        let exportRow = ActionRow(
            title: "Export Usage",
            subtitle: "Save the current snapshots without credentials."
        )
        let exportActions = Box(
            orientation: GTK_ORIENTATION_HORIZONTAL,
            spacing: GNOMEStyle.controlSpacing
        )
        exportActions.addCSSClass(.linked)
        let exportJSON = Button(label: "JSON", onClicked: { [weak self] in
            self?.onExportRequested(.json)
        })
        exportJSON.addCSSClass(.flat)
        exportActions.append(exportJSON)
        let exportCSV = Button(label: "CSV", onClicked: { [weak self] in
            self?.onExportRequested(.csv)
        })
        exportCSV.addCSSClass(.flat)
        exportActions.append(exportCSV)
        exportRow.addSuffix(exportActions)
        privacyGroup.add(exportRow)

        let apiKeyGroup = PreferencesGroup(
            title: "API Keys",
            description: "Keys are stored in the system Secret Service, never in settings."
        )
        addAPIKeyRow(
            openRouterAPIKeyRow,
            status: openRouterAPIKeyStatus,
            provider: .openRouter
        )
        addAPIKeyRow(
            zaiAPIKeyRow,
            status: zaiAPIKeyStatus,
            provider: .zai
        )
        apiKeyGroup.add(openRouterAPIKeyRow)
        apiKeyGroup.add(zaiAPIKeyRow)

        let proxyGroup = PreferencesGroup(
            title: "Proxy",
            description: "Routes provider HTTP requests after restart. Supports http, https, and socks5."
        )
        proxyURLRow.text = settings.proxyURL ?? ""
        proxyBypassRow.text = settings.proxyBypassHosts.joined(separator: ", ")
        let proxySaveRow = ActionRow(
            title: "Apply Proxy Settings",
            subtitle: "Loopback addresses always bypass the proxy."
        )
        proxySaveRow.addSuffix(Button(label: "Save", onClicked: { [weak self] in
            guard let self else { return }
            self.onProxySave(
                self.proxyEnabledRow.active,
                self.proxyURLRow.text,
                self.proxyBypassRow.text
            )
        }))
        proxyGroup.add(proxyEnabledRow)
        proxyGroup.add(proxyURLRow)
        proxyGroup.add(proxyBypassRow)
        proxyGroup.add(proxySaveRow)

        logLevelRow.title = "Log Level"
        logLevelRow.setModel(StringList(LinuxLogLevel.allCases.map(\.label)))
        logLevelRow.selected = LinuxLogLevel.allCases.firstIndex(
            of: settings.logLevel
        ) ?? 0
        let advancedGroup = PreferencesGroup(
            title: "Advanced",
            description: "File logging applies immediately. Debug is opt-in."
        )
        advancedGroup.add(logLevelRow)
        let logFileRow = ActionRow(
            title: "Log File",
            subtitle: GNOMEAppLog.file.path
        )
        logFileRow.subtitleSelectable = true
        logFileRow.addSuffix(Button(label: "Open", onClicked: { [weak self] in
            self?.onOpenLog()
        }))
        advancedGroup.add(logFileRow)

        let updateDelivery = LinuxUpdateDelivery(
            environment: ProcessInfo.processInfo.environment
        )
        let updateGroup = PreferencesGroup(title: "Updates")
        updateGroup.add(ActionRow(
            title: "Managed Updates",
            subtitle: updateDelivery.userMessage
        ))

        let screenSharePrivacyRow = SwitchRow(
            title: "Hide From Screen Share",
            subtitle: "Unavailable on GNOME Wayland: no API exposes global capture state or capture exclusion."
        )
        screenSharePrivacyRow.active = false
        screenSharePrivacyRow.sensitive = false
        privacyGroup.add(screenSharePrivacyRow)

        // About group
        let aboutGroup = PreferencesGroup(title: "About")
        aboutGroup.add(ActionRow(title: "OpenUsage", subtitle: "Version \(version)"))

        let generalPage = page(
            name: "general",
            title: "General",
            icon: "preferences-system-symbolic",
            groups: [
            refreshGroup,
            notificationGroup,
            startupGroup,
            apiGroup,
            shortcutsGroup,
            aboutGroup,
        ])
        let displayPage = page(
            name: "display",
            title: "Display",
            icon: "video-display-symbolic",
            groups: [
            appearanceGroup,
            panelIndicatorGroup,
            displayGroup,
        ])
        configure(
            providersPage,
            name: "providers",
            title: "Providers",
            icon: "system-users-symbolic",
            groups: [
            orderGroup,
            metricCustomizationGroup,
        ]
        )
        let dataPage = page(
            name: "data",
            title: "Data",
            icon: "folder-symbolic",
            groups: [
            privacyGroup,
            apiKeyGroup,
            proxyGroup,
            advancedGroup,
            updateGroup,
        ])
        [generalPage, displayPage, providersPage, dataPage].forEach(dialog.add)
        dialog.title = "Preferences"
        dialog.searchEnabled = true
        dialog.contentWidth = 760
        dialog.contentHeight = 680
        connections.append(dialog.onMap { [weak self] in
            guard let self else { return }
            self.isPresented = true
            if self.focusDataPageOnMap {
                self.focusDataPageOnMap = false
                _ = self.proxyEnabledRow.grabFocus()
            }
        })
        connections.append(dialog.onUnmap { [weak self] in
            self?.isPresented = false
        })

        wireSignals()
        apply(settings: settings)
    }

    /// Applies persisted settings to the controls without emitting callbacks.
    func apply(settings: GNOMESettings) {
        applyingSettings = true
        appearanceRow.selected = GNOMESettings.Appearance.allCases.firstIndex(of: settings.appearance) ?? 0
        trayUsageDisplayRow.selected = TrayUsageDisplayMode.allCases.firstIndex(
            of: settings.trayUsageDisplayMode
        ) ?? 0
        menuBarStyleRow.selected = MenuBarStyle.allCases.firstIndex(of: settings.menuBarStyle) ?? 0
        widgetDisplayModeRow.selected = WidgetDisplayMode.allCases.firstIndex(
            of: settings.widgetDisplayMode
        ) ?? 0
        resetDisplayModeRow.selected = ResetDisplayMode.allCases.firstIndex(
            of: settings.resetDisplayMode
        ) ?? 0
        alwaysShowPacingRow.active = settings.alwaysShowPacing
        densityRow.selected = DensitySetting.allCases.firstIndex(of: settings.density) ?? 0
        timeFormatRow.selected = TimeFormatSetting.allCases.firstIndex(of: settings.timeFormat) ?? 0
        almostOutRow.active = settings.notifyAlmostOut
        cuttingItCloseRow.active = settings.notifyCuttingItClose
        willRunOutRow.active = settings.notifyWillRunOut
        periodicRow.active = settings.periodicRefreshEnabled
        intervalRow.value = Double(settings.refreshIntervalMinutes)
        intervalRow.sensitive = settings.periodicRefreshEnabled
        launchRow.active = settings.launchAtLogin ?? false
        analyticsRow.active = settings.analyticsEnabled ?? true
        apiRow.active = settings.localAPIEnabled ?? false
        apiPortRow.value = Double(settings.localAPIPort ?? LoopbackHTTPServer.defaultPort)
        apiPortRow.sensitive = apiRow.active
        syncDirectoryRow.subtitle = settings.syncDirectoryPath ?? defaultSyncPath
        proxyEnabledRow.active = settings.proxyEnabled
        proxyURLRow.text = settings.proxyURL ?? ""
        proxyBypassRow.text = settings.proxyBypassHosts.joined(separator: ", ")
        proxyURLRow.sensitive = settings.proxyEnabled
        proxyBypassRow.sensitive = settings.proxyEnabled
        logLevelRow.selected = LinuxLogLevel.allCases.firstIndex(
            of: settings.logLevel
        ) ?? 0
        order = settings.providerOrder
        hiddenProviderIDs = Set(settings.hiddenProviderIDs ?? [])
        rebuildOrderRows()
        customizationSettings = settings
        rebuildMetricCustomizationRows()
        applyingSettings = false
    }

    /// Updates the provider list used by the ordering group. Called after
    /// each refresh; preserves the persisted order and appends newcomers.
    func updateProviders(_ providers: [(id: String, name: String)]) {
        providerNames = Dictionary(providers.map { ($0.id, $0.name) }) { first, _ in first }
        let known = providers.map(\.id)
        order = order.filter { known.contains($0) } + known.filter { !order.contains($0) }
        rebuildOrderRows()
    }

    func updateMetricCustomization(_ snapshots: [ProviderUsageSnapshot]) {
        customizationSnapshots = snapshots
        rebuildMetricCustomizationRows()
    }

    func updateAPIKeyStatus(
        _ provider: ManagedAPIKeyProvider,
        text: String
    ) {
        apiKeyStatus(for: provider).text = text
    }

    func clearAPIKeyEntry(_ provider: ManagedAPIKeyProvider) {
        apiKeyRow(for: provider).text = ""
    }

    func present(parent: Widget, page name: String = "general") {
        selectPage(name)
        dialog.present(parent)
    }

    func revealDataSettings(parent: Widget) {
        focusDataPageOnMap = true
        present(parent: parent, page: "data")
    }

    func addToast(_ toast: Toast) {
        dialog.addToast(toast)
    }

    func presentationParent(fallback: Widget) -> Widget {
        isPresented ? dialog : fallback
    }

    func selectPage(_ name: String) {
        guard Self.pageOrder.contains(where: { $0.name == name }) else {
            return
        }
        dialog.visiblePageName = name
    }

    private func page(
        name: String,
        title: String,
        icon: String,
        groups: [Widget]
    ) -> PreferencesPage {
        let page = PreferencesPage()
        configure(page, name: name, title: title, icon: icon, groups: groups)
        return page
    }

    private func configure(
        _ page: PreferencesPage,
        name: String,
        title: String,
        icon: String,
        groups: [Widget]
    ) {
        page.name = name
        page.title = title
        page.iconName = icon
        groups.forEach(page.add)
    }

    private func addAPIKeyRow(
        _ row: PasswordEntryRow,
        status: Label,
        provider: ManagedAPIKeyProvider
    ) {
        status.addCSSClass(.caption)
        row.addSuffix(status)
        let clear = Button(label: "Clear", onClicked: { [weak self] in
            self?.onAPIKeyClear(provider)
        })
        clear.addCSSClass(.flat)
        row.addSuffix(clear)
        row.onApply { [weak self, weak row] in
            guard let row else { return }
            self?.onAPIKeySave(provider, row.text)
        }
    }

    private func apiKeyRow(
        for provider: ManagedAPIKeyProvider
    ) -> PasswordEntryRow {
        switch provider {
        case .openRouter: openRouterAPIKeyRow
        case .zai: zaiAPIKeyRow
        }
    }

    private func apiKeyStatus(for provider: ManagedAPIKeyProvider) -> Label {
        switch provider {
        case .openRouter: openRouterAPIKeyStatus
        case .zai: zaiAPIKeyStatus
        }
    }
}
