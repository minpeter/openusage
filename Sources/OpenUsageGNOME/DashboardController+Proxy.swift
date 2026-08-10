import Adwaita
import Foundation

extension DashboardController {
    func saveProxySettings(
        enabled: Bool,
        url: String,
        bypassText: String
    ) {
        do {
            try settings.setProxy(
                enabled: enabled,
                url: url,
                bypassText: bypassText
            )
            settingsStore.save(settings)
            settingsView.apply(settings: settings)
            toastOverlay.addToast(Toast(
                title: enabled
                    ? "Proxy saved - restart OpenUsage to apply"
                    : "Proxy disabled - restart OpenUsage to apply"
            ))
        } catch {
            settingsView.apply(settings: settings)
            toastOverlay.addToast(Toast(
                title: "Could not save proxy: \(error.localizedDescription)"
            ))
        }
    }
}
