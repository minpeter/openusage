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
}

private extension JSONDecoder {
    static var openUsage: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
