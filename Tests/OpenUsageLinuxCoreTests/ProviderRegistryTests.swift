import Foundation
import Testing
@testable import OpenUsageLinuxCore

@Suite("Linux provider registry")
struct ProviderRegistryTests {
    @Test("Refresh is single-flight and runs at most four provider operations")
    func boundedSingleFlight() async {
        let gate = OperationGate(expectedStarts: 4)
        let registrations = (0..<8).map { index in
            ProviderSnapshotRegistration(
                providerID: "provider-\(index)",
                displayName: "Provider \(index)"
            ) {
                await gate.operationStarted()
                return ProviderUsageSnapshot(
                    providerID: "ignored", displayName: "Ignored", plan: nil,
                    metrics: [UsageMetric(kind: .value, label: "Value", used: Double(index))]
                )
            }
        }
        let registry = ProviderSnapshotRegistry(registrations: registrations)
        let started = Task { await gate.waitForExpectedStarts() }
        let callers = Task {
            await withTaskGroup(of: [ProviderUsageSnapshot].self, returning: [[ProviderUsageSnapshot]].self) { group in
                for _ in 0..<20 { group.addTask { await registry.snapshots(force: true) } }
                return await group.reduce(into: []) { $0.append($1) }
            }
        }

        await started.value
        #expect(await gate.maximumActive == 4)
        #expect(await gate.totalStarts == 4)
        await gate.releaseAll()
        let results = await callers.value

        #expect(results.count == 20)
        #expect(results.allSatisfy { $0.count == 8 })
        #expect(await gate.totalStarts == 8)
        #expect(await gate.maximumActive == 4)
    }

    @Test("Failed refresh preserves the last good card and annotates it as stale")
    func preservesLastGood() async throws {
        let fake = SequencedProvider()
        let links = [ProviderLink(label: "Dashboard", url: "https://example.com/usage")]
        let widgets = [WidgetDescriptor(id: "example.usage", title: "Usage", metricLabel: "Usage")]
        let registry = ProviderSnapshotRegistry(registrations: [
            ProviderSnapshotRegistration(
                providerID: "example", instanceID: "example@stable", displayName: "Example",
                links: links, widgets: widgets
            ) { try await fake.refresh() },
        ])

        let good = try #require(await registry.snapshots(force: true).first)
        let stale = try #require(await registry.snapshots(force: true).first)

        #expect(good.instanceID == "example@stable")
        #expect(stale.instanceID == good.instanceID)
        #expect(stale.metrics == good.metrics)
        #expect(stale.links == links)
        #expect(stale.widgets == widgets)
        #expect(stale.refreshedAt == good.refreshedAt)
        #expect(stale.errorMessage?.range(of: "stale", options: .caseInsensitive) != nil)
        #expect(stale.errorMessage?.contains("temporary failure") == true)
    }

    @Test("Pi metrics fold into matching cards without creating a Pi card")
    func piFoldIn() async throws {
        let registry = ProviderSnapshotRegistry(
            registrations: ["claude", "codex"].map { providerID in
                ProviderSnapshotRegistration(providerID: providerID, displayName: providerID.capitalized) {
                    ProviderUsageSnapshot(
                        providerID: providerID, displayName: providerID.capitalized, plan: nil,
                        metrics: [UsageMetric(kind: .progress, label: "Session", used: 10, limit: 100)]
                    )
                }
            },
            foldIns: [ProviderSnapshotFoldIn(providerIDs: ["claude"]) { _ in
                [UsageMetric(kind: .value, label: "Today", used: 1.25)]
            }]
        )

        let snapshots = await registry.snapshots(force: true)
        let claude = try #require(snapshots.first { $0.providerID == "claude" })
        let codex = try #require(snapshots.first { $0.providerID == "codex" })
        #expect(claude.metrics.map(\.label) == ["Session", "Today"])
        #expect(claude.widgets.contains { $0.id == "claude.today" })
        #expect(codex.metrics.map(\.label) == ["Session"])
        #expect(!snapshots.contains { $0.providerID == "pi" })
    }

    @Test("Cancelling a refresh reaches in-flight provider operations")
    func cancellationPropagates() async {
        let fake = CancellationProbe()
        let registry = ProviderSnapshotRegistry(registrations: [
            ProviderSnapshotRegistration(providerID: "cancel", displayName: "Cancel") {
                try await fake.refresh()
            },
        ])
        let subscribed = Task { await fake.waitUntilStarted() }
        let refresh = Task { await registry.snapshots(force: true) }
        await subscribed.value
        refresh.cancel()
        _ = await refresh.value
        await fake.waitUntilCancelled()
        #expect(await registry.cachedSnapshots().isEmpty)
    }

    @Test("Default repository registers every Linux card provider")
    func repositoryProviderCoverage() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = "sk-registry-secret-must-not-leak"
        let environment = [
            "HOME": root.path,
            "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
            "XDG_CACHE_HOME": root.appendingPathComponent("cache").path,
            "OPENROUTER_API_KEY": secret,
            "ZAI_API_KEY": secret,
        ]
        let paths = LinuxPaths(environment: environment)
        let repository = LinuxUsageRepository(
            credentials: LinuxCredentialStore(paths: paths),
            transport: NoNetworkTransport(),
            cache: SnapshotCache(paths: paths),
            environment: environment,
            credentialBackend: EmptyCredentialBackend()
        )

        let snapshots = await repository.refresh()
        #expect(Set(snapshots.map(\.providerID)) == Set(ProviderCatalog.cardEntries.map(\.id)))
        #expect(snapshots.allSatisfy { !$0.instanceID.isEmpty })
        #expect(snapshots.allSatisfy { !$0.links.contains(where: { $0.safeURL == nil }) })
        #expect(!snapshots.contains { $0.providerID == "pi" })
        let encoded = (try? JSONEncoder().encode(snapshots)).flatMap { String(data: $0, encoding: .utf8) }
        #expect(encoded?.contains(secret) == false)
    }
}

private actor OperationGate {
    private let expectedStarts: Int
    private var active = 0
    private(set) var maximumActive = 0
    private(set) var totalStarts = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    init(expectedStarts: Int) { self.expectedStarts = expectedStarts }

    func waitForExpectedStarts() async {
        if totalStarts >= expectedStarts { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func operationStarted() async {
        active += 1
        totalStarts += 1
        maximumActive = max(maximumActive, active)
        if totalStarts >= expectedStarts {
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        if !isReleased {
            await withCheckedContinuation { operationWaiters.append($0) }
        }
        active -= 1
    }

    func releaseAll() {
        isReleased = true
        let waiters = operationWaiters
        operationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor SequencedProvider {
    private var count = 0

    func refresh() throws -> ProviderUsageSnapshot {
        count += 1
        if count > 1 { throw FakeFailure() }
        return ProviderUsageSnapshot(
            providerID: "wrong", displayName: "Wrong", plan: "Pro",
            metrics: [UsageMetric(kind: .progress, label: "Usage", used: 20, limit: 100)],
            refreshedAt: Date(timeIntervalSince1970: 100)
        )
    }
}

private struct FakeFailure: Error, LocalizedError {
    var errorDescription: String? { "temporary failure" }
}

private actor CancellationProbe {
    private var started = false
    private var cancelled = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var operation: CheckedContinuation<Void, Error>?

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitUntilCancelled() async {
        if cancelled { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }

    func refresh() async throws -> ProviderUsageSnapshot {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { operation = $0 }
        } onCancel: {
            Task { await self.cancelOperation() }
        }
        throw CancellationError()
    }

    private func cancelOperation() {
        cancelled = true
        operation?.resume(throwing: CancellationError())
        operation = nil
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private struct NoNetworkTransport: HTTPTransport {
    func execute(_ request: URLRequest) async throws -> HTTPResult {
        throw URLError(.notConnectedToInternet)
    }
}

private struct EmptyCredentialBackend: LinuxCredentialBackend {
    func load(for key: LinuxCredentialKey) throws -> Data? { nil }
    func store(_ secret: Data, for key: LinuxCredentialKey) throws {}
    func remove(_ key: LinuxCredentialKey) throws {}
}
