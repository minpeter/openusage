import Foundation
import OpenUsageLinuxCore
import Testing
@testable import OpenUsageGNOME

@Suite("GNOME API key operation ordering")
struct APIKeyOperationCoordinatorTests {
    @Test("An older save cannot overwrite a newer clear")
    func staleSaveIsIgnored() async throws {
        let backend = APIKeyMemoryBackend()
        let coordinator = APIKeyOperationCoordinator(
            manager: LinuxAPIKeyManager(backend: backend)
        )
        try LinuxAPIKeyManager(backend: backend).store(
            "existing",
            for: .openRouter
        )

        let cleared = await coordinator.clear(
            .openRouter,
            revision: 2
        )
        let staleSave = await coordinator.store(
            "older",
            for: .openRouter,
            revision: 1
        )

        #expect(cleared == .cleared)
        #expect(staleSave == .stale)
        #expect(try LinuxAPIKeyManager(backend: backend).load(
            for: .openRouter
        ) == nil)
    }

    @Test("A stale status lookup cannot replace mutation status")
    func staleStatusIsIgnored() async {
        let coordinator = APIKeyOperationCoordinator(
            manager: LinuxAPIKeyManager(backend: APIKeyMemoryBackend())
        )

        let stored = await coordinator.store(
            "new-key",
            for: .zai,
            revision: 4
        )
        let staleStatus = await coordinator.status(
            for: .zai,
            revision: 3
        )

        #expect(stored == .stored)
        #expect(staleStatus == .stale)
    }

    @Test("Performance probes exclude transient Secret Service work")
    func performanceProbeSkipsStatusLookups() {
        #expect(DashboardController.shouldRefreshAPIKeyStatuses(
            environment: ["OPENUSAGE_PERFORMANCE_RECEIPT": "/tmp/perf.json"]
        ) == false)
        #expect(DashboardController.shouldRefreshAPIKeyStatuses(
            environment: [:]
        ))
    }

    @Test("A latest failed mutation still refreshes changed credentials")
    func failedMutationRequiresRefresh() {
        #expect(APIKeyOperationResult.failed("clear failed")
            .requiresCredentialRefresh)
        #expect(!APIKeyOperationResult.status("Stored")
            .requiresCredentialRefresh)
        #expect(!APIKeyOperationResult.stale.requiresCredentialRefresh)
    }
}

private final class APIKeyMemoryBackend:
    LinuxCredentialBackend,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var values: [LinuxCredentialKey: Data] = [:]

    func load(for key: LinuxCredentialKey) throws -> Data? {
        lock.withLock { values[key] }
    }

    func store(_ secret: Data, for key: LinuxCredentialKey) throws {
        lock.withLock { values[key] = secret }
    }

    func remove(_ key: LinuxCredentialKey) throws {
        _ = lock.withLock { values.removeValue(forKey: key) }
    }
}
