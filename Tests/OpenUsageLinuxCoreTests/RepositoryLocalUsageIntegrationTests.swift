import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenUsageLinuxCore

@Suite("Repository local usage integration")
struct RepositoryLocalUsageIntegrationTests {
    @Test("Default Claude card includes local spend and history")
    func claudeCardIncludesLocalUsage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root
            .appendingPathComponent(".claude/projects/demo", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let log = """
        {"timestamp":"2026-08-09T12:00:00Z","requestId":"request-1","isSidechain":false,"message":{"id":"message-1","model":"claude-sonnet-4-5","usage":{"input_tokens":1000,"output_tokens":250}}}
        """
        try Data(log.utf8).write(to: project.appendingPathComponent("session.jsonl"))

        let environment = [
            "HOME": root.path,
            "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
            "XDG_CACHE_HOME": root.appendingPathComponent("cache").path,
        ]
        let paths = LinuxPaths(environment: environment)
        let now = try #require(
            ISO8601DateFormatter().date(from: "2026-08-09T13:00:00Z")
        )
        let repository = LinuxUsageRepository(
            credentials: LinuxCredentialStore(paths: paths),
            transport: OfflineTransport(),
            cache: SnapshotCache(paths: paths),
            now: { now },
            environment: environment,
            credentialBackend: EmptyCredentialBackend()
        )

        let snapshots = await repository.refresh()
        let claude = try #require(snapshots.first { $0.providerID == "claude" })

        #expect(claude.metrics.contains { $0.label == "Last 30 Days" })
        #expect(claude.metrics.contains { $0.kind == .chart && $0.label == "Usage Trend" })
    }
}

private struct OfflineTransport: HTTPTransport {
    func execute(_ request: URLRequest) async throws -> HTTPResult {
        HTTPResult(data: Data(), statusCode: 503)
    }
}

private struct EmptyCredentialBackend: LinuxCredentialBackend {
    func load(for key: LinuxCredentialKey) throws -> Data? { nil }
    func store(_ secret: Data, for key: LinuxCredentialKey) throws {}
    func remove(_ key: LinuxCredentialKey) throws {}
}
