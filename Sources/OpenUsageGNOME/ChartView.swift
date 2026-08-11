import Adwaita
import Foundation
import OpenUsageLinuxCore

/// One Cairo drawing area per chart (efficiency contract: never one widget
/// per point). Renders up to 31 daily values as accent bars over a baseline
/// track, in light, dark, and high-contrast appearances.
///
/// The draw closure captures the points by value, so the chart keeps
/// rendering even after this Swift wrapper is released — GTK owns the area.
@MainActor
struct ChartView {
    static let maximumPoints = 31
    static let height = 120

    let widget: DrawingArea

    init(points: [UsagePoint], providerName: String, unitLabel: String) {
        widget = DrawingArea()
        widget.setSizeRequest(height: Self.height)
        widget.vexpand = false
        widget.hexpand = true

        let bounded = Array(points.suffix(Self.maximumPoints))
        widget.setAccessibleLabel("\(providerName) daily usage chart")
        widget.setAccessibleDescription(
            Self.tabularDescription(points: bounded, providerName: providerName, unitLabel: unitLabel)
        )
        widget.setDrawFunc { context, width, height in
            Self.draw(context: context, points: bounded,
                      width: Double(width), height: Double(height))
        }
    }

    private static func tabularDescription(
        points: [UsagePoint], providerName: String, unitLabel: String
    ) -> String {
        guard let first = points.first, let last = points.last else {
            return "No daily usage recorded for \(providerName)."
        }
        let total = points.reduce(0) { $0 + $1.value }
        let peak = points.max { $0.value < $1.value }
        var description = "\(points.count) daily points from "
            + "\(GNOMEFormat.shortDay(first.date)) to \(GNOMEFormat.shortDay(last.date)). "
            + "Total \(GNOMEFormat.tokens(total)) \(unitLabel)."
        if let peak, peak.value > 0 {
            description += " Peak \(GNOMEFormat.tokens(peak.value)) \(unitLabel) on "
                + "\(GNOMEFormat.shortDay(peak.date))."
        }
        return description
    }

    private static func draw(context: CairoContext, points: [UsagePoint],
                             width: Double, height: Double) {
        guard width > 8, height > 8 else { return }
        let style = StyleManager.default
        let palette = GNOMEStyle.chartPalette(dark: style.dark, highContrast: style.highContrast)
        let inset = 2.0
        let baselineY = height - inset

        context.setSourceRGBA(palette.accentRed, palette.accentGreen, palette.accentBlue,
                              palette.trackAlpha)
        context.setLineWidth(1)
        context.moveTo(x: inset, y: baselineY - 0.5)
        context.lineTo(x: width - inset, y: baselineY - 0.5)
        context.stroke()

        guard !points.isEmpty else { return }
        let peak = points.map(\.value).max() ?? 0
        guard peak > 0 else { return }

        let usableWidth = width - inset * 2
        let usableHeight = height - inset * 2 - 4
        let count = Double(points.count)
        let slot = usableWidth / count
        let barWidth = max(slot * 0.68, 1.5)

        for (index, point) in points.enumerated() {
            let fraction = min(max(point.value / peak, 0), 1)
            let barHeight = max(fraction * usableHeight, fraction > 0 ? 2 : 0)
            guard barHeight > 0 else { continue }
            let x = inset + slot * (Double(index) + 0.5) - barWidth / 2
            let y = baselineY - barHeight
            context.setSourceRGBA(palette.accentRed, palette.accentGreen, palette.accentBlue, 1)
            context.roundedRectangle(x: x, y: y, width: barWidth, height: barHeight,
                                     radius: min(barWidth / 2, 3))
            context.fill()
        }
    }
}
