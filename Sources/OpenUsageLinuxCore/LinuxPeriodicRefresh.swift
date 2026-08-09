import Foundation

/// The scheduler depends on the repository-wide refresh entry point, not individual provider adapters.
/// LinuxUsageRepository.refresh() and ProviderSnapshotRegistry.snapshots(force:) are both single-flight.
public protocol LinuxDesktopRefreshRepository: Sendable {
    func refresh() async -> [ProviderUsageSnapshot]
}

extension LinuxUsageRepository: LinuxDesktopRefreshRepository {}

public protocol LinuxPeriodicRefreshClock: Sendable {
    func ticks(every interval: Duration) -> AsyncStream<Void>
}

public struct ContinuousLinuxRefreshClock: LinuxPeriodicRefreshClock {
    public init() {}

    public func ticks(every interval: Duration) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: interval) } catch { break }
                    guard !Task.isCancelled else { break }
                    continuation.yield(())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// A cancellation-bounded periodic loop. Overlapping ticks cannot start provider work in parallel:
/// this loop awaits each repository-wide single-flight refresh before consuming the next tick.
public actor LinuxPeriodicRefreshService {
    private let repository: any LinuxDesktopRefreshRepository
    private let clock: any LinuxPeriodicRefreshClock
    private let interval: Duration
    private var task: Task<Void, Never>?

    public init(
        repository: any LinuxDesktopRefreshRepository,
        interval: Duration,
        clock: any LinuxPeriodicRefreshClock = ContinuousLinuxRefreshClock()
    ) {
        self.repository = repository
        self.interval = interval
        self.clock = clock
    }

    public func start() {
        guard task == nil else { return }
        let repository = repository
        let ticks = clock.ticks(every: interval)
        task = Task {
            for await _ in ticks {
                guard !Task.isCancelled else { break }
                _ = await repository.refresh()
            }
        }
    }

    public func stop() async {
        let active = task
        task = nil
        active?.cancel()
        await active?.value
    }
}
