import Foundation

public protocol ProviderSnapshotSource: Sendable {
    func knownProviderIDs() async -> Set<String>
    func snapshots(force: Bool) async -> [ProviderUsageSnapshot]
}

public struct ProviderSnapshotRegistration: Sendable {
    public let providerID: String
    public let instanceID: String?
    public let displayName: String
    public let links: [ProviderLink]
    public let widgets: [WidgetDescriptor]
    private let refreshOperation: @Sendable () async throws -> ProviderUsageSnapshot

    public init(
        providerID: String,
        instanceID: String? = nil,
        displayName: String? = nil,
        links: [ProviderLink] = [],
        widgets: [WidgetDescriptor] = [],
        refresh: @escaping @Sendable () async throws -> ProviderUsageSnapshot
    ) {
        self.providerID = providerID.lowercased()
        self.instanceID = instanceID
        self.displayName = displayName ?? providerID
        self.links = links
        self.widgets = widgets
        self.refreshOperation = refresh
    }

    func refresh() async throws -> ProviderUsageSnapshot { try await refreshOperation() }

    func normalized(_ snapshot: ProviderUsageSnapshot) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            providerID: providerID,
            instanceID: instanceID ?? snapshot.instanceID,
            displayName: displayName,
            accountLabel: snapshot.accountLabel,
            plan: snapshot.plan,
            metrics: snapshot.metrics,
            links: links.isEmpty ? snapshot.links : links,
            widgets: widgets.isEmpty ? snapshot.widgets : widgets,
            refreshedAt: snapshot.refreshedAt,
            errorMessage: snapshot.errorMessage,
            warning: snapshot.warning
        )
    }

    func failure(_ error: Error, previous: ProviderUsageSnapshot?, now: Date) -> ProviderUsageSnapshot {
        if let previous, previous.errorMessage == nil, !previous.metrics.isEmpty {
            return ProviderUsageSnapshot(
                providerID: previous.providerID, instanceID: previous.instanceID,
                displayName: previous.displayName, accountLabel: previous.accountLabel,
                plan: previous.plan, metrics: previous.metrics, links: previous.links,
                widgets: previous.widgets, refreshedAt: previous.refreshedAt,
                errorMessage: "Stale data: \(error.localizedDescription)", warning: previous.warning
            )
        }
        return ProviderUsageSnapshot(
            providerID: providerID, instanceID: instanceID ?? providerID, displayName: displayName,
            plan: nil, metrics: [], links: links, widgets: widgets, refreshedAt: now,
            errorMessage: error.localizedDescription
        )
    }
}

public struct ProviderSnapshotFoldIn: Sendable {
    public let providerIDs: Set<String>
    private let operation: @Sendable (ProviderUsageSnapshot) async throws -> [UsageMetric]

    public init(
        providerIDs: Set<String>,
        operation: @escaping @Sendable (ProviderUsageSnapshot) async throws -> [UsageMetric]
    ) {
        self.providerIDs = Set(providerIDs.map { $0.lowercased() })
        self.operation = operation
    }

    func metrics(for snapshot: ProviderUsageSnapshot) async throws -> [UsageMetric] {
        try await operation(snapshot)
    }
}

public actor ProviderSnapshotRegistry: ProviderSnapshotSource {
    private let registrations: [ProviderSnapshotRegistration]
    private let registeredProviderIDs: Set<String>
    private let foldIns: [ProviderSnapshotFoldIn]
    private let cache: SnapshotCache?
    private let maximumConcurrentRefreshes: Int
    private let now: @Sendable () -> Date
    private var current: [ProviderUsageSnapshot]
    private var activeRefresh: Task<[ProviderUsageSnapshot], Never>?

    public init(
        registrations: [ProviderSnapshotRegistration],
        knownProviderIDs: Set<String>? = nil,
        foldIns: [ProviderSnapshotFoldIn] = [],
        cache: SnapshotCache? = nil,
        maximumConcurrentRefreshes: Int = 4,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.registrations = registrations
        self.registeredProviderIDs = knownProviderIDs ?? Set(registrations.map(\.providerID))
        self.foldIns = foldIns
        self.cache = cache
        self.maximumConcurrentRefreshes = min(max(1, maximumConcurrentRefreshes), 4)
        self.now = now
        self.current = (try? cache?.load()) ?? []
    }

    public func knownProviderIDs() -> Set<String> {
        registeredProviderIDs.union(current.map(\.providerID)).union(current.map(\.instanceID))
    }

    public func cachedSnapshots() -> [ProviderUsageSnapshot] { current }

    public func snapshots(force: Bool) async -> [ProviderUsageSnapshot] {
        let fresh = current.allSatisfy { now().timeIntervalSince($0.refreshedAt) < LinuxUsageAPI.cacheLifetime }
        if !force, !current.isEmpty, fresh { return current }
        if let activeRefresh { return await awaitRefresh(activeRefresh) }

        let previous = Dictionary(uniqueKeysWithValues: current.map { ($0.instanceID, $0) })
        let task = Task {
            await Self.refresh(
                registrations, foldIns: foldIns, previous: previous,
                maximumConcurrent: maximumConcurrentRefreshes, now: now()
            )
        }
        activeRefresh = task
        let refreshed = await awaitRefresh(task)
        activeRefresh = nil
        guard !Task.isCancelled, !task.isCancelled else { return current }
        current = refreshed
        try? cache?.save(refreshed)
        return refreshed
    }

    private func awaitRefresh(_ task: Task<[ProviderUsageSnapshot], Never>) async -> [ProviderUsageSnapshot] {
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    private static func refresh(
        _ registrations: [ProviderSnapshotRegistration],
        foldIns: [ProviderSnapshotFoldIn],
        previous: [String: ProviderUsageSnapshot],
        maximumConcurrent: Int,
        now: Date
    ) async -> [ProviderUsageSnapshot] {
        var snapshots = await withTaskGroup(
            of: (Int, ProviderUsageSnapshot?).self,
            returning: [ProviderUsageSnapshot].self
        ) { group in
            var iterator = registrations.enumerated().makeIterator()
            func submit(_ item: (offset: Int, element: ProviderSnapshotRegistration)) {
                group.addTask {
                    let previousSnapshot = previous[item.element.instanceID ?? item.element.providerID]
                        ?? previous.values.first { $0.providerID == item.element.providerID }
                    do {
                        try Task.checkCancellation()
                        let snapshot = item.element.normalized(try await item.element.refresh())
                        try Task.checkCancellation()
                        if let message = snapshot.errorMessage {
                            return (item.offset, item.element.failure(
                                RegistryRefreshError(message), previous: previousSnapshot, now: now
                            ))
                        }
                        return (item.offset, snapshot)
                    } catch is CancellationError { return (item.offset, nil) }
                    catch {
                        return (item.offset, item.element.failure(
                            error, previous: previousSnapshot, now: now
                        ))
                    }
                }
            }
            for _ in 0..<min(maximumConcurrent, registrations.count) {
                if let item = iterator.next() { submit(item) }
            }
            var results: [(Int, ProviderUsageSnapshot)] = []
            while let (index, snapshot) = await group.next() {
                if let snapshot { results.append((index, snapshot)) }
                if !Task.isCancelled, let item = iterator.next() { submit(item) }
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
        guard !Task.isCancelled else { return [] }

        for foldIn in foldIns {
            for index in snapshots.indices where foldIn.providerIDs.contains(snapshots[index].providerID) {
                do {
                    try Task.checkCancellation()
                    let metrics = try await foldIn.metrics(for: snapshots[index])
                    guard !metrics.isEmpty else { continue }
                    let snapshot = snapshots[index]
                    var seen = Set(snapshot.widgets.map(\.id))
                    let foldInWidgets = PiLinuxUsageScanner.widgetDescriptors(forCardID: snapshot.instanceID)
                        .filter { seen.insert($0.id).inserted }
                    snapshots[index] = ProviderUsageSnapshot(
                        providerID: snapshot.providerID, instanceID: snapshot.instanceID,
                        displayName: snapshot.displayName, accountLabel: snapshot.accountLabel,
                        plan: snapshot.plan, metrics: snapshot.metrics + metrics, links: snapshot.links,
                        widgets: snapshot.widgets + foldInWidgets, refreshedAt: snapshot.refreshedAt,
                        errorMessage: snapshot.errorMessage, warning: snapshot.warning
                    )
                } catch is CancellationError {
                    return []
                } catch {
                    // Pi/local metrics are supplementary; preserve the provider snapshot on scan failure.
                }
            }
        }
        return snapshots
    }
}

private struct RegistryRefreshError: Error, LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
