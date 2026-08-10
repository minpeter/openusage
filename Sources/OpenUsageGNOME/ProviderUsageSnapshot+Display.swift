import OpenUsageLinuxCore

extension ProviderUsageSnapshot {
    func applyingProviderRenames(
        _ renames: [String: String]
    ) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            providerID: providerID,
            instanceID: instanceID,
            displayName: renames[providerID] ?? displayName,
            accountLabel: accountLabel,
            plan: plan,
            metrics: metrics,
            links: links,
            widgets: widgets,
            refreshedAt: refreshedAt,
            errorMessage: errorMessage,
            warning: warning
        )
    }

    func hasSameDisplayContent(as other: ProviderUsageSnapshot) -> Bool {
        providerID == other.providerID
            && instanceID == other.instanceID
            && displayName == other.displayName
            && accountLabel == other.accountLabel
            && plan == other.plan
            && metrics == other.metrics
            && links == other.links
            && widgets == other.widgets
            && errorMessage == other.errorMessage
            && warning == other.warning
    }
}
