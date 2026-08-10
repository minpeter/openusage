import Foundation
import Testing
@testable import OpenUsageLinuxCore

@Suite("Provider snapshot presentation")
struct ProviderSnapshotPresentationTests {
    @Test("Ordering and visibility are stable across repository permutations")
    func stableAcrossRefreshPermutations() {
        let claude = snapshot(providerID: "claude", name: "Claude")
        let codex = snapshot(providerID: "codex", name: "Codex")
        let antigravity = snapshot(providerID: "antigravity", name: "Antigravity")
        let order = ["codex", "antigravity", "claude"]

        let before = ProviderSnapshotPresentation.visibleOrdered(
            [claude, codex, antigravity],
            providerOrder: order,
            hiddenProviderIDs: ["antigravity"]
        )
        let during = ProviderSnapshotPresentation.visibleOrdered(
            [antigravity, claude, codex],
            providerOrder: order,
            hiddenProviderIDs: ["antigravity"]
        )

        #expect(before.map(\.providerID) == ["codex", "claude"])
        #expect(during.map(\.providerID) == before.map(\.providerID))
    }

    private func snapshot(providerID: String, name: String) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            providerID: providerID,
            instanceID: providerID,
            displayName: name,
            accountLabel: nil,
            plan: nil,
            metrics: [],
            links: [],
            refreshedAt: Date(timeIntervalSince1970: 0)
        )
    }
}
