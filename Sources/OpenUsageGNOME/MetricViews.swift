import Adwaita
import Foundation
import OpenUsageLinuxCore

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

        if let caption = secondaryCopy(metric, presentation: presentation) {
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

        if let caption = secondaryCopy(metric, presentation: presentation) {
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

        let parts = (metric.values ?? []).map(formatValue(_:))
        let primary = Label(parts.isEmpty ? primaryValue(metric) : parts.joined(separator: " · "))
        primary.xalign = 1
        primary.wrap = true
        primary.justify = GTK_JUSTIFY_RIGHT
        primary.addCSSClass(.heading)
        primary.addCSSClass(.numeric)
        heading.append(primary)
        box.append(heading)

        if let caption = secondaryCopy(metric, presentation: presentation) {
            box.append(captionLabel(caption))
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
        pill.addCSSClass(badgeClass(for: text))
        pill.valign = GTK_ALIGN_CENTER
        row.append(pill)
        return row
    }

    private static func badgeClass(for text: String) -> CSSClass {
        let lowered = text.lowercased()
        if lowered.contains("error") || lowered.contains("down") || lowered.contains("fail") {
            return .error
        }
        if lowered.contains("limit") || lowered.contains("warn") || lowered.contains("degraded") {
            return .warning
        }
        return .success
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

        if let caption = secondaryCopy(metric, presentation: presentation) {
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

    private static func primaryValue(
        _ metric: UsageMetric,
        presentation: GNOMEMetricPresentation? = nil
    ) -> String {
        if metric.kind == .progress {
            return presentation?.valueText ?? GNOMEFormat.percent(metric.used)
        }
        return GNOMEFormat.currency(metric.used)
    }

    private static func secondaryCopy(
        _ metric: UsageMetric,
        presentation: GNOMEMetricPresentation
    ) -> String? {
        let expiry = metric.expiriesAt?.first.map { "Credits expire \(GNOMEFormat.shortDay($0))" }
        return [metric.detail, presentation.resetText, presentation.pacingText, expiry]
            .compactMap { $0 }
            .joined(separator: " · ")
            .nilIfEmpty
    }

    private static func formatValue(_ value: UsageValue) -> String {
        let number = value.label.isEmpty ? "" : "\(value.label) "
        switch value.unit {
        case .dollars:
            return number + GNOMEFormat.currency(value.value)
        case .tokens, .count:
            // Avoid "tokens 1,234 tokens" when the label already names the unit.
            let label = value.label.lowercased() == "tokens" ? "" : number
            let suffix = value.unit == .tokens ? " tokens" : ""
            return label + GNOMEFormat.tokens(value.value) + suffix
        case .credits:
            return GNOMEFormat.tokens(value.value) + " credits"
        case .percent:
            return "\(Int(value.value.rounded()))%"
        }
    }
}
