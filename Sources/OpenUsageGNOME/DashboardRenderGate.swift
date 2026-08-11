import OpenUsageLinuxCore

enum DashboardRenderChange: Equatable {
    case none
    case loading
    case content
}

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
        consumeChange(
            snapshots: snapshots,
            settings: settings,
            isRefreshing: isRefreshing
        ) != .none
    }

    mutating func consumeChange(
        snapshots: [ProviderUsageSnapshot],
        settings: GNOMESettings,
        isRefreshing: Bool
    ) -> DashboardRenderChange {
        let next = State(
            snapshots: snapshots,
            settings: settings,
            isRefreshing: isRefreshing
        )
        guard next != last else { return .none }
        let change: DashboardRenderChange
        if let last,
           last.snapshots == next.snapshots,
           last.settings == next.settings
        {
            change = .loading
        } else {
            change = .content
        }
        last = next
        return change
    }
}
