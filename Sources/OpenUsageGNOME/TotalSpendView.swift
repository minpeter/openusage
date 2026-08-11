import Adwaita
import Foundation
import OpenUsageLinuxCore

@MainActor
final class TotalSpendView {
    let root = Box(
        orientation: GTK_ORIENTATION_VERTICAL,
        spacing: GNOMEStyle.sectionSpacing
    )

    private let periodButtons = TotalSpendPeriod.allCases.map {
        ToggleButton(label: $0 == .last30Days ? "30 Days" : $0.label)
    }
    private let metricButtons = TotalSpendMetric.allCases.map {
        ToggleButton(label: $0.label)
    }
    private let drawingArea = DrawingArea()
    private let ringOverlay = Overlay()
    private let centerValue = Label("")
    private let centerCaption = Label("")
    private let legend = Box(
        orientation: GTK_ORIENTATION_VERTICAL,
        spacing: GNOMEStyle.controlSpacing
    )
    private var records: [ProviderSpendRecord] = []
    private var connections: [SignalConnection] = []
    private var currentProjection: TotalSpendProjection?
    private var onShare: (BrandedShareCard) -> Void = { _ in }

    init() {
        root.addCSSClass("ou-summary-card")
        let header = Box(
            orientation: GTK_ORIENTATION_VERTICAL,
            spacing: GNOMEStyle.rowSpacing
        )
        let heading = Box(
            orientation: GTK_ORIENTATION_VERTICAL,
            spacing: 2
        )
        heading.hexpand = true
        let title = Label("Total Spend")
        title.xalign = 0
        title.addCSSClass(.title2)
        heading.append(title)
        let subtitle = Label("Compare providers across cost and token usage.")
        subtitle.xalign = 0
        subtitle.wrap = true
        subtitle.addCSSClass(.dimLabel)
        heading.append(subtitle)
        header.append(heading)

        let shareButton = Button(label: "Share PNG", onClicked: { [weak self] in
            self?.shareCurrent()
        })
        shareButton.addCSSClass(.pill)
        shareButton.halign = GTK_ALIGN_START
        shareButton.setAccessibleLabel("Export and open branded share PNG")
        header.append(shareButton)
        root.append(header)

        let selectors = Box(
            orientation: GTK_ORIENTATION_VERTICAL,
            spacing: GNOMEStyle.rowSpacing
        )
        selectors.append(Self.segmentedSelector(
            title: "Period",
            buttons: periodButtons,
            connections: &connections,
            onChange: { [weak self] in self?.render() }
        ))
        selectors.append(Self.segmentedSelector(
            title: "Metric",
            buttons: metricButtons,
            connections: &connections,
            onChange: { [weak self] in self?.render() }
        ))
        root.append(selectors)

        drawingArea.setSizeRequest(width: 160, height: 160)
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
        root.append(ringOverlay)
        root.append(legend)
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
        guard let index = TotalSpendMetric.allCases.firstIndex(of: metric) else {
            return
        }
        metricButtons[index].active = true
    }

    private func render() {
        let periodIndex = periodButtons.firstIndex { $0.active } ?? 0
        let metricIndex = metricButtons.firstIndex { $0.active } ?? 0
        let period = TotalSpendPeriod.allCases[periodIndex]
        let metric = TotalSpendMetric.allCases[metricIndex]
        let projection = TotalSpendAnalytics.project(
            records: records,
            metric: metric,
            period: period
        )
        currentProjection = projection.slices.isEmpty ? nil : projection
        centerValue.text = format(projection.total, metric: metric)
        centerCaption.text = metric.label
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

    private static func segmentedSelector(
        title: String,
        buttons: [ToggleButton],
        connections: inout [SignalConnection],
        onChange: @escaping @MainActor () -> Void
    ) -> Widget {
        let row = Box(
            orientation: GTK_ORIENTATION_VERTICAL,
            spacing: GNOMEStyle.rowSpacing
        )
        let label = Label(title)
        label.xalign = 0
        label.addCSSClass(.caption)
        label.addCSSClass(.dimLabel)
        row.append(label)

        let control = Box(
            orientation: GTK_ORIENTATION_HORIZONTAL,
            spacing: 0
        )
        control.addCSSClass(.linked)
        for (index, button) in buttons.enumerated() {
            if index > 0 {
                button.setGroup(buttons[0])
            }
            button.active = index == 0
            button.hexpand = true
            button.setSizeRequest(height: GNOMEStyle.minimumTargetHeight)
            connections.append(button.onToggled { [weak button] in
                guard button?.active == true else { return }
                onChange()
            })
            control.append(button)
        }
        row.append(control)
        return row
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
                orientation: GTK_ORIENTATION_VERTICAL,
                spacing: 2
            )
            row.addCSSClass("ou-legend-row")
            let name = Label(slice.label)
            name.xalign = 0
            name.hexpand = true
            name.wrap = true
            name.maxWidthChars = 24
            row.append(name)
            let value = Label(
                "\(format(slice.value, metric: projection.metric)) · \(slice.wholePercent)%"
            )
            value.addCSSClass(.numeric)
            value.xalign = 0
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
        let style = StyleManager.default
        let theme = GNOMEStyle.chartPalette(
            dark: style.dark,
            highContrast: style.highContrast
        )
        let palette = [
            (theme.accentRed, theme.accentGreen, theme.accentBlue),
            (0.42, 0.36, 0.78),
            (0.16, 0.64, 0.52),
            (0.91, 0.49, 0.16),
            (0.78, 0.35, 0.58),
            (0.25, 0.62, 0.74),
        ]
        let centerX = width / 2
        let centerY = height / 2
        let radius = min(width, height) * 0.34
        let lineWidth = min(width, height) * 0.13

        context.setLineWidth(lineWidth)
        context.setSourceRGBA(0.5, 0.5, 0.5, theme.trackAlpha)
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
