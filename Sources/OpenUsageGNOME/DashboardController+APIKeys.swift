import Adwaita
import Foundation
import OpenUsageLinuxCore

extension DashboardController {
    nonisolated static func shouldRefreshAPIKeyStatuses(
        environment: [String: String]
    ) -> Bool {
        environment["OPENUSAGE_PERFORMANCE_RECEIPT"] == nil
    }

    func refreshAPIKeyStatuses() {
        guard Self.shouldRefreshAPIKeyStatuses(
            environment: ProcessInfo.processInfo.environment
        ) else {
            return
        }
        for provider in ManagedAPIKeyProvider.allCases {
            let revision = nextAPIKeyRevision(for: provider)
            let operations = apiKeyOperations
            let callback = DashboardCallback(self)
            Task.detached {
                let result = await operations.status(
                    for: provider,
                    revision: revision
                )
                scheduleOnGTK {
                    callback.finishAPIKeyOperation(
                        provider: provider,
                        revision: revision,
                        result: result
                    )
                }
            }
        }
    }

    func storeAPIKey(
        _ value: String,
        for provider: ManagedAPIKeyProvider
    ) {
        let revision = nextAPIKeyRevision(for: provider)
        settingsView.updateAPIKeyStatus(provider, text: "Saving…")
        let operations = apiKeyOperations
        let callback = DashboardCallback(self)
        Task.detached {
            let result = await operations.store(
                value,
                for: provider,
                revision: revision
            )
            scheduleOnGTK {
                callback.finishAPIKeyOperation(
                    provider: provider,
                    revision: revision,
                    result: result
                )
            }
        }
    }

    func clearAPIKey(for provider: ManagedAPIKeyProvider) {
        let revision = nextAPIKeyRevision(for: provider)
        settingsView.updateAPIKeyStatus(provider, text: "Clearing…")
        let operations = apiKeyOperations
        let callback = DashboardCallback(self)
        Task.detached {
            let result = await operations.clear(
                provider,
                revision: revision
            )
            scheduleOnGTK {
                callback.finishAPIKeyOperation(
                    provider: provider,
                    revision: revision,
                    result: result
                )
            }
        }
    }

    func finishAPIKeyOperation(
        provider: ManagedAPIKeyProvider,
        revision: UInt64,
        result: APIKeyOperationResult
    ) {
        guard apiKeyRevisions[provider] == revision else { return }
        if result.requiresCredentialRefresh {
            requestCredentialRefresh()
        }
        switch result {
        case .status(let status):
            settingsView.updateAPIKeyStatus(provider, text: status)
        case .stored:
            GNOMEAppLog.info("Stored \(provider.providerID) API key in Secret Service")
            settingsView.clearAPIKeyEntry(provider)
            settingsView.updateAPIKeyStatus(provider, text: "Stored")
            toastOverlay.addToast(Toast(
                title: "\(provider.displayName) API key saved"
            ))
        case .cleared:
            GNOMEAppLog.info("Cleared \(provider.providerID) API key from Secret Service")
            settingsView.clearAPIKeyEntry(provider)
            settingsView.updateAPIKeyStatus(provider, text: "Not Stored")
            toastOverlay.addToast(Toast(
                title: "\(provider.displayName) API key cleared"
            ))
        case .failed(let error):
            GNOMEAppLog.warning(
                "API key operation failed for \(provider.providerID): \(error)"
            )
            toastOverlay.addToast(Toast(
                title: "\(provider.displayName) API key update failed: \(error)"
            ))
            refreshAPIKeyStatuses()
        case .stale:
            break
        }
    }

    private func nextAPIKeyRevision(
        for provider: ManagedAPIKeyProvider
    ) -> UInt64 {
        let revision = (apiKeyRevisions[provider] ?? 0) + 1
        apiKeyRevisions[provider] = revision
        return revision
    }

    private func requestCredentialRefresh() {
        if isRefreshing {
            credentialRefreshPending = true
        } else {
            refresh()
        }
    }

    static var qaAPIKeyProvider: ManagedAPIKeyProvider? {
        switch ProcessInfo.processInfo.environment["OPENUSAGE_API_KEY_PROVIDER"] {
        case "openrouter": .openRouter
        case "zai": .zai
        default: nil
        }
    }
}
