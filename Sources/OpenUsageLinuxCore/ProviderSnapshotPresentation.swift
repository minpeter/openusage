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

        let sorted = snapshots.sorted { lhs, rhs in
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
        return uniqueCards(sorted)
    }

    /// One card per account. Bare catalog/cache/file-fallback cards that share a
    /// provider ID collapse so Overview, Providers, and Settings stay aligned.
    public static func uniqueCards(
        _ snapshots: [ProviderUsageSnapshot]
    ) -> [ProviderUsageSnapshot] {
        var result: [ProviderUsageSnapshot] = []
        var indexByKey: [String: Int] = [:]
        for snapshot in snapshots {
            let key = cardKey(snapshot)
            if let index = indexByKey[key] {
                result[index] = preferred(result[index], snapshot)
                continue
            }
            indexByKey[key] = result.count
            result.append(snapshot)
        }
        return result
    }

    public static func uniqueProviderIDs(
        _ snapshots: [ProviderUsageSnapshot]
    ) -> [String] {
        var seen: Set<String> = []
        return snapshots.compactMap { snapshot in
            seen.insert(snapshot.providerID).inserted ? snapshot.providerID : nil
        }
    }

    private static func cardKey(_ snapshot: ProviderUsageSnapshot) -> String {
        if let account = snapshot.accountLabel, !account.isEmpty {
            return "\(snapshot.providerID)|account:\(account)"
        }
        // Claude-style extra accounts use `provider@hash`, not `provider:…`.
        if snapshot.instanceID != snapshot.providerID,
           !snapshot.instanceID.hasPrefix("\(snapshot.providerID):")
        {
            return snapshot.instanceID
        }
        return "\(snapshot.providerID)|bare"
    }

    private static func preferred(
        _ current: ProviderUsageSnapshot,
        _ incoming: ProviderUsageSnapshot
    ) -> ProviderUsageSnapshot {
        let currentScore = cardScore(current)
        let incomingScore = cardScore(incoming)
        if incomingScore != currentScore {
            return incomingScore > currentScore ? incoming : current
        }
        return incoming.refreshedAt > current.refreshedAt ? incoming : current
    }

    private static func cardScore(_ snapshot: ProviderUsageSnapshot) -> Int {
        var score = 0
        if snapshot.errorMessage == nil { score += 4 }
        if !snapshot.metrics.isEmpty { score += 2 }
        if snapshot.accountLabel != nil { score += 1 }
        return score
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
