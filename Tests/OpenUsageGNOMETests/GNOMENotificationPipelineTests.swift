import OpenUsageLinuxCore
import Testing
@testable import OpenUsageGNOME

@Suite("GNOME notification refresh ordering")
struct GNOMENotificationPipelineTests {
    @Test("Older refreshes cannot follow a newer notification state")
    func staleRefreshIsIgnored() async {
        let recorder = NotificationRevisionRecorder()
        let pipeline = GNOMENotificationPipeline { state in
            await recorder.record(state.revision)
        }

        await pipeline.submit(state(revision: 2))
        await pipeline.submit(state(revision: 1))
        await pipeline.waitUntilIdle()
        await pipeline.submit(state(revision: 4))
        await pipeline.submit(state(revision: 3))
        await pipeline.waitUntilIdle()

        #expect(await recorder.revisions == [2, 4])
    }

    private func state(revision: UInt64) -> GNOMENotificationState {
        GNOMENotificationState(
            snapshots: [],
            toggles: UsageNotificationToggles(
                almostOut: true,
                cuttingItClose: true,
                willRunOut: true
            ),
            revision: revision
        )
    }
}

private actor NotificationRevisionRecorder {
    private(set) var revisions: [UInt64] = []

    func record(_ revision: UInt64) {
        revisions.append(revision)
    }
}
