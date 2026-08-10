import CAdwaita
import Foundation
import OpenUsageLinuxCore

struct BrandedShareCard: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let label: String
        let value: String
        let share: Double
        let wholePercent: Int
    }

    let brand: String
    let title: String
    let total: String
    let subtitle: String
    let entries: [Entry]
    let footer: String

    init(projection: TotalSpendProjection, generatedAt: Date) {
        brand = "OpenUsage"
        title = "Total Spend"
        total = Self.format(projection.total, metric: projection.metric)
        subtitle = "\(projection.period.label) · \(projection.metric.label)"
        entries = projection.slices.map {
            Entry(
                label: $0.label,
                value: Self.format($0.value, metric: projection.metric),
                share: $0.share,
                wholePercent: $0.wholePercent
            )
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        footer = "Generated \(formatter.string(from: generatedAt))"
    }

    private static func format(
        _ value: Double,
        metric: TotalSpendMetric
    ) -> String {
        switch metric {
        case .cost:
            return String(format: "$%.2f", value)
        case .costPerMillionTokens:
            return String(format: "$%.2f / MTok", value)
        case .tokens:
            if value >= 1_000_000 {
                return String(format: "%.2fM", value / 1_000_000)
            }
            if value >= 1_000 {
                return String(format: "%.1fK", value / 1_000)
            }
            return String(format: "%.0f", value)
        }
    }
}

enum BrandedPNGRendererError: Error, Equatable {
    case invalidDimensions
    case cairoFailure
    case writeFailure
}

enum BrandedPNGRenderer {
    static func render(
        _ card: BrandedShareCard,
        width: Int = 1_200,
        height: Int = 675
    ) throws -> Data {
        guard (320...4_096).contains(width),
              (180...4_096).contains(height)
        else {
            throw BrandedPNGRendererError.invalidDimensions
        }
        guard let surface = cairo_image_surface_create(
            CAIRO_FORMAT_ARGB32,
            Int32(width),
            Int32(height)
        ) else {
            throw BrandedPNGRendererError.cairoFailure
        }
        defer { cairo_surface_destroy(surface) }
        let surfaceStatus = cairo_surface_status(surface)
        guard surfaceStatus == CAIRO_STATUS_SUCCESS else {
            throw BrandedPNGRendererError.cairoFailure
        }
        guard let context = cairo_create(surface) else {
            throw BrandedPNGRendererError.cairoFailure
        }
        defer { cairo_destroy(context) }

        cairo_scale(
            context,
            Double(width) / 1_200,
            Double(height) / 675
        )
        draw(card, context: context)
        cairo_surface_flush(surface)

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-share-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let writeStatus = temporaryURL.path.withCString {
            cairo_surface_write_to_png(surface, $0)
        }
        guard writeStatus == CAIRO_STATUS_SUCCESS else {
            throw BrandedPNGRendererError.cairoFailure
        }
        guard let data = try? Data(contentsOf: temporaryURL) else {
            throw BrandedPNGRendererError.writeFailure
        }
        return data
    }

    private static func draw(
        _ card: BrandedShareCard,
        context: OpaquePointer
    ) {
        cairo_set_source_rgb(context, 0.075, 0.075, 0.09)
        cairo_paint(context)
        cairo_set_source_rgb(context, 0.98, 0.35, 0.08)
        cairo_rectangle(context, 0, 0, 1_200, 12)
        cairo_fill(context)

        text(
            card.brand,
            context: context,
            x: 72,
            y: 58,
            font: "Sans Bold 30",
            color: (0.98, 0.35, 0.08)
        )
        text(
            card.title,
            context: context,
            x: 72,
            y: 118,
            font: "Sans Bold 52",
            color: (0.98, 0.98, 0.99)
        )
        text(
            card.subtitle,
            context: context,
            x: 74,
            y: 185,
            font: "Sans 24",
            color: (0.68, 0.68, 0.73)
        )
        text(
            card.total,
            context: context,
            x: 72,
            y: 250,
            font: "Sans Bold 70",
            color: (0.98, 0.98, 0.99)
        )

        drawRing(card.entries, context: context)
        var y = 390.0
        for entry in card.entries.prefix(5) {
            text(
                entry.label,
                context: context,
                x: 72,
                y: y,
                font: "Sans Bold 25",
                color: (0.92, 0.92, 0.95)
            )
            text(
                "\(entry.value) · \(entry.wholePercent)%",
                context: context,
                x: 350,
                y: y,
                font: "Sans 24",
                color: (0.72, 0.72, 0.78)
            )
            y += 48
        }
        text(
            card.footer,
            context: context,
            x: 72,
            y: 620,
            font: "Sans 18",
            color: (0.48, 0.48, 0.54)
        )
        text(
            "openusage.dev",
            context: context,
            x: 935,
            y: 620,
            font: "Sans Bold 18",
            color: (0.48, 0.48, 0.54)
        )
    }

    private static func drawRing(
        _ entries: [BrandedShareCard.Entry],
        context: OpaquePointer
    ) {
        let palette = [
            (0.98, 0.25, 0.12),
            (1.00, 0.62, 0.08),
            (0.22, 0.58, 0.95),
            (0.55, 0.38, 0.88),
            (0.20, 0.72, 0.50),
        ]
        let centerX = 920.0
        let centerY = 288.0
        let radius = 142.0
        cairo_set_line_width(context, 54)
        cairo_set_source_rgba(context, 0.7, 0.7, 0.75, 0.16)
        cairo_arc(context, centerX, centerY, radius, 0, 2 * Double.pi)
        cairo_stroke(context)
        var angle = -Double.pi / 2
        for (index, entry) in entries.enumerated() {
            let end = angle + entry.share * 2 * Double.pi
            let color = palette[index % palette.count]
            cairo_set_source_rgb(context, color.0, color.1, color.2)
            cairo_arc(context, centerX, centerY, radius, angle, end)
            cairo_stroke(context)
            angle = end
        }
    }

    private static func text(
        _ value: String,
        context: OpaquePointer,
        x: Double,
        y: Double,
        font: String,
        color: (Double, Double, Double)
    ) {
        guard let layout = pango_cairo_create_layout(context) else { return }
        defer { g_object_unref(UnsafeMutableRawPointer(layout)) }
        value.withCString { pango_layout_set_text(layout, $0, -1) }
        if let description = font.withCString({ pango_font_description_from_string($0) }) {
            pango_layout_set_font_description(layout, description)
            pango_font_description_free(description)
        }
        cairo_set_source_rgb(context, color.0, color.1, color.2)
        cairo_move_to(context, x, y)
        pango_cairo_show_layout(context, layout)
    }
}

enum BrandedPNGExportService {
    static func export(
        card: BrandedShareCard,
        to directory: URL
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try BrandedPNGRenderer.render(card)
        var suffix = 1
        while true {
            let name = suffix == 1
                ? "openusage-share.png"
                : "openusage-share-\(suffix).png"
            let destination = directory.appendingPathComponent(name)
            do {
                try data.write(to: destination, options: .withoutOverwriting)
                return destination
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                suffix += 1
            }
        }
    }
}
