import Adwaita
import Foundation
import OpenUsageLinuxCore

struct UsageTrendPresentation: Equatable, Sendable {
    static let maximumPoints = 31

    let points: [UsagePoint]
    let total: Double
    let average: Double
    let peak: UsagePoint?
    let scaleMaximum: Double
    let gridValues: [Double]

    init(points: [UsagePoint]) {
        let bounded = Array(points.suffix(Self.maximumPoints))
        self.points = bounded
        total = bounded.reduce(0) { $0 + max($1.value, 0) }
        average = bounded.isEmpty ? 0 : total / Double(bounded.count)
        peak = bounded.max { $0.value < $1.value }
        scaleMaximum = Self.niceMaximum(peak?.value ?? 0)
        gridValues = [0, scaleMaximum / 2, scaleMaximum]
    }

    private static func niceMaximum(_ value: Double) -> Double {
        guard value > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(value)))
        let normalized = value / magnitude
        let nice: Double
        switch normalized {
        case ...1:
            nice = 1
        case ...2:
            nice = 2
        case ...4:
            nice = 4
        case ...5:
            nice = 5
        default:
            nice = 10
        }
        return nice * magnitude
    }
}

enum TotalSpendPresentationMode: Equatable, Sendable {
    case empty
    case singleProvider
    case providerComparison

    init(sliceCount: Int) {
        switch sliceCount {
        case ...0:
            self = .empty
        case 1:
            self = .singleProvider
        default:
            self = .providerComparison
        }
    }
}

/// One Cairo drawing area per chart (efficiency contract: never one widget
/// per point). Renders up to 31 daily values as accent bars over a baseline
/// track, in light, dark, and high-contrast appearances.
///
/// The draw closure captures the points by value, so the chart keeps
/// rendering even after this Swift wrapper is released — GTK owns the area.
@MainActor
struct ChartView {
    static let maximumPoints = UsageTrendPresentation.maximumPoints
    static let height = 164

    let widget: DrawingArea

    init(points: [UsagePoint], providerName: String, unitLabel: String) {
        widget = DrawingArea()
        widget.setSizeRequest(height: Self.height)
        widget.vexpand = false
        widget.hexpand = true

        let presentation = UsageTrendPresentation(points: points)
        let bounded = presentation.points
        widget.setAccessibleLabel("\(providerName) daily usage chart")
        widget.setAccessibleDescription(
            Self.tabularDescription(points: bounded, providerName: providerName, unitLabel: unitLabel)
        )
        widget.setDrawFunc { context, width, height in
            Self.draw(context: context, presentation: presentation,
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

    private static func draw(context: CairoContext, presentation: UsageTrendPresentation,
                             width: Double, height: Double) {
        guard width > 48, height > 48 else { return }
        let style = StyleManager.default
        let palette = GNOMEStyle.chartPalette(dark: style.dark, highContrast: style.highContrast)
        let points = presentation.points
        let leftInset = 12.0
        let rightInset = 8.0
        let topInset = 10.0
        let bottomInset = 18.0
        let plotWidth = width - leftInset - rightInset
        let plotHeight = height - topInset - bottomInset

        for gridValue in presentation.gridValues {
            let fraction = gridValue / presentation.scaleMaximum
            let y = topInset + plotHeight * (1 - fraction)
            context.setSourceRGBA(
                palette.accentRed,
                palette.accentGreen,
                palette.accentBlue,
                gridValue == 0 ? palette.trackAlpha * 1.8 : palette.trackAlpha
            )
            context.setLineWidth(1)
            context.moveTo(x: leftInset, y: y + 0.5)
            context.lineTo(x: width - rightInset, y: y + 0.5)
            context.stroke()
        }

        guard !points.isEmpty else { return }
        guard presentation.scaleMaximum > 0 else { return }

        let count = Double(points.count)
        let slot = plotWidth / count
        let barWidth = min(max(slot * 0.58, 2), 12)

        for (index, point) in points.enumerated() {
            let fraction = min(max(point.value / presentation.scaleMaximum, 0), 1)
            let barHeight = max(fraction * plotHeight, fraction > 0 ? 2 : 0)
            guard barHeight > 0 else { continue }
            let x = leftInset + slot * (Double(index) + 0.5) - barWidth / 2
            let y = topInset + plotHeight - barHeight
            let isLatest = index == points.indices.last
            context.setSourceRGBA(
                palette.accentRed,
                palette.accentGreen,
                palette.accentBlue,
                isLatest ? 1 : 0.68
            )
            context.roundedRectangle(x: x, y: y, width: barWidth, height: barHeight,
                                     radius: min(barWidth / 2, 4))
            context.fill()
        }

        let averageFraction = min(max(presentation.average / presentation.scaleMaximum, 0), 1)
        let averageY = (topInset + plotHeight * (1 - averageFraction)).rounded() + 0.5
        context.setSourceRGBA(
            palette.accentRed,
            palette.accentGreen,
            palette.accentBlue,
            0.82
        )
        context.setLineWidth(1)
        var dashX = leftInset
        while dashX < width - rightInset {
            context.moveTo(x: dashX, y: averageY)
            context.lineTo(x: min(dashX + 4, width - rightInset), y: averageY)
            dashX += 8
        }
        context.stroke()
    }
}
