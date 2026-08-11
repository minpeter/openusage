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

        #expect(gate.consume(
            snapshots: [snapshot],
            settings: settings,
            isRefreshing: false
        ))
        #expect(!gate.consume(
            snapshots: [snapshot],
            settings: settings,
            isRefreshing: false
        ))

        var renamed = settings
        renamed.renameProvider("codex", to: "Work Codex")
        #expect(gate.consume(
            snapshots: [snapshot],
            settings: renamed,
            isRefreshing: false
        ))
        #expect(gate.consume(
            snapshots: [snapshot],
            settings: renamed,
            isRefreshing: true
        ))
    }
}
