import Foundation
import Testing
@testable import OpenUsageLinuxCore

@Suite("Usage threshold notifications")
struct UsageThresholdNotificationTests {
    private let reset = Date(timeIntervalSince1970: 1_786_492_800)

    @Test("First observation primes without notifying")
    func primesWithoutFiring() {
        let transition = UsageThresholdNotificationPolicy.transitions(
            bucket: .runningOut,
            remainingFraction: 0.05,
            resetsAt: reset,
            previous: .init(),
            toggles: .allEnabled
        )

        #expect(transition.milestones.isEmpty)
        #expect(transition.state.primed)
        #expect(transition.state.previousBucket == .runningOut)
        #expect(transition.state.wasUnderTenPercent)
    }

    @Test("Worsening pace fires adjacent milestones and dedupes delivery")
    func worseningEdges() {
        var state = primed(bucket: .healthy, remaining: 0.5)

        let close = UsageThresholdNotificationPolicy.transitions(
            bucket: .close,
            remainingFraction: 0.4,
            resetsAt: reset,
            previous: state,
            toggles: .allEnabled
        )
        #expect(close.milestones == [.cuttingItClose])
        state = close.state.markingDelivered(close.milestones)

        let duplicate = UsageThresholdNotificationPolicy.transitions(
            bucket: .close,
            remainingFraction: 0.4,
            resetsAt: reset,
            previous: state,
            toggles: .allEnabled
        )
        #expect(duplicate.milestones.isEmpty)

        let runningOut = UsageThresholdNotificationPolicy.transitions(
            bucket: .runningOut,
            remainingFraction: 0.3,
            resetsAt: reset,
            previous: duplicate.state,
            toggles: .allEnabled
        )
        #expect(runningOut.milestones == [.willRunOut])
    }

    @Test("Healthy to running out skips the intermediate alert")
    func severityJump() {
        let transition = UsageThresholdNotificationPolicy.transitions(
            bucket: .runningOut,
            remainingFraction: 0.5,
            resetsAt: reset,
            previous: primed(bucket: .healthy, remaining: 0.5),
            toggles: .allEnabled
        )

        #expect(transition.milestones == [.willRunOut])
    }

    @Test("Almost Out fires below ten percent and rearms after recovery")
    func almostOutRearms() {
        var state = primed(bucket: .healthy, remaining: 0.2)
        let first = UsageThresholdNotificationPolicy.transitions(
            bucket: .healthy,
            remainingFraction: 0.09,
            resetsAt: reset,
            previous: state,
            toggles: .allEnabled
        )
        #expect(first.milestones == [.almostOut])
        state = first.state.markingDelivered(first.milestones)

        let recovered = UsageThresholdNotificationPolicy.transitions(
            bucket: .healthy,
            remainingFraction: 0.2,
            resetsAt: reset,
            previous: state,
            toggles: .allEnabled
        )
        let second = UsageThresholdNotificationPolicy.transitions(
            bucket: .healthy,
            remainingFraction: 0.09,
            resetsAt: reset,
            previous: recovered.state,
            toggles: .allEnabled
        )

        #expect(second.milestones == [.almostOut])
    }

    @Test("A disabled trigger does not consume its worsening edge")
    func disabledTriggerDoesNotConsume() {
        let previous = primed(bucket: .healthy, remaining: 0.5)
        let disabled = UsageThresholdNotificationPolicy.transitions(
            bucket: .close,
            remainingFraction: 0.4,
            resetsAt: reset,
            previous: previous,
            toggles: .init(almostOut: true, cuttingItClose: false, willRunOut: true)
        )
        #expect(disabled.milestones.isEmpty)
        #expect(disabled.state.previousBucket == .healthy)

        let enabled = UsageThresholdNotificationPolicy.transitions(
            bucket: .close,
            remainingFraction: 0.4,
            resetsAt: reset,
            previous: disabled.state,
            toggles: .allEnabled
        )
        #expect(enabled.milestones == [.cuttingItClose])
    }

    @Test("Only a meaningfully later reset rearms delivered milestones")
    func resetWindowJitter() {
        var state = primed(bucket: .healthy, remaining: 0.2)
        state = state.markingDelivered([.almostOut])

        let jitter = UsageThresholdNotificationPolicy.transitions(
            bucket: .healthy,
            remainingFraction: 0.09,
            resetsAt: reset.addingTimeInterval(0.5),
            previous: state,
            toggles: .allEnabled
        )
        #expect(jitter.milestones.isEmpty)

        let advanced = UsageThresholdNotificationPolicy.transitions(
            bucket: .healthy,
            remainingFraction: 0.09,
            resetsAt: reset.addingTimeInterval(2),
            previous: jitter.state,
            toggles: .allEnabled
        )
        #expect(advanced.milestones == [.almostOut])
    }

    @Test("Metric projection maps to healthy close and running-out buckets")
    func metricProjection() {
        let now = Date(timeIntervalSince1970: 1_786_451_400)
        #expect(UsageThresholdNotificationPolicy.bucket(
            metric: progress(used: 30, now: now),
            now: now
        ) == .healthy)
        #expect(UsageThresholdNotificationPolicy.bucket(
            metric: progress(used: 48, now: now),
            now: now
        ) == .close)
        #expect(UsageThresholdNotificationPolicy.bucket(
            metric: progress(used: 60, now: now),
            now: now
        ) == .runningOut)
    }

    @Test("Coordinator retries failed delivery and dedupes success")
    func coordinatorDelivery() async {
        let now = Date(timeIntervalSince1970: 1_786_451_400)
        let coordinator = UsageThresholdNotificationCoordinator()
        _ = await coordinator.events(
            snapshots: [snapshot(instanceID: "claude-work", used: 30, now: now)],
            toggles: .allEnabled,
            now: now
        )

        let first = await coordinator.events(
            snapshots: [snapshot(instanceID: "claude-work", used: 48, now: now)],
            toggles: .allEnabled,
            now: now
        )
        #expect(first.map(\.milestone) == [.cuttingItClose])
        #expect(first.first?.subtitle == "Claude · Work · Session")

        let retried = await coordinator.events(
            snapshots: [snapshot(instanceID: "claude-work", used: 48, now: now)],
            toggles: .allEnabled,
            now: now
        )
        #expect(retried == first)

        if let event = first.first {
            await coordinator.markDelivered(event)
        }
        let deduped = await coordinator.events(
            snapshots: [snapshot(instanceID: "claude-work", used: 48, now: now)],
            toggles: .allEnabled,
            now: now
        )
        #expect(deduped.isEmpty)
    }

    @Test("Coordinator tracks accounts independently")
    func coordinatorAccounts() async {
        let now = Date(timeIntervalSince1970: 1_786_451_400)
        let coordinator = UsageThresholdNotificationCoordinator()
        _ = await coordinator.events(
            snapshots: [
                snapshot(instanceID: "claude-work", account: "Work", used: 30, now: now),
                snapshot(instanceID: "claude-personal", account: "Personal", used: 30, now: now),
            ],
            toggles: .allEnabled,
            now: now
        )

        let events = await coordinator.events(
            snapshots: [
                snapshot(instanceID: "claude-work", account: "Work", used: 48, now: now),
                snapshot(instanceID: "claude-personal", account: "Personal", used: 60, now: now),
            ],
            toggles: .allEnabled,
            now: now
        )

        #expect(Set(events.map(\.subtitle)) == [
            "Claude · Work · Session",
            "Claude · Personal · Session",
        ])
        #expect(Set(events.map(\.milestone)) == [.cuttingItClose, .willRunOut])
    }

    @Test("Coordinator drops pending alerts after recovery")
    func coordinatorRecovery() async {
        let now = Date(timeIntervalSince1970: 1_786_451_400)
        let coordinator = UsageThresholdNotificationCoordinator()
        _ = await coordinator.events(
            snapshots: [snapshot(instanceID: "claude", used: 30, now: now)],
            toggles: .allEnabled,
            now: now
        )
        let pending = await coordinator.events(
            snapshots: [snapshot(instanceID: "claude", used: 48, now: now)],
            toggles: .allEnabled,
            now: now
        )
        #expect(pending.map(\.milestone) == [.cuttingItClose])

        let recovered = await coordinator.events(
            snapshots: [snapshot(instanceID: "claude", used: 30, now: now)],
            toggles: .allEnabled,
            now: now
        )
        #expect(recovered.isEmpty)

        let worsenedAgain = await coordinator.events(
            snapshots: [snapshot(instanceID: "claude", used: 48, now: now)],
            toggles: .allEnabled,
            now: now
        )
        #expect(worsenedAgain.map(\.milestone) == [.cuttingItClose])
    }

    @Test("Disabling a pending alert suppresses it without consuming the edge")
    func coordinatorToggleChange() async {
        let now = Date(timeIntervalSince1970: 1_786_451_400)
        let coordinator = UsageThresholdNotificationCoordinator()
        _ = await coordinator.events(
            snapshots: [snapshot(instanceID: "claude", used: 30, now: now)],
            toggles: .allEnabled,
            now: now
        )
        let pending = await coordinator.events(
            snapshots: [snapshot(instanceID: "claude", used: 48, now: now)],
            toggles: .allEnabled,
            now: now
        )
        #expect(pending.map(\.milestone) == [.cuttingItClose])

        let disabled = await coordinator.events(
            snapshots: [snapshot(instanceID: "claude", used: 48, now: now)],
            toggles: .init(almostOut: true, cuttingItClose: false, willRunOut: true),
            now: now
        )
        #expect(disabled.isEmpty)

        let enabledAgain = await coordinator.events(
            snapshots: [snapshot(instanceID: "claude", used: 48, now: now)],
            toggles: .allEnabled,
            now: now
        )
        #expect(enabledAgain.map(\.milestone) == [.cuttingItClose])
    }

    private func primed(
        bucket: UsageNotificationPaceBucket,
        remaining: Double
    ) -> UsageNotificationState {
        UsageThresholdNotificationPolicy.transitions(
            bucket: bucket,
            remainingFraction: remaining,
            resetsAt: reset,
            previous: .init(),
            toggles: .allEnabled
        ).state
    }

    private func progress(used: Double, now: Date) -> UsageMetric {
        UsageMetric(
            kind: .progress,
            label: "Session",
            used: used,
            limit: 100,
            resetsAt: now.addingTimeInterval(7_200),
            periodDurationMilliseconds: 14_400_000
        )
    }

    private func snapshot(
        instanceID: String,
        account: String = "Work",
        used: Double,
        now: Date
    ) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            providerID: "claude",
            instanceID: instanceID,
            displayName: "Claude",
            accountLabel: account,
            plan: nil,
            metrics: [progress(used: used, now: now)],
            links: [],
            refreshedAt: now
        )
    }
}
