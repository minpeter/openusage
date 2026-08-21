import Adwaita
import Foundation
import OpenUsageLinuxCore

extension SettingsView {
    func updateAPIKeyStatus(
        _ provider: ManagedAPIKeyProvider,
        text: String
    ) {
        apiKeyStatus(for: provider).text = text
        apiKeyClearButton(for: provider).sensitive =
            SettingsAPIKeyPresentation.clearIsEnabled(status: text)
    }

    func addAPIKeyRow(
        _ row: PasswordEntryRow,
        status: Label,
        clear: Button,
        provider: ManagedAPIKeyProvider
    ) {
        status.addCSSClass(.caption)
        row.addSuffix(status)
        clear.addCSSClass(.flat)
        clear.sensitive = false
        connections.append(clear.onClicked { [weak self] in
            self?.onAPIKeyClear(provider)
        })
        row.addSuffix(clear)
        row.onApply { [weak self, weak row] in
            guard let row else { return }
            self?.onAPIKeySave(provider, row.text)
        }
    }

    func apiKeyRow(
        for provider: ManagedAPIKeyProvider
    ) -> PasswordEntryRow {
        switch provider {
        case .openRouter: openRouterAPIKeyRow
        case .zai: zaiAPIKeyRow
        }
    }

    func apiKeyStatus(for provider: ManagedAPIKeyProvider) -> Label {
        switch provider {
        case .openRouter: openRouterAPIKeyStatus
        case .zai: zaiAPIKeyStatus
        }
    }

    func apiKeyClearButton(for provider: ManagedAPIKeyProvider) -> Button {
        switch provider {
        case .openRouter: openRouterAPIKeyClear
        case .zai: zaiAPIKeyClear
        }
    }
}
