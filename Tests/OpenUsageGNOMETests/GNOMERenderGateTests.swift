import Foundation
import OpenUsageLinuxCore
import Testing
@testable import OpenUsageGNOME

@Suite("GNOME render coalescing")
struct GNOMERenderGateTests {
    private let snapshot = ProviderUsageSnapshot(
        providerID: "codex",
        displayName: "Codex",
        plan: nil,
        metrics: [
            UsageMetric(kind: .progress, label: "Weekly", used: 42, limit: 100)
        ],
        refreshedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    @Test("Only data settings or loading changes consume a GTK render")
    func consumesDistinctRenderStates() {
        var gate = DashboardRenderGate()
        let settings = GNOMESettings()

        let first = gate.consume(
            snapshots: [snapshot],
            settings: settings,
            isRefreshing: false
        )
        let duplicate = gate.consume(
            snapshots: [snapshot],
            settings: settings,
            isRefreshing: false
        )
        #expect(first)
        #expect(!duplicate)

        var renamed = settings
        renamed.renameProvider("codex", to: "Work Codex")
        let renamedRender = gate.consume(
            snapshots: [snapshot],
            settings: renamed,
            isRefreshing: false
        )
        let loadingRender = gate.consume(
            snapshots: [snapshot],
            settings: renamed,
            isRefreshing: true
        )
        #expect(renamedRender)
        #expect(loadingRender)
    }

    @Test("Hidden provider changes independently consume Settings updates")
    func consumesHiddenProviderSettingsChanges() {
        var gate = DashboardRenderGate()
        let hidden = ProviderUsageSnapshot(
            providerID: "openrouter",
            displayName: "OpenRouter",
            plan: nil,
            metrics: [],
            refreshedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )

        let initial = gate.consumeProviderSettings(
            snapshots: [snapshot, hidden]
        )
        let duplicate = gate.consumeProviderSettings(
            snapshots: [snapshot, hidden]
        )
        let hiddenRemoved = gate.consumeProviderSettings(
            snapshots: [snapshot]
        )
        #expect(initial)
        #expect(!duplicate)
        #expect(hiddenRemoved)
    }
}
