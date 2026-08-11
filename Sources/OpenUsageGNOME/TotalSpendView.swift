import Adwaita
import Foundation
import OpenUsageLinuxCore

@MainActor
final class TotalSpendView {
    let root = PreferencesGroup(
        title: "Total Spend",
        description: "Provider share for the selected period and metric."
    )

    private let periodRow = ComboRow(title: "Spend Period")
    private let metricRow = ComboRow(title: "Spend Metric")
    private let drawingArea = DrawingArea()
    private let ringOverlay = Overlay()
    private let centerValue = Label("")
    private let centerCaption = Label("")
    private let ringLabel = Label("")
    private let legend = Box(
        orientation: GTK_ORIENTATION_VERTICAL,
        spacing: GNOMEStyle.rowSpacing
    )
    private var records: [ProviderSpendRecord] = []
    private var connections: [SignalConnection] = []
    private var currentProjection: TotalSpendProjection?
    private var onShare: (BrandedShareCard) -> Void = { _ in }

    init() {
        periodRow.setModel(StringList(TotalSpendPeriod.allCases.map(\.label)))
        periodRow.selected = 0
        metricRow.setModel(StringList(TotalSpendMetric.allCases.map(\.label)))
        metricRow.selected = 0
        root.add(periodRow)
        root.add(metricRow)

        drawingArea.setSizeRequest(width: 220, height: 220)
        drawingArea.halign = GTK_ALIGN_CENTER
        ringOverlay.child = drawingArea
        let center = Box(
            orientation: GTK_ORIENTATION_VERTICAL,
            spacing: GNOMEStyle.rowSpacing
        )
        center.halign = GTK_ALIGN_CENTER
        center.valign = GTK_ALIGN_CENTER
        centerValue.addCSSClass(.title1)
        centerValue.addCSSClass(.numeric)
        centerCaption.addCSSClass(.caption)
        centerCaption.addCSSClass(.dimLabel)
        center.append(centerValue)
        center.append(centerCaption)
        ringOverlay.addOverlay(center)
        root.add(ringOverlay)
        ringLabel.halign = GTK_ALIGN_CENTER
        ringLabel.addCSSClass(.caption)
        ringLabel.addCSSClass(.dimLabel)
        root.add(ringLabel)
        root.add(legend)
        let shareButton = Button(label: "Share PNG", onClicked: { [weak self] in
            self?.shareCurrent()
        })
        shareButton.addCSSClass(.suggestedAction)
        shareButton.addCSSClass(.pill)
        shareButton.halign = GTK_ALIGN_CENTER
        shareButton.setAccessibleLabel("Export and open branded share PNG")
        root.add(shareButton)

        connections.append(periodRow.onNotify(.selected) { [weak self] in
            self?.render()
        })
        connections.append(metricRow.onNotify(.selected) { [weak self] in
            self?.render()
        })
    }

    func update(snapshots: [ProviderUsageSnapshot]) {
        records = TotalSpendAnalytics.records(from: snapshots)
        root.visible = !records.isEmpty
        render()
    }

    func setShareHandler(
        _ handler: @escaping @MainActor (BrandedShareCard) -> Void
    ) {
        onShare = handler
    }

    func shareCurrent() {
        guard let currentProjection else { return }
        onShare(BrandedShareCard(
            projection: currentProjection,
            generatedAt: Date()
        ))
    }

    func selectMetric(_ metric: TotalSpendMetric) {
        switch metric {
        case .cost:
            metricRow.selected = 0
        case .costPerMillionTokens:
            metricRow.selected = 1
        case .tokens:
            metricRow.selected = 2
        }
    }

    private func render() {
        let period = TotalSpendPeriod.allCases[
            min(max(periodRow.selected, 0), TotalSpendPeriod.allCases.count - 1)
        ]
        let metric = TotalSpendMetric.allCases[
            min(max(metricRow.selected, 0), TotalSpendMetric.allCases.count - 1)
        ]
        let projection = TotalSpendAnalytics.project(
            records: records,
            metric: metric,
            period: period
        )
        currentProjection = projection.slices.isEmpty ? nil : projection
        centerValue.text = format(projection.total, metric: metric)
        centerCaption.text = metric.label
        ringLabel.text = "\(metric.label) provider share ring"
        ringLabel.setAccessibleDescription(accessibilityDescription(projection))
        drawingArea.setAccessibleLabel("Total Spend \(metric.label) ring")
        drawingArea.setAccessibleDescription(accessibilityDescription(projection))
        ringOverlay.setAccessibleLabel("Total Spend \(metric.label) ring")
        ringOverlay.setAccessibleDescription(accessibilityDescription(projection))
        drawingArea.setDrawFunc { context, width, height in
            Self.draw(
                context: context,
                projection: projection,
                width: Double(width),
                height: Double(height)
            )
        }
        drawingArea.queueDraw()
        rebuildLegend(projection)
    }

    private func rebuildLegend(_ projection: TotalSpendProjection) {
        while let child = legend.firstChild {
            legend.remove(child)
        }
        if projection.slices.isEmpty {
            let empty = Label("No spend recorded for this period.")
            empty.xalign = 0
            empty.addCSSClass(.dimLabel)
            legend.append(empty)
            return
        }
        for slice in projection.slices {
            let row = Box(
                orientation: GTK_ORIENTATION_HORIZONTAL,
                spacing: GNOMEStyle.controlSpacing
            )
            let name = Label(slice.label)
            name.xalign = 0
            name.hexpand = true
            row.append(name)
            let value = Label(
                "\(format(slice.value, metric: projection.metric)) · \(slice.wholePercent)%"
            )
            value.addCSSClass(.numeric)
            row.append(value)
            row.setAccessibleLabel("\(slice.label) \(slice.wholePercent)%")
            legend.append(row)
        }
    }

    private func accessibilityDescription(
        _ projection: TotalSpendProjection
    ) -> String {
        let slices = projection.slices.map {
            "\($0.label) \($0.wholePercent)%"
        }.joined(separator: ", ")
        if slices.isEmpty {
            return "No spend recorded for \(projection.period.label)."
        }
        return "\(format(projection.total, metric: projection.metric)) total. \(slices)."
    }

    private func format(_ value: Double, metric: TotalSpendMetric) -> String {
        switch metric {
        case .cost:
            GNOMEFormat.currency(value)
        case .costPerMillionTokens:
            "\(GNOMEFormat.currency(value)) / MTok"
        case .tokens:
            GNOMEFormat.tokens(value)
        }
    }

    private static func draw(
        context: CairoContext,
        projection: TotalSpendProjection,
        width: Double,
        height: Double
    ) {
        guard width > 20, height > 20 else { return }
        let palette = [
            (0.93, 0.27, 0.18),
            (0.96, 0.62, 0.12),
            (0.20, 0.55, 0.86),
            (0.45, 0.36, 0.78),
            (0.20, 0.65, 0.47),
            (0.80, 0.34, 0.60),
        ]
        let centerX = width / 2
        let centerY = height / 2
        let radius = min(width, height) * 0.34
        let lineWidth = min(width, height) * 0.13

        context.setLineWidth(lineWidth)
        context.setSourceRGBA(0.5, 0.5, 0.5, 0.18)
        context.arc(
            centerX: centerX,
            centerY: centerY,
            radius: radius,
            startAngle: 0,
            endAngle: 2 * Double.pi
        )
        context.stroke()

        var angle = -Double.pi / 2
        for (index, slice) in projection.slices.enumerated() {
            let end = angle + slice.share * 2 * Double.pi
            let color = palette[index % palette.count]
            context.setSourceRGBA(color.0, color.1, color.2, 1)
            context.arc(
                centerX: centerX,
                centerY: centerY,
                radius: radius,
                startAngle: angle,
                endAngle: end
            )
            context.stroke()
            angle = end
        }
    }
}
