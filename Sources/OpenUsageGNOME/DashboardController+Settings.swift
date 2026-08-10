import Adwaita
import Foundation
import OpenUsageLinuxCore

// MARK: - View wiring

extension DashboardController {
    func wireViews() {
        overview.setRefreshHandler { [weak self] in self?.refresh() }
        providersView.setRefreshHandler { [weak self] in self?.refresh() }
    }

    func wireSettings() {
        settingsView.onAppearanceChanged = { [weak self] appearance in
            guard let self else { return }
            self.settings.appearance = appearance
            self.settingsStore.save(self.settings)
            self.applyAppearance(appearance)
        }
        settingsView.onTrayUsageDisplayModeChanged = { [weak self] mode in
            guard let self else { return }
            self.settings.trayUsageDisplayMode = mode
            self.settingsStore.save(self.settings)
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
        settingsView.onRefreshScheduleChanged = { [weak self] enabled, minutes in
            guard let self else { return }
            self.settings.periodicRefreshEnabled = enabled
            self.settings.refreshIntervalMinutes = minutes
            self.settingsStore.save(self.settings)
            self.scheduleRefreshTimer()
        }
        settingsView.onProviderOrderChanged = { [weak self] order in
            guard let self else { return }
            self.settings.providerOrder = order
            self.settingsStore.save(self.settings)
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
            self.settingsStore.save(self.settings)
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
            do {
                try self.launchAtLoginService.setEnabled(enabled)
                self.settings.launchAtLogin = enabled
                self.settingsStore.save(self.settings)
            } catch {
                self.toastOverlay.addToast(Toast(
                    title: "Could not update launch at login: \(error.localizedDescription)"
                ))
                self.settingsView.apply(settings: self.settings)
            }
        }
        settingsView.onAnalyticsChanged = { [weak self] enabled in
            guard let self else { return }
            self.settings.analyticsEnabled = enabled
            self.settingsStore.save(self.settings)
            let client = self.analyticsClient
            Task.detached {
                await client.setEnabled(enabled)
            }
        }
        settingsView.onLocalAPIChanged = { [weak self] enabled, port in
            guard let self else { return }
            self.settings.localAPIEnabled = enabled
            self.settings.localAPIPort = port
            self.settingsStore.save(self.settings)
            self.configureLocalAPI(enabled: enabled, port: port)
        }
        settingsView.onExportRequested = { [weak self] format in
            self?.exportSnapshots(format: format)
        }
    }

    private func saveAndApplyDisplaySettings() {
        settingsStore.save(settings)
        settingsView.apply(settings: settings)
        applySnapshots()
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
            let environment = ProcessInfo.processInfo.environment
            let home = environment["HOME"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            } ?? FileManager.default.homeDirectoryForCurrentUser
            let directory = environment["XDG_DOWNLOAD_DIR"].map {
                URL(
                    fileURLWithPath: $0.replacingOccurrences(
                        of: "$HOME",
                        with: home.path
                    ),
                    isDirectory: true
                )
            } ?? home.appendingPathComponent("Downloads", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let suffix = format == .json ? "json" : "csv"
            let stamp = Int(Date().timeIntervalSince1970)
            let file = directory.appendingPathComponent(
                "openusage-\(stamp).\(suffix)"
            )
            let data = try UsageExportService().encode(snapshots, format: format)
            try data.write(to: file, options: .atomic)
            UriLauncher(uri: file.absoluteString).launch()
            toastOverlay.addToast(Toast(title: "Exported \(file.lastPathComponent)"))
        } catch {
            toastOverlay.addToast(Toast(
                title: "Could not export usage: \(error.localizedDescription)"
            ))
        }
    }
}
