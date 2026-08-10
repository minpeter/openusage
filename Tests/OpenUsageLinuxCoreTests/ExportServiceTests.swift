import Foundation
import Testing
@testable import OpenUsageLinuxCore

@Suite("Usage export")
struct ExportServiceTests {
    private let snapshots = [
        ProviderUsageSnapshot(
            providerID: "codex",
            instanceID: "codex:work",
            displayName: "Codex",
            accountLabel: "work@example.com",
            plan: "Pro 20x",
            metrics: [
                UsageMetric(kind: .progress, label: "Weekly", used: 42, limit: 100),
                UsageMetric(
                    kind: .values,
                    label: "Today",
                    used: 0,
                    values: [UsageValue(label: "Cost", value: 3.5, unit: .dollars)]
                ),
            ],
            refreshedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    ]

    @Test("JSON export preserves the public snapshot contract")
    func jsonExportPreservesSnapshotContract() throws {
        let data = try UsageExportService().encode(snapshots, format: .json)
        let decoded = try JSONDecoder.openUsage.decode([ProviderUsageSnapshot].self, from: data)

        #expect(decoded == snapshots)
        #expect(String(decoding: data, as: UTF8.self).contains("work@example.com"))
        #expect(!String(decoding: data, as: UTF8.self).contains("access_token"))
        #expect(try UsageExportService().decodeJSON(data) == snapshots)
    }

    @Test("CSV export flattens metrics without losing account identity")
    func csvExportFlattensMetrics() throws {
        let data = try UsageExportService().encode(snapshots, format: .csv)
        let csv = String(decoding: data, as: UTF8.self)

        #expect(csv.contains("provider,instance,account,plan,metric,kind,value,unit,limit,reset"))
        #expect(csv.contains("Codex,codex:work,work@example.com,Pro 20x,Weekly,progress,42"))
        #expect(csv.contains("Codex,codex:work,work@example.com,Pro 20x,Today / Cost,values,3.5,dollars"))
    }

    @Test("Import rejects files above the snapshot budget")
    func importRejectsOversizedFiles() {
        let oversized = Data(repeating: 0, count: 1_048_577)

        #expect(throws: UsageImportError.fileTooLarge(maximumBytes: 1_048_576)) {
            try UsageExportService().decodeJSON(oversized)
        }
    }

    @Test("Configured sync directory round trips exported JSON into the snapshot cache")
    func configuredSyncDirectoryRoundTripsJSON() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = LinuxPaths(environment: [
            "HOME": root.path,
            "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
            "XDG_CACHE_HOME": root.appendingPathComponent("cache").path,
        ])
        let directory = root.appendingPathComponent("shared usage", isDirectory: true)
        let service = UsageDataSyncService(
            cache: SnapshotCache(paths: paths),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let exported = try service.export(
            snapshots,
            format: .json,
            to: directory
        )
        let imported = try service.importSnapshots(from: exported)

        #expect(exported.deletingLastPathComponent() == directory)
        #expect(exported.lastPathComponent == "openusage-1700000000.json")
        #expect(imported == snapshots)
        #expect(try SnapshotCache(paths: paths).load() == snapshots)
    }

    @Test("Malformed import preserves the previous snapshot cache byte for byte")
    func malformedImportPreservesSnapshotCache() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = LinuxPaths(environment: [
            "HOME": root.path,
            "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
            "XDG_CACHE_HOME": root.appendingPathComponent("cache").path,
        ])
        let cache = SnapshotCache(paths: paths)
        try cache.save(snapshots)
        let original = try Data(contentsOf: paths.snapshotCache)
        let malformed = root.appendingPathComponent("malformed.json")
        try Data(#"{"providerID":"truncated""#.utf8).write(to: malformed)

        #expect(throws: (any Error).self) {
            try UsageDataSyncService(cache: cache).importSnapshots(from: malformed)
        }
        #expect(try Data(contentsOf: paths.snapshotCache) == original)
        #expect(try cache.load() == snapshots)
    }

    @Test("Repeated exports never overwrite an existing sync file")
    func repeatedExportsDoNotOverwrite() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = UsageDataSyncService(
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let first = try service.export(snapshots, format: .json, to: root)
        let second = try service.export(snapshots, format: .json, to: root)

        #expect(first.lastPathComponent == "openusage-1700000000.json")
        #expect(second.lastPathComponent == "openusage-1700000000-2.json")
        #expect(try Data(contentsOf: first) == Data(contentsOf: second))
    }
}

private extension JSONDecoder {
    static var openUsage: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
