import OpenUsageLinuxCore

struct DashboardRenderGate {
    private struct State: Equatable {
        let snapshots: [ProviderUsageSnapshot]
        let settings: GNOMESettings
        let isRefreshing: Bool
    }

    private var last: State?
    private var lastProviderSettingsSnapshots: [ProviderUsageSnapshot]?

    mutating func consumeProviderSettings(
        snapshots: [ProviderUsageSnapshot]
    ) -> Bool {
        guard snapshots != lastProviderSettingsSnapshots else { return false }
        lastProviderSettingsSnapshots = snapshots
        return true
    }

    mutating func consume(
        snapshots: [ProviderUsageSnapshot],
        settings: GNOMESettings,
        isRefreshing: Bool
    ) -> Bool {
        let next = State(
            snapshots: snapshots,
            settings: settings,
            isRefreshing: isRefreshing
        )
        guard next != last else { return false }
        last = next
        return true
    }
}
