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
    private let totalValue = Label("")
    private let totalCaption = Label("")
    private let shareButton = Button(icon: .editCopy)
    private let legend = Box(
        orientation: GTK_ORIENTATION_VERTICAL,
        spacing: GNOMEStyle.controlSpacing
    )
    private var records: [ProviderSpendRecord] = []
    private var connections: [SignalConnection] = []
    private var feedbackSource: SourceID?
    private var currentProjection: TotalSpendProjection?
    private var onShare: (BrandedShareCard) -> Void = { _ in }

    init() {
        root.addCSSClass("ou-summary-card")
        let header = Box(
            orientation: GTK_ORIENTATION_HORIZONTAL,
            spacing: GNOMEStyle.rowSpacing
        )
        let heading = Box(
            orientation: GTK_ORIENTATION_VERTICAL,
            spacing: 2
        )
        heading.hexpand = true
        let title = Label("Total Spend")
        title.xalign = 0
        title.addCSSClass(GNOMETypographyRole.cardTitle.cssClass)
        heading.append(title)
        let subtitle = Label("Compare providers across cost and token usage.")
        subtitle.xalign = 0
        subtitle.wrap = true
        subtitle.addCSSClass(.dimLabel)
        heading.append(subtitle)
        header.append(heading)

        shareButton.iconName = TotalSpendShareAction.iconName
        shareButton.addCSSClass(.flat)
        shareButton.halign = GTK_ALIGN_END
        shareButton.valign = GTK_ALIGN_START
        shareButton.setSizeRequest(
            width: GNOMEStyle.minimumTargetHeight,
            height: GNOMEStyle.minimumTargetHeight
        )
        shareButton.tooltipText = "Copy screenshot"
        connections.append(shareButton.onClicked { [weak self] in
            self?.shareCurrent()
        })
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

        let total = Box(
            orientation: GTK_ORIENTATION_VERTICAL,
            spacing: GNOMEStyle.rowSpacing
        )
        total.setMargins(GNOMEStyle.rowSpacing)
        totalValue.xalign = 0
        totalValue.addCSSClass(GNOMETypographyRole.heroValue.cssClass)
        totalValue.addCSSClass(.numeric)
        totalCaption.xalign = 0
        totalCaption.addCSSClass(.caption)
        totalCaption.addCSSClass(.dimLabel)
        total.append(totalValue)
        total.append(totalCaption)
        root.append(total)
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

    func showCopyFeedback() {
        if let feedbackSource {
            _ = MainContext.cancel(sourceId: feedbackSource)
        }
        shareButton.iconName = TotalSpendShareAction.successIconName
        shareButton.addCSSClass("ou-copy-success")
        feedbackSource = MainContext.timeout(every: TotalSpendShareAction.feedbackDuration) {
            [weak self] in
            guard let self else { return false }
            self.shareButton.iconName = TotalSpendShareAction.iconName
            self.shareButton.removeCSSClass("ou-copy-success")
            self.feedbackSource = nil
            return false
        }
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
        shareButton.setAccessibleLabel(
            TotalSpendShareAction.accessibilityLabel(metric: metric)
        )
        let projection = TotalSpendAnalytics.project(
            records: records,
            metric: metric,
            period: period
        )
        currentProjection = projection.slices.isEmpty ? nil : projection
        totalValue.text = format(projection.total, metric: metric)
        let mode = TotalSpendPresentationMode(sliceCount: projection.slices.count)
        totalCaption.text = switch mode {
        case .empty:
            projection.period.label
        case .singleProvider:
            "\(projection.period.label) · \(projection.slices[0].label)"
        case .providerComparison:
            "\(projection.period.label) · \(projection.slices.count) providers"
        }
        totalValue.setAccessibleDescription(accessibilityDescription(projection))
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
                spacing: GNOMEStyle.controlSpacing
            )
            row.addCSSClass("ou-legend-row")
            let labels = Box(
                orientation: GTK_ORIENTATION_HORIZONTAL,
                spacing: GNOMEStyle.controlSpacing
            )
            let name = Label(slice.label)
            name.xalign = 0
            name.hexpand = true
            name.wrap = true
            name.maxWidthChars = 18
            labels.append(name)
            let value = Label(format(slice.value, metric: projection.metric))
            value.addCSSClass(.numeric)
            value.valign = GTK_ALIGN_CENTER
            labels.append(value)
            row.append(labels)
            let bar = ProgressBar()
            bar.setSizeRequest(width: 1)
            bar.fraction = slice.share
            bar.setAccessibleLabel("\(slice.label) spend share")
            bar.setAccessibleDescription("\(slice.wholePercent)%")
            row.append(bar)
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

}
