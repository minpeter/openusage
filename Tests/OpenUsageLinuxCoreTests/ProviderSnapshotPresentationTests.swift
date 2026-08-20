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

    @Test("Bare Antigravity cards collapse to one identity across surfaces")
    func collapsesBareAntigravityDuplicates() {
        let live = snapshot(
            providerID: "antigravity",
            name: "Antigravity",
            metrics: [UsageMetric(kind: .progress, label: "Session", used: 10, limit: 100)],
            refreshedAt: Date(timeIntervalSince1970: 20)
        )
        let stale = snapshot(
            providerID: "antigravity",
            instanceID: "antigravity:file",
            name: "Antigravity",
            refreshedAt: Date(timeIntervalSince1970: 10)
        )
        let claude = snapshot(providerID: "claude", name: "Claude")
        let extraClaude = snapshot(
            providerID: "claude",
            instanceID: "claude@work",
            name: "Claude (Work)"
        )

        let visible = ProviderSnapshotPresentation.visibleOrdered(
            [stale, claude, extraClaude, live],
            providerOrder: ["antigravity", "claude"],
            hiddenProviderIDs: []
        )

        #expect(visible.map(\.providerID) == ["antigravity", "claude", "claude"])
        #expect(visible.map(\.instanceID) == ["antigravity", "claude", "claude@work"])
        #expect(visible[0].metrics.count == 1)
        #expect(ProviderSnapshotPresentation.uniqueProviderIDs(visible) == [
            "antigravity", "claude",
        ])
    }

    private func snapshot(
        providerID: String,
        instanceID: String? = nil,
        name: String,
        metrics: [UsageMetric] = [],
        refreshedAt: Date = Date(timeIntervalSince1970: 0)
    ) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            providerID: providerID,
            instanceID: instanceID ?? providerID,
            displayName: name,
            accountLabel: nil,
            plan: nil,
            metrics: metrics,
            links: [],
            refreshedAt: refreshedAt
        )
    }
}
