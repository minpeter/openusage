import OpenUsageLinuxCore

extension ProviderUsageSnapshot {
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
