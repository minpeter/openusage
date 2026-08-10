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
    let root: ScrolledWindow

    var onAppearanceChanged: (GNOMESettings.Appearance) -> Void = { _ in }
    var onRefreshScheduleChanged: (Bool, Int) -> Void = { _, _ in }
    var onProviderOrderChanged: ([String]) -> Void = { _ in }
    var onProviderVisibilityChanged: (String, Bool) -> Void = { _, _ in }
    var onLaunchAtLoginChanged: (Bool) -> Void = { _ in }
    var onAnalyticsChanged: (Bool) -> Void = { _ in }
    var onLocalAPIChanged: (Bool, Int) -> Void = { _, _ in }
    var onExportRequested: (UsageExportFormat) -> Void = { _ in }

    private let content = Box(orientation: GTK_ORIENTATION_VERTICAL, spacing: GNOMEStyle.sectionSpacing)
    let appearanceRow: ComboRow
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
    let orderGroup = PreferencesGroup(
        title: "Provider Order",
        description: "Controls the order of providers in every view."
    )
    var order: [String] = []
    var hiddenProviderIDs: Set<String> = []
    var providerNames: [String: String] = [:]
    var providerRows: [String: SwitchRow] = [:]
    var connections: [SignalConnection] = []
    var orderConnections: [SignalConnection] = []
    var applyingSettings = false

    init(settings: GNOMESettings, cachePath: String, version: String) {
        root = ScrolledWindow()
        root.setPolicy(horizontal: GTK_POLICY_NEVER, vertical: GTK_POLICY_AUTOMATIC)
        root.kineticScrolling = true
        content.setMargins(GNOMEStyle.outerMargin)

        // Appearance group
        appearanceRow = ComboRow(title: "Style")
        appearanceRow.setModel(StringList(["System", "Light", "Dark"]))
        let appearanceGroup = PreferencesGroup(
            title: "Appearance",
            description: "Follows the desktop unless overridden here. High-contrast and font "
                + "scaling always come from the system."
        )
        appearanceGroup.add(appearanceRow)

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
        shortcutsGroup.add(shortcutRow(title: "Show History", accelerator: "<Control>3"))
        shortcutsGroup.add(shortcutRow(title: "Show Settings", accelerator: "<Control>4"))
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
        let exportRow = ActionRow(
            title: "Export Usage",
            subtitle: "Save the current snapshots without credentials."
        )
        let exportActions = Box(
            orientation: GTK_ORIENTATION_HORIZONTAL,
            spacing: GNOMEStyle.controlSpacing
        )
        exportActions.append(Button(label: "JSON", onClicked: { [weak self] in
            self?.onExportRequested(.json)
        }))
        exportActions.append(Button(label: "CSV", onClicked: { [weak self] in
            self?.onExportRequested(.csv)
        }))
        exportRow.addSuffix(exportActions)
        privacyGroup.add(exportRow)

        // About group
        let aboutGroup = PreferencesGroup(title: "About")
        aboutGroup.add(ActionRow(title: "OpenUsage", subtitle: "Version \(version)"))

        content.append(appearanceGroup)
        content.append(refreshGroup)
        content.append(startupGroup)
        content.append(orderGroup)
        content.append(apiGroup)
        content.append(shortcutsGroup)
        content.append(privacyGroup)
        content.append(aboutGroup)

        let clamp = Clamp()
        clamp.maximumSize = GNOMEStyle.contentClamp
        clamp.tighteningThreshold = GNOMEStyle.clampTightening
        clamp.child = content
        root.child = clamp

        wireSignals()
        apply(settings: settings)
    }

    /// Applies persisted settings to the controls without emitting callbacks.
    func apply(settings: GNOMESettings) {
        applyingSettings = true
        appearanceRow.selected = GNOMESettings.Appearance.allCases.firstIndex(of: settings.appearance) ?? 0
        periodicRow.active = settings.periodicRefreshEnabled
        intervalRow.value = Double(settings.refreshIntervalMinutes)
        intervalRow.sensitive = settings.periodicRefreshEnabled
        launchRow.active = settings.launchAtLogin ?? false
        analyticsRow.active = settings.analyticsEnabled ?? true
        apiRow.active = settings.localAPIEnabled ?? false
        apiPortRow.value = Double(settings.localAPIPort ?? LoopbackHTTPServer.defaultPort)
        apiPortRow.sensitive = apiRow.active
        order = settings.providerOrder
        hiddenProviderIDs = Set(settings.hiddenProviderIDs ?? [])
        rebuildOrderRows()
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
}
