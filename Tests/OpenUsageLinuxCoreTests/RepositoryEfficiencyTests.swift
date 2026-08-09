import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenUsageLinuxCore

@Suite("Repository efficiency")
struct RepositoryEfficiencyTests {
    @Test("Concurrent refresh callers share one provider pass")
    func refreshIsSingleFlight() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = LinuxPaths(environment: [
            "HOME": root.path,
            "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
            "XDG_CACHE_HOME": root.appendingPathComponent("cache").path,
        ])
        try FileManager.default.createDirectory(
            at: paths.claudeCredentials.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(
            """
            {"claudeAiOauth":{"accessToken":"claude-token","subscriptionType":"pro"}}
            """.utf8
        ).write(to: paths.claudeCredentials)
        let codexPath = try #require(paths.codexAuthCandidates.last)
        try FileManager.default.createDirectory(
            at: codexPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(
            """
            {"tokens":{"access_token":"codex-token","account_id":"account"}}
            """.utf8
        ).write(to: codexPath)

        let baselineTransport = CountingTransport()
        let baselineRepository = LinuxUsageRepository(
            credentials: LinuxCredentialStore(paths: paths),
            transport: baselineTransport,
            cache: SnapshotCache(paths: paths)
        )
        let baselineSnapshots = await baselineRepository.refresh()
        let baselineRequests = await baselineTransport.requestCount

        let transport = CountingTransport()
        let repository = LinuxUsageRepository(
            credentials: LinuxCredentialStore(paths: paths),
            transport: transport,
            cache: SnapshotCache(paths: paths)
        )

        await withTaskGroup(of: [ProviderUsageSnapshot].self) { group in
            for _ in 0..<50 {
                group.addTask { await repository.refresh() }
            }
            for await snapshots in group {
                #expect(snapshots.count == baselineSnapshots.count)
            }
        }

        #expect(await transport.requestCount == baselineRequests)
    }

    @Test("Response accumulator rejects oversized bodies")
    func responseAccumulatorRejectsOversizedBodies() throws {
        var accumulator = BoundedDataAccumulator(maximumBytes: 8)

        try accumulator.append(Data([0, 1, 2, 3]))
        try accumulator.append(Data([4, 5, 6, 7]))

        #expect(accumulator.data.count == 8)
        #expect(throws: ResponseLimitError.exceeded(maximumBytes: 8)) {
            try accumulator.append(Data([8]))
        }
    }

    @Test("Response policy rejects oversized declared lengths")
    func responsePolicyRejectsDeclaredLengths() {
        let policy = ResponseSizePolicy(maximumBytes: 512)

        #expect(policy.allows(expectedContentLength: -1))
        #expect(policy.allows(expectedContentLength: 512))
        #expect(!policy.allows(expectedContentLength: 513))
    }

    @Test("Snapshot cache rejects files above one MiB")
    func snapshotCacheRejectsOversizedFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = LinuxPaths(environment: [
            "HOME": root.path,
            "XDG_CACHE_HOME": root.appendingPathComponent("cache").path,
        ])
        try paths.prepareStorage()
        try Data(repeating: 0, count: 1_048_577).write(to: paths.snapshotCache)

        #expect(throws: SnapshotCacheError.fileTooLarge(maximumBytes: 1_048_576)) {
            try SnapshotCache(paths: paths).load()
        }
    }

    @Test("Snapshot cache rejects unbounded provider counts")
    func snapshotCacheRejectsUnboundedProviderCounts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = LinuxPaths(environment: [
            "HOME": root.path,
            "XDG_CACHE_HOME": root.appendingPathComponent("cache").path,
        ])
        let snapshots = (0..<33).map {
            ProviderUsageSnapshot(
                providerID: "provider-\($0)",
                displayName: "Provider \($0)",
                plan: nil,
                metrics: []
            )
        }

        #expect(throws: SnapshotCacheError.tooManyProviders(maximum: 32)) {
            try SnapshotCache(paths: paths).save(snapshots)
        }
    }
}

private actor CountingTransport: HTTPTransport {
    private(set) var requestCount = 0

    func execute(_ request: URLRequest) async throws -> HTTPResult {
        requestCount += 1
        await Task.yield()
        if request.url?.host == "api.anthropic.com" {
            return HTTPResult(
                data: Data(
                    """
                    {"five_hour":{"utilization":10},"seven_day":{"utilization":20}}
                    """.utf8
                ),
                statusCode: 200
            )
        }
        return HTTPResult(
            data: Data(
                """
                {"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":30,"limit_window_seconds":18000}}}
                """.utf8
            ),
            statusCode: 200
        )
    }
}
