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
