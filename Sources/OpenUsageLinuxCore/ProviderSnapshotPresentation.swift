import Foundation

public enum ProviderSnapshotPresentation {
    public static func ordered(
        _ snapshots: [ProviderUsageSnapshot],
        providerOrder: [String]
    ) -> [ProviderUsageSnapshot] {
        var positions: [String: Int] = [:]
        for (index, providerID) in providerOrder.enumerated() where positions[providerID] == nil {
            positions[providerID] = index
        }

        return snapshots.sorted { lhs, rhs in
            let left = positions[lhs.providerID] ?? Int.max
            let right = positions[rhs.providerID] ?? Int.max
            if left != right { return left < right }

            let leftLabel = lhs.accountLabel ?? lhs.displayName
            let rightLabel = rhs.accountLabel ?? rhs.displayName
            let labelOrder = leftLabel.localizedStandardCompare(rightLabel)
            if labelOrder != .orderedSame { return labelOrder == .orderedAscending }
            if lhs.providerID != rhs.providerID { return lhs.providerID < rhs.providerID }
            return lhs.instanceID < rhs.instanceID
        }
    }

    public static func visibleOrdered(
        _ snapshots: [ProviderUsageSnapshot],
        providerOrder: [String],
        hiddenProviderIDs: [String]
    ) -> [ProviderUsageSnapshot] {
        let hidden = Set(hiddenProviderIDs)
        return ordered(snapshots, providerOrder: providerOrder)
            .filter { !hidden.contains($0.providerID) }
    }
}
