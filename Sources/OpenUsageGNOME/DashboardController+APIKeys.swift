import Adwaita
import Foundation
import OpenUsageLinuxCore

extension DashboardController {
    func refreshAPIKeyStatuses() {
        let manager = apiKeyManager
        let callback = DashboardCallback(self)
        Task.detached {
            let statuses = ManagedAPIKeyProvider.allCases.map { provider in
                do {
                    return (
                        provider,
                        try manager.hasStoredKey(for: provider)
                            ? "Stored"
                            : "Not Stored"
                    )
                } catch {
                    return (provider, "Secret Service Unavailable")
                }
            }
            scheduleOnGTK {
                callback.applyAPIKeyStatuses(statuses)
            }
        }
    }

    func storeAPIKey(
        _ value: String,
        for provider: ManagedAPIKeyProvider
    ) {
        let manager = apiKeyManager
        let callback = DashboardCallback(self)
        Task.detached {
            let error: String?
            do {
                try manager.store(value, for: provider)
                error = nil
            } catch let caught {
                error = caught.localizedDescription
            }
            scheduleOnGTK {
                callback.finishAPIKeyStore(provider: provider, error: error)
            }
        }
    }

    func clearAPIKey(for provider: ManagedAPIKeyProvider) {
        let manager = apiKeyManager
        let callback = DashboardCallback(self)
        Task.detached {
            let error: String?
            do {
                try manager.clear(provider)
                error = nil
            } catch let caught {
                error = caught.localizedDescription
            }
            scheduleOnGTK {
                callback.finishAPIKeyClear(provider: provider, error: error)
            }
        }
    }

    func applyAPIKeyStatuses(
        _ statuses: [(ManagedAPIKeyProvider, String)]
    ) {
        for (provider, status) in statuses {
            settingsView.updateAPIKeyStatus(provider, text: status)
        }
    }

    func finishAPIKeyStore(
        provider: ManagedAPIKeyProvider,
        error: String?
    ) {
        guard let error else {
            GNOMEAppLog.info("Stored \(provider.providerID) API key in Secret Service")
            settingsView.clearAPIKeyEntry(provider)
            settingsView.updateAPIKeyStatus(provider, text: "Stored")
            toastOverlay.addToast(Toast(
                title: "\(provider.displayName) API key saved"
            ))
            return
        }
        GNOMEAppLog.warning("Could not store \(provider.providerID) API key: \(error)")
        toastOverlay.addToast(Toast(
            title: "Could not save \(provider.displayName) API key: \(error)"
        ))
    }

    func finishAPIKeyClear(
        provider: ManagedAPIKeyProvider,
        error: String?
    ) {
        guard let error else {
            GNOMEAppLog.info("Cleared \(provider.providerID) API key from Secret Service")
            settingsView.clearAPIKeyEntry(provider)
            settingsView.updateAPIKeyStatus(provider, text: "Not Stored")
            toastOverlay.addToast(Toast(
                title: "\(provider.displayName) API key cleared"
            ))
            return
        }
        GNOMEAppLog.warning("Could not clear \(provider.providerID) API key: \(error)")
        toastOverlay.addToast(Toast(
            title: "Could not clear \(provider.displayName) API key: \(error)"
        ))
    }

    static var qaAPIKeyProvider: ManagedAPIKeyProvider? {
        switch ProcessInfo.processInfo.environment["OPENUSAGE_API_KEY_PROVIDER"] {
        case "openrouter": .openRouter
        case "zai": .zai
        default: nil
        }
    }
}
