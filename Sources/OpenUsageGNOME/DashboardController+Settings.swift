import Adwaita
import Foundation
import OpenUsageLinuxCore

// MARK: - View wiring

extension DashboardController {
    func wireViews() {
        overview.setRefreshHandler { [weak self] in self?.refresh() }
        overview.setShareHandler { [weak self] card in
            self?.exportShareCard(card)
        }
        providersView.setRefreshHandler { [weak self] in self?.refresh() }
        providersView.setRenameHandler { [weak self] providerID, name in
            guard let self else { return }
            self.settings.renameProvider(providerID, to: name)
            guard self.persistSettings() else { return }
            self.applySnapshots()
        }
    }

    func wireSettings() {
        settingsView.onAppearanceChanged = { [weak self] appearance in
            guard let self else { return }
            self.settings.appearance = appearance
            guard self.persistSettings() else { return }
            self.applyAppearance(appearance)
        }
        settingsView.onTrayUsageDisplayModeChanged = { [weak self] mode in
            guard let self else { return }
            self.settings.trayUsageDisplayMode = mode
            guard self.persistSettings() else { return }
            self.updateTrayUsage(self.visibleOrdered(self.snapshots))
        }
        settingsView.onMenuBarStyleChanged = { [weak self] style in
            guard let self else { return }
            self.settings.menuBarStyle = style
            self.saveAndApplyDisplaySettings()
        }
        settingsView.onWidgetDisplayModeChanged = { [weak self] mode in
            guard let self else { return }
            self.settings.widgetDisplayMode = mode
            self.saveAndApplyDisplaySettings()
        }
        settingsView.onResetDisplayModeChanged = { [weak self] mode in
            guard let self else { return }
            self.settings.resetDisplayMode = mode
            self.saveAndApplyDisplaySettings()
        }
        settingsView.onAlwaysShowPacingChanged = { [weak self] enabled in
            guard let self else { return }
            self.settings.alwaysShowPacing = enabled
            self.saveAndApplyDisplaySettings()
        }
        settingsView.onDensityChanged = { [weak self] density in
            guard let self else { return }
            self.settings.density = density
            self.saveAndApplyDisplaySettings()
        }
        settingsView.onTimeFormatChanged = { [weak self] format in
            guard let self else { return }
            self.settings.timeFormat = format
            self.saveAndApplyDisplaySettings()
        }
        settingsView.onNotificationTogglesChanged = { [weak self] toggles in
            guard let self else { return }
            self.settings.notifyAlmostOut = toggles.almostOut
            self.settings.notifyCuttingItClose = toggles.cuttingItClose
            self.settings.notifyWillRunOut = toggles.willRunOut
            _ = self.persistSettings()
        }
        settingsView.onRefreshScheduleChanged = { [weak self] enabled, minutes in
            guard let self else { return }
            self.settings.periodicRefreshEnabled = enabled
            self.settings.refreshIntervalMinutes = minutes
            guard self.persistSettings() else { return }
            self.scheduleRefreshTimer()
        }
        settingsView.onProviderOrderChanged = { [weak self] order in
            guard let self else { return }
            self.settings.providerOrder = order
            guard self.persistSettings() else { return }
            self.applySnapshots()
        }
        settingsView.onProviderVisibilityChanged = { [weak self] providerID, isVisible in
            guard let self else { return }
            var hidden = Set(self.settings.hiddenProviderIDs ?? [])
            if isVisible {
                hidden.remove(providerID)
            } else {
                hidden.insert(providerID)
            }
            self.settings.hiddenProviderIDs = hidden.sorted()
            guard self.persistSettings() else { return }
            self.applySnapshots()
        }
        settingsView.onMetricEnabledChanged = { [weak self] providerID, key, enabled in
            self?.setMetricEnabled(enabled, providerID: providerID, key: key)
        }
        settingsView.onMetricSectionChanged = { [weak self] providerID, key, section in
            self?.setMetricSection(section, providerID: providerID, key: key)
        }
        settingsView.onMetricMoved = { [weak self] providerID, key, offset in
            self?.moveMetric(providerID: providerID, key: key, offset: offset)
        }
        settingsView.onPanelPinChanged = { [weak self] providerID, key, enabled in
            self?.setPanelPin(enabled, providerID: providerID, key: key) ?? false
        }
        settingsView.onLaunchAtLoginChanged = { [weak self] enabled in
            guard let self else { return }
            let previous = self.persistedSettings
            self.settings.launchAtLogin = enabled
            guard self.persistSettings() else { return }
            do {
                try self.launchAtLoginService.setEnabled(enabled)
            } catch {
                self.settings.launchAtLogin =
                    Self.reconciledLaunchAtLoginState(
                        fallback: previous.launchAtLogin ?? false
                    ) {
                        try self.launchAtLoginService.isEnabled()
                    }
                _ = self.persistSettings()
                self.toastOverlay.addToast(Toast(
                    title: "Could not update launch at login: \(error.localizedDescription)"
                ))
                self.settingsView.apply(settings: self.settings)
            }
        }
        settingsView.onAnalyticsChanged = { [weak self] enabled in
            guard let self else { return }
            self.settings.analyticsEnabled = enabled
            guard self.persistSettings() else { return }
            let client = self.analyticsClient
            Task.detached {
                await client.setEnabled(enabled)
            }
        }
        settingsView.onLocalAPIChanged = { [weak self] enabled, port in
            guard let self else { return }
            self.settings.localAPIEnabled = enabled
            self.settings.localAPIPort = port
            guard self.persistSettings() else { return }
            self.configureLocalAPI(enabled: enabled, port: port)
        }
        settingsView.onSyncDirectoryRequested = { [weak self] in
            self?.chooseSyncDirectory()
        }
        settingsView.onSyncDirectoryReset = { [weak self] in
            self?.setSyncDirectory(nil)
        }
        settingsView.onImportRequested = { [weak self] in
            self?.chooseUsageImport()
        }
        settingsView.onExportRequested = { [weak self] format in
            self?.exportSnapshots(format: format)
        }
        settingsView.onAPIKeySave = { [weak self] provider, value in
            self?.storeAPIKey(value, for: provider)
        }
        settingsView.onAPIKeyClear = { [weak self] provider in
            self?.clearAPIKey(for: provider)
        }
        settingsView.onProxySave = { [weak self] enabled, url, bypass in
            self?.saveProxySettings(
                enabled: enabled,
                url: url,
                bypassText: bypass
            )
        }
        settingsView.onLogLevelChanged = { [weak self] level in
            guard let self else { return }
            self.settings.logLevel = level
            guard self.persistSettings() else { return }
            GNOMEAppLog.configure(level: level)
            GNOMEAppLog.info("Log level changed to \(level.rawValue)")
        }
        settingsView.onOpenLog = {
            GNOMEAppLog.info("Opening file log")
            UriLauncher(uri: GNOMEAppLog.file.absoluteString).launch()
        }
        refreshAPIKeyStatuses()
    }

    private func saveAndApplyDisplaySettings() {
        guard persistSettings() else { return }
        settingsView.apply(settings: settings)
        applySnapshots()
    }

    @discardableResult
    func persistSettings() -> Bool {
        do {
            try settingsStore.save(settings)
            persistedSettings = settings
            return true
        } catch {
            settings = persistedSettings
            settingsView.apply(settings: settings)
            GNOMEAppLog.error(
                "Failed to save GNOME settings: \(error.localizedDescription)"
            )
            toastOverlay.addToast(Toast(
                title: "Could not save settings: \(error.localizedDescription)"
            ))
            return false
        }
    }

    nonisolated static func reconciledLaunchAtLoginState(
        fallback: Bool,
        readActualState: () throws -> Bool
    ) -> Bool {
        (try? readActualState()) ?? fallback
    }

    private func setMetricEnabled(
        _ enabled: Bool,
        providerID: String,
        key: MetricPreferenceKey
    ) {
        var layout = metricLayout(for: providerID)
        layout.setEnabled(enabled, for: key)
        settings.metricLayouts[providerID] = layout
        if !enabled {
            settings.panelMetricPins.unpin(key, for: providerID)
        }
        saveAndApplyDisplaySettings()
    }

    private func setMetricSection(
        _ section: MetricVisibilitySection,
        providerID: String,
        key: MetricPreferenceKey
    ) {
        var layout = metricLayout(for: providerID)
        layout.move(key, to: section, at: Int.max)
        settings.metricLayouts[providerID] = layout
        saveAndApplyDisplaySettings()
    }

    private func moveMetric(
        providerID: String,
        key: MetricPreferenceKey,
        offset: Int
    ) {
        var layout = metricLayout(for: providerID)
        guard let entry = layout.entry(for: key) else { return }
        let knownKeys = Set(metricCustomizationMetrics(for: providerID).map(
            MetricPreferenceKey.init(metric:)
        ))
        let sectionKeys = layout.entries.filter {
            $0.section == entry.section && knownKeys.contains($0.key)
        }.map(\.key)
        guard let current = sectionKeys.firstIndex(of: key) else { return }
        let destination = current + offset
        guard sectionKeys.indices.contains(destination) else { return }
        layout.move(key, to: entry.section, at: destination)
        settings.metricLayouts[providerID] = layout
        saveAndApplyDisplaySettings()
    }

    private func setPanelPin(
        _ enabled: Bool,
        providerID: String,
        key: MetricPreferenceKey
    ) -> Bool {
        var pins = settings.panelMetricPins
        if enabled {
            guard metricLayout(for: providerID).entry(for: key)?.isEnabled == true else {
                settingsView.apply(settings: settings)
                return false
            }
            guard pins.pin(key, for: providerID) else {
                toastOverlay.addToast(Toast(title: "Pin up to two metrics per provider."))
                settingsView.apply(settings: settings)
                return false
            }
        } else {
            pins.unpin(key, for: providerID)
        }
        settings.panelMetricPins = pins
        saveAndApplyDisplaySettings()
        return true
    }

    private func metricLayout(for providerID: String) -> ProviderMetricLayout {
        var layout = settings.metricLayouts[providerID] ?? .init()
        layout.reconcile(with: metricCustomizationMetrics(for: providerID))
        return layout
    }

    private func metricCustomizationMetrics(for providerID: String) -> [UsageMetric] {
        var seen: Set<MetricPreferenceKey> = []
        return snapshots.filter { $0.providerID == providerID }.flatMap(\.metrics).filter {
            seen.insert(MetricPreferenceKey(metric: $0)).inserted
        }
    }

    func applyAppearance(_ appearance: GNOMESettings.Appearance) {
        switch appearance {
        case .system:
            StyleManager.default.resetColorScheme()
        case .light:
            StyleManager.default.forceLight()
        case .dark:
            StyleManager.default.forceDark()
        }
    }

    func configureLocalAPI(enabled: Bool, port: Int) {
        localAPIServer?.stop()
        localAPIServer = nil
        guard enabled, !DemoFixtures.isEnabled else { return }
        do {
            let server = try LoopbackHTTPServer(port: port, source: repository)
            try server.start()
            localAPIServer = server
        } catch {
            toastOverlay.addToast(Toast(
                title: "Could not start local API: \(error.localizedDescription)"
            ))
        }
    }

    func exportSnapshots(format: UsageExportFormat) {
        do {
            let file = try UsageDataSyncService().export(
                snapshots,
                format: format,
                to: usageDataDirectory
            )
            UriLauncher(uri: file.absoluteString).launch()
            toastOverlay.addToast(Toast(title: "Exported \(file.lastPathComponent)"))
        } catch {
            toastOverlay.addToast(Toast(
                title: "Could not export usage: \(error.localizedDescription)"
            ))
        }
    }

    func chooseSyncDirectory() {
        if let qaPath = ProcessInfo.processInfo.environment["OPENUSAGE_SYNC_DIRECTORY"] {
            setSyncDirectory(qaPath)
            return
        }
        let dialog = FileDialog()
        dialog.title = "Choose Usage Sync Directory"
        dialog.acceptLabel = "Choose"
        dialog.selectFolder(parent: window) { [weak self] path in
            guard let path else { return }
            self?.setSyncDirectory(path)
        }
    }

    func setSyncDirectory(_ path: String?) {
        settings.setSyncDirectory(path)
        guard persistSettings() else { return }
        settingsView.syncDirectoryRow.subtitle = usageDataDirectory.path
        toastOverlay.addToast(Toast(
            title: settings.syncDirectoryPath == nil
                ? "Using the Downloads directory"
                : "Sync directory updated"
        ))
    }

    func chooseUsageImport() {
        if let qaPath = ProcessInfo.processInfo.environment["OPENUSAGE_IMPORT_PATH"] {
            importSnapshots(from: URL(fileURLWithPath: qaPath))
            return
        }
        let dialog = FileDialog()
        dialog.title = "Import Usage"
        dialog.acceptLabel = "Import"
        dialog.setFilters([FileFilter(name: "OpenUsage JSON", suffixes: ["json"])])
        dialog.open(parent: window) { [weak self] path in
            guard let path else { return }
            self?.importSnapshots(from: URL(fileURLWithPath: path))
        }
    }

    func importSnapshots(from file: URL) {
        do {
            snapshots = mergedWithLastGood(
                try UsageDataSyncService().importSnapshots(from: file)
            )
            applySnapshots()
            toastOverlay.addToast(Toast(title: "Imported \(file.lastPathComponent)"))
        } catch {
            toastOverlay.addToast(Toast(
                title: "Could not import usage: \(error.localizedDescription)"
            ))
        }
    }

    var usageDataDirectory: URL {
        guard let path = settings.syncDirectoryPath else {
            return Self.defaultUsageDirectory()
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func defaultUsageDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let home = environment["HOME"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser
        guard let configured = environment["XDG_DOWNLOAD_DIR"] else {
            return home.appendingPathComponent("Downloads", isDirectory: true)
        }
        return URL(
            fileURLWithPath: configured.replacingOccurrences(
                of: "$HOME",
                with: home.path
            ),
            isDirectory: true
        )
    }

    func exportShareCard(_ card: BrandedShareCard) {
        do {
            let environment = ProcessInfo.processInfo.environment
            let home = environment["HOME"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            } ?? FileManager.default.homeDirectoryForCurrentUser
            let directory = environment["XDG_PICTURES_DIR"].map {
                URL(
                    fileURLWithPath: $0.replacingOccurrences(
                        of: "$HOME",
                        with: home.path
                    ),
                    isDirectory: true
                )
            } ?? home.appendingPathComponent("Pictures", isDirectory: true)
            let file = try BrandedPNGExportService.export(card: card, to: directory)
            showSharePreview(file)
            UriLauncher(uri: file.absoluteString).launch()
            toastOverlay.addToast(Toast(title: "Exported \(file.lastPathComponent)"))
        } catch {
            toastOverlay.addToast(Toast(
                title: "Could not export share image: \(error.localizedDescription)"
            ))
        }
    }

    private func showSharePreview(_ file: URL) {
        _ = sharePreviewDialog?.close()
        let preview = Dialog()
        preview.title = file.lastPathComponent
        preview.contentWidth = 960
        preview.contentHeight = 600
        let picture = Picture(filename: file.path)
        picture.canShrink = true
        picture.contentFit = GTK_CONTENT_FIT_CONTAIN
        picture.hexpand = true
        picture.vexpand = true
        picture.setMargins(GNOMEStyle.outerMargin)
        picture.alternativeText = "OpenUsage branded Total Spend share image"
        preview.child = picture
        preview.present(window)
        sharePreviewDialog = preview
    }
}
