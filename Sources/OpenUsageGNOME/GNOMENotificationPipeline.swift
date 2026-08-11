import OpenUsageLinuxCore

struct GNOMENotificationState: Sendable {
    let snapshots: [ProviderUsageSnapshot]
    let toggles: UsageNotificationToggles
    let revision: UInt64
}

actor GNOMENotificationPipeline {
    typealias Delivery = @Sendable (GNOMENotificationState) async -> Void

    private let deliver: Delivery
    private var latestRevision: UInt64 = 0
    private var pending: GNOMENotificationState?
    private var workerRunning = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(deliver: @escaping Delivery) {
        self.deliver = deliver
    }

    func submit(_ state: GNOMENotificationState) {
        guard state.revision > latestRevision else { return }
        latestRevision = state.revision
        pending = state
        guard !workerRunning else { return }
        workerRunning = true
        Task { await drain() }
    }

    func waitUntilIdle() async {
        guard workerRunning || pending != nil else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    private func drain() async {
        while let next = pending {
            pending = nil
            await deliver(next)
        }
        workerRunning = false
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
