import Foundation
import OpenUsageCore
import Testing

@Suite("OpenUsageCore domain identity")
struct OpenUsageCoreDomainTests {
    @Test("usage metrics calculate bounded fractions")
    func usageMetricFraction() {
        let metric = UsageMetric(
            kind: .progress,
            label: "Current Session",
            used: 75,
            limit: 100,
            resetsAt: Date(timeIntervalSince1970: 1_700_000_000),
            periodDurationMilliseconds: 18_000_000
        )

        #expect(metric.fraction == 0.75)
        #expect(metric.periodDurationMilliseconds == 18_000_000)
        #expect(metric.periodDurationMs == nil)
    }

    @Test("provider snapshots round-trip shared metrics")
    func providerSnapshotRoundTrip() throws {
        let snapshot = ProviderUsageSnapshot(
            providerID: "codex",
            instanceID: "codex:work@example.com",
            displayName: "Codex",
            accountLabel: "work@example.com",
            plan: "Pro",
            metrics: [
                UsageMetric(
                    kind: .progress,
                    label: "Weekly",
                    used: 40,
                    limit: 100)
            ],
            links: [],
            widgets: [],
            refreshedAt: Date(timeIntervalSince1970: 1_700_000_100))

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ProviderUsageSnapshot.self, from: data)

        #expect(decoded == snapshot)
        #expect(decoded.instanceID == "codex:work@example.com")
        #expect(decoded.metrics.first?.fraction == 0.4)
    }

    @Test("macOS metric values use the shared core identity")
    func metricValueIdentity() {
        let value = MetricValue(
            number: 4.21,
            kind: .dollars,
            label: "spent",
            estimated: true)

        #expect(value.number == 4.21)
        #expect(value.kind == .dollars)
        #expect(value.label == "spent")
        #expect(value.estimated)
    }
}
