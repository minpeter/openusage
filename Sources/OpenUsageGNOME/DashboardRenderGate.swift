import OpenUsageLinuxCore

struct DashboardRenderGate {
    private struct State: Equatable {
        let snapshots: [ProviderUsageSnapshot]
        let settings: GNOMESettings
        let isRefreshing: Bool
    }

    private var last: State?

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
