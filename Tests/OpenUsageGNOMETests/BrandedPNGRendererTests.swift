import Foundation
import OpenUsageLinuxCore
import Testing
@testable import OpenUsageGNOME

@Suite("Branded PNG sharing")
struct BrandedPNGRendererTests {
    @Test("Card copy is deterministic from the spend projection")
    func cardCopy() {
        let card = BrandedShareCard(
            projection: projection(),
            generatedAt: Date(timeIntervalSince1970: 1_786_579_200)
        )

        #expect(card.brand == "OpenUsage")
        #expect(card.title == "Total Spend")
        #expect(card.total == "$14.00")
        #expect(card.subtitle == "30 Days · Cost")
        #expect(card.entries.map(\.label) == ["Claude", "Codex"])
        #expect(card.entries.map(\.value) == ["$10.00", "$4.00"])
        #expect(card.entries.map(\.wholePercent) == [71, 29])
    }

    @Test("Renderer emits a valid PNG with requested dimensions")
    func pngSignatureAndDimensions() throws {
        let data = try BrandedPNGRenderer.render(
            BrandedShareCard(
                projection: projection(),
                generatedAt: Date(timeIntervalSince1970: 1_786_579_200)
            ),
            width: 1_200,
            height: 675
        )

        #expect(Array(data.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(pngDimension(data, offset: 16) == 1_200)
        #expect(pngDimension(data, offset: 20) == 675)
        #expect(data.count > 1_000)
    }

    @Test("Renderer rejects unusable dimensions")
    func invalidDimensions() {
        #expect(throws: BrandedPNGRendererError.invalidDimensions) {
            try BrandedPNGRenderer.render(
                BrandedShareCard(
                    projection: projection(),
                    generatedAt: Date(timeIntervalSince1970: 0)
                ),
                width: 100,
                height: 100
            )
        }
    }

    @Test("Exporter preserves existing shares with collision-safe names")
    func collisionSafeExport() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let card = BrandedShareCard(
            projection: projection(),
            generatedAt: Date(timeIntervalSince1970: 1_786_579_200)
        )

        let first = try BrandedPNGExportService.export(card: card, to: directory)
        let second = try BrandedPNGExportService.export(card: card, to: directory)

        #expect(first.lastPathComponent == "openusage-share.png")
        #expect(second.lastPathComponent == "openusage-share-2.png")
        #expect(try Data(contentsOf: first).starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(try Data(contentsOf: second).starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    private func projection() -> TotalSpendProjection {
        TotalSpendProjection(
            metric: .cost,
            period: .thirtyDays,
            total: 14,
            slices: [
                .init(
                    providerID: "claude",
                    label: "Claude",
                    value: 10,
                    share: 10.0 / 14.0,
                    wholePercent: 71
                ),
                .init(
                    providerID: "codex",
                    label: "Codex",
                    value: 4,
                    share: 4.0 / 14.0,
                    wholePercent: 29
                ),
            ]
        )
    }

    private func pngDimension(_ data: Data, offset: Int) -> Int {
        data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
    }
}
