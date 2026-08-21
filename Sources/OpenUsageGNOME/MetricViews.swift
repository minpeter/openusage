import Adwaita
import Foundation
import OpenUsageLinuxCore

struct GNOMEModelBreakdown: Equatable, Sendable {
    struct Item: Equatable, Sendable {
        let label: String
        let value: Double
        let unit: UsageValue.Unit
        let share: Double
        let wholePercent: Int
    }

    let items: [Item]
    let total: Double

    init(values: [UsageValue]) {
        let valid = values.enumerated().filter {
            $0.element.value.isFinite && $0.element.value > 0
        }
        guard let unit = valid.first?.element.unit else {
            items = []
            total = 0
            return
        }
        let matching = valid.filter { $0.element.unit == unit }
        let totalValue = matching.reduce(0) { $0 + $1.element.value }
        total = totalValue
        items = matching.sorted {
            if $0.element.value == $1.element.value {
                return $0.offset < $1.offset
            }
            return $0.element.value > $1.element.value
        }.map {
            let share = $0.element.value / totalValue
            return Item(
                label: $0.element.label,
                value: $0.element.value,
                unit: $0.element.unit,
                share: share,
                wholePercent: Int((share * 100).rounded())
            )
        }
    }

    var accessibilityDescription: String {
        items.map { "\($0.label) \($0.wholePercent)%" }.joined(separator: ", ")
    }
}

/// Renders every UsageMetric shape the core can produce (progress, value,
/// values, badge, chart, text) as native GNOME rows. All renderers are pure
/// functions of the metric so views can rebuild a metric cluster in one call.
@MainActor
enum MetricViews {

    static func widget(
        for metric: UsageMetric,
        providerName: String,
        metricPresentationSettings: GNOMEMetricPresentationSettings
    ) -> Widget {
        let presentation = metricPresentationSettings.presentation(for: metric)
        switch metric.kind {
        case .progress:
            return progress(metric, presentation: presentation)
        case .value:
            return value(metric, presentation: presentation)
        case .values:
            return values(metric, presentation: presentation)
        case .badge:
            return badge(metric)
        case .chart:
            guard GNOMEValuesCopy.shouldDisplay(metric) else {
                return Box(orientation: GTK_ORIENTATION_VERTICAL, spacing: 0)
            }
            return chart(metric, providerName: providerName, presentation: presentation)
        case .text:
            return text(metric)
        }
    }

    // MARK: - Progress: label, trailing percentage, bar, reset copy

    private static func progress(
        _ metric: UsageMetric,
        presentation: GNOMEMetricPresentation
    ) -> Widget {
        let box = Box(orientation: GTK_ORIENTATION_VERTICAL, spacing: GNOMEStyle.rowSpacing)
        let heading = Box(orientation: GTK_ORIENTATION_HORIZONTAL, spacing: GNOMEStyle.controlSpacing)

        let label = Label(metric.label)
        label.xalign = 0
        label.hexpand = true
        label.wrap = true
        label.addCSSClass(.heading)
        heading.append(label)

        let primary = primaryValue(metric, presentation: presentation)
        let value = Label(primary)
        value.xalign = 1
        value.wrap = true
        value.justify = GTK_JUSTIFY_RIGHT
        value.addCSSClass(.numeric)
        heading.append(value)
        box.append(heading)

        if let fraction = metric.fraction {
            let bar = ProgressBar()
            bar.fraction = fraction
            bar.setAccessibleLabel(metric.label)
            bar.setAccessibleDescription(primary)
            box.append(bar)
        }

        if let caption = GNOMEValuesCopy.caption(for: metric, presentation: presentation) {
            box.append(captionLabel(caption))
        }
        return box
    }

    // MARK: - Value / values: title, primary value, optional detail

    private static func value(
        _ metric: UsageMetric,
        presentation: GNOMEMetricPresentation
    ) -> Widget {
        let box = Box(orientation: GTK_ORIENTATION_VERTICAL, spacing: GNOMEStyle.rowSpacing)
        let heading = Box(orientation: GTK_ORIENTATION_HORIZONTAL, spacing: GNOMEStyle.controlSpacing)

        let label = Label(metric.label)
        label.xalign = 0
        label.hexpand = true
        label.wrap = true
        heading.append(label)

        let valueLabel = Label(primaryValue(metric))
        valueLabel.xalign = 1
        valueLabel.addCSSClass(.heading)
        valueLabel.addCSSClass(.numeric)
        heading.append(valueLabel)
        box.append(heading)

        if let caption = GNOMEValuesCopy.caption(for: metric, presentation: presentation) {
            box.append(captionLabel(caption))
        }
        return box
    }

    private static func values(
        _ metric: UsageMetric,
        presentation: GNOMEMetricPresentation
    ) -> Widget {
        let box = Box(orientation: GTK_ORIENTATION_VERTICAL, spacing: GNOMEStyle.rowSpacing)
        let heading = Box(orientation: GTK_ORIENTATION_HORIZONTAL, spacing: GNOMEStyle.controlSpacing)

        let label = Label(metric.label)
        label.xalign = 0
        label.hexpand = true
        label.wrap = true
        heading.append(label)

        let primary = Label(GNOMEValuesCopy.primary(for: metric))
        primary.xalign = 1
        primary.wrap = true
        primary.justify = GTK_JUSTIFY_RIGHT
        primary.addCSSClass(.heading)
        primary.addCSSClass(.numeric)
        heading.append(primary)
        box.append(heading)

        if let caption = GNOMEValuesCopy.caption(for: metric, presentation: presentation) {
            box.append(captionLabel(caption))
        }
        let breakdown = GNOMEModelBreakdown(values: metric.values ?? [])
        if breakdown.items.count > 1 {
            box.append(modelBreakdownButton(metric: metric, breakdown: breakdown))
        }
        return box
    }

    // MARK: - Badge: semantic pill, never color alone

    private static func badge(_ metric: UsageMetric) -> Widget {
        let row = Box(orientation: GTK_ORIENTATION_HORIZONTAL, spacing: GNOMEStyle.controlSpacing)
        row.setSizeRequest(height: GNOMEStyle.minimumTargetHeight)

        let label = Label(metric.label)
        label.xalign = 0
        label.hexpand = true
        row.append(label)

        let text = metric.text ?? primaryValue(metric)
        let pill = Label(text)
        pill.addCSSClass("ou-pill")
        pill.addCSSClass(GNOMEBadgeStyle.semanticClass(for: text))
        pill.valign = GTK_ALIGN_CENTER
        row.append(pill)
        return row
    }

    // MARK: - Chart: single Cairo area with accessible tabular copy

    private static func chart(
        _ metric: UsageMetric,
        providerName: String,
        presentation: GNOMEMetricPresentation
    ) -> Widget {
        let box = Box(orientation: GTK_ORIENTATION_VERTICAL, spacing: GNOMEStyle.rowSpacing)
        let label = Label(metric.label)
        label.xalign = 0
        label.addCSSClass(.heading)
        box.append(label)

        let chart = ChartView(points: metric.points ?? [], providerName: providerName,
                              unitLabel: "tokens")
        box.append(chart.widget)

        let points = Array((metric.points ?? []).suffix(ChartView.maximumPoints))
        if !points.isEmpty {
            let values = ExpanderRow(title: "Daily Values")
            values.subtitle = "Every chart point as text, newest first"
            for point in points.reversed() {
                let row = ActionRow(title: GNOMEFormat.shortDay(point.date))
                let value = Label("\(GNOMEFormat.tokens(point.value)) tokens")
                value.addCSSClass(.numeric)
                value.valign = GTK_ALIGN_CENTER
                row.addSuffix(value)
                values.addRow(row)
            }
            box.append(values)
        }

        if let caption = GNOMEValuesCopy.caption(for: metric, presentation: presentation) {
            box.append(captionLabel(caption))
        }
        return box
    }

    // MARK: - Text: wrapped explanatory copy

    private static func text(_ metric: UsageMetric) -> Widget {
        let box = Box(orientation: GTK_ORIENTATION_VERTICAL, spacing: GNOMEStyle.rowSpacing)
        let label = Label(metric.label)
        label.xalign = 0
        label.addCSSClass(.heading)
        box.append(label)
        box.append(captionLabel(metric.text ?? ""))
        return box
    }

    // MARK: - Shared formatting

    private static func captionLabel(_ text: String) -> Label {
        let caption = Label(text)
        caption.xalign = 0
        caption.wrap = true
        caption.addCSSClass(.caption)
        caption.addCSSClass(.dimLabel)
        return caption
    }

    private static func modelBreakdownButton(
        metric: UsageMetric,
        breakdown: GNOMEModelBreakdown
    ) -> Widget {
        let content = Box(
            orientation: GTK_ORIENTATION_VERTICAL,
            spacing: GNOMEStyle.rowSpacing
        )
        content.setMargins(GNOMEStyle.sectionSpacing)
        let heading = Label("Model Breakdown")
        heading.xalign = 0
        heading.addCSSClass(.heading)
        content.append(heading)

        for item in breakdown.items {
            let row = Box(
                orientation: GTK_ORIENTATION_HORIZONTAL,
                spacing: GNOMEStyle.controlSpacing
            )
            let name = Label(item.label)
            name.xalign = 0
            name.hexpand = true
            row.append(name)
            let value = Label("\(item.wholePercent)%")
            value.addCSSClass(.numeric)
            row.append(value)
            content.append(row)

            let bar = ProgressBar()
            bar.fraction = item.share
            bar.setAccessibleLabel("\(item.label) share")
            bar.setAccessibleDescription("\(item.wholePercent)% of \(metric.label)")
            content.append(bar)
        }

        let popover = Popover()
        popover.child = content
        let button = MenuButton(label: "Model Details")
        button.addCSSClass(.flat)
        button.setPopover(popover)
        button.setAccessibleLabel("Show \(metric.label) model breakdown")
        button.setAccessibleDescription(breakdown.accessibilityDescription)
        return button
    }

    private static func primaryValue(
        _ metric: UsageMetric,
        presentation: GNOMEMetricPresentation? = nil
    ) -> String {
        if metric.kind == .progress {
            return presentation?.valueText ?? GNOMEFormat.percent(metric.used)
        }
        return GNOMEFormat.currency(metric.used)
    }

}
