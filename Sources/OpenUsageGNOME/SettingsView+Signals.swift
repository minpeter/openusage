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
    }
}
