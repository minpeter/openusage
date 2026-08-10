import Adwaita
import Foundation
import OpenUsageLinuxCore

// MARK: - Internals

extension SettingsView {
    /// Wires every control to its callback. `applyingSettings` suppresses
    /// callbacks while persisted state is replayed into the controls.
    func wireSignals() {
        connections.append(appearanceRow.onNotify(.selected) { [weak self] in
            guard let self, !self.applyingSettings else { return }
            let appearance = GNOMESettings.Appearance.allCases[
                min(max(appearanceRow.selected, 0), GNOMESettings.Appearance.allCases.count - 1)
            ]
            self.onAppearanceChanged(appearance)
        })
        connections.append(trayUsageDisplayRow.onNotify(.selected) { [weak self] in
            guard let self, !self.applyingSettings else { return }
            let mode = TrayUsageDisplayMode.allCases[
                min(
                    max(trayUsageDisplayRow.selected, 0),
                    TrayUsageDisplayMode.allCases.count - 1
                )
            ]
            self.onTrayUsageDisplayModeChanged(mode)
        })
        connections.append(menuBarStyleRow.onNotify(.selected) { [weak self] in
            guard let self, !self.applyingSettings else { return }
            let style = MenuBarStyle.allCases[
                min(max(menuBarStyleRow.selected, 0), MenuBarStyle.allCases.count - 1)
            ]
            self.onMenuBarStyleChanged(style)
        })
        connections.append(widgetDisplayModeRow.onNotify(.selected) { [weak self] in
            guard let self, !self.applyingSettings else { return }
            let mode = WidgetDisplayMode.allCases[
                min(
                    max(widgetDisplayModeRow.selected, 0),
                    WidgetDisplayMode.allCases.count - 1
                )
            ]
            self.onWidgetDisplayModeChanged(mode)
        })
        connections.append(resetDisplayModeRow.onNotify(.selected) { [weak self] in
            guard let self, !self.applyingSettings else { return }
            let mode = ResetDisplayMode.allCases[
                min(
                    max(resetDisplayModeRow.selected, 0),
                    ResetDisplayMode.allCases.count - 1
                )
            ]
            self.onResetDisplayModeChanged(mode)
        })
        connections.append(alwaysShowPacingRow.onNotify(.active) { [weak self] in
            guard let self, !self.applyingSettings else { return }
            self.onAlwaysShowPacingChanged(self.alwaysShowPacingRow.active)
        })
        connections.append(densityRow.onNotify(.selected) { [weak self] in
            guard let self, !self.applyingSettings else { return }
            let density = DensitySetting.allCases[
                min(max(densityRow.selected, 0), DensitySetting.allCases.count - 1)
            ]
            self.onDensityChanged(density)
        })
        connections.append(timeFormatRow.onNotify(.selected) { [weak self] in
            guard let self, !self.applyingSettings else { return }
            let format = TimeFormatSetting.allCases[
                min(max(timeFormatRow.selected, 0), TimeFormatSetting.allCases.count - 1)
            ]
            self.onTimeFormatChanged(format)
        })
        connections.append(almostOutRow.onNotify(.active) { [weak self] in
            guard let self, !self.applyingSettings else { return }
            self.emitNotificationToggles()
        })
        connections.append(cuttingItCloseRow.onNotify(.active) { [weak self] in
            guard let self, !self.applyingSettings else { return }
            self.emitNotificationToggles()
        })
        connections.append(willRunOutRow.onNotify(.active) { [weak self] in
            guard let self, !self.applyingSettings else { return }
            self.emitNotificationToggles()
        })
        connections.append(periodicRow.onNotify(.active) { [weak self] in
            guard let self, !self.applyingSettings else { return }
            self.intervalRow.sensitive = self.periodicRow.active
            self.onRefreshScheduleChanged(self.periodicRow.active, Int(self.intervalRow.value))
        })
        connections.append(intervalRow.onNotify(.value) { [weak self] in
            guard let self, !self.applyingSettings else { return }
            self.onRefreshScheduleChanged(self.periodicRow.active, Int(self.intervalRow.value))
        })
        connections.append(launchRow.onNotify(.active) { [weak self] in
            guard let self, !self.applyingSettings else { return }
            self.onLaunchAtLoginChanged(self.launchRow.active)
        })
        connections.append(analyticsRow.onNotify(.active) { [weak self] in
            guard let self, !self.applyingSettings else { return }
            self.onAnalyticsChanged(self.analyticsRow.active)
        })
        connections.append(apiRow.onNotify(.active) { [weak self] in
            guard let self, !self.applyingSettings else { return }
            self.apiPortRow.sensitive = self.apiRow.active
            self.onLocalAPIChanged(self.apiRow.active, Int(self.apiPortRow.value))
        })
        connections.append(apiPortRow.onNotify(.value) { [weak self] in
            guard let self, !self.applyingSettings else { return }
            self.onLocalAPIChanged(self.apiRow.active, Int(self.apiPortRow.value))
        })
        connections.append(proxyEnabledRow.onNotify(.active) { [weak self] in
            guard let self, !self.applyingSettings else { return }
            self.proxyURLRow.sensitive = self.proxyEnabledRow.active
            self.proxyBypassRow.sensitive = self.proxyEnabledRow.active
        })
        connections.append(logLevelRow.onNotify(.selected) { [weak self] in
            guard let self, !self.applyingSettings else { return }
            let levels = LinuxLogLevel.allCases
            let index = min(max(self.logLevelRow.selected, 0), levels.count - 1)
            self.onLogLevelChanged(levels[index])
        })
    }

    private func emitNotificationToggles() {
        onNotificationTogglesChanged(.init(
            almostOut: almostOutRow.active,
            cuttingItClose: cuttingItCloseRow.active,
            willRunOut: willRunOutRow.active
        ))
    }
}
