import Adwaita
import Foundation
import OpenUsageLinuxCore

/// History view: bounded daily charts (at most 31 points, one Cairo area per
/// chart) with a provider/account legend and an accessible tabular copy of
/// every point. Shows an actionable empty state until providers report
/// trend data.
@MainActor
final class HistoryView {
    let root: ScrolledWindow

    let content = Box(orientation: GTK_ORIENTATION_VERTICAL, spacing: GNOMEStyle.sectionSpacing)
    private let emptyPage: StatusPage

    init() {
        root = ScrolledWindow()
        root.setPolicy(horizontal: GTK_POLICY_NEVER, vertical: GTK_POLICY_AUTOMATIC)
        root.kineticScrolling = true

        content.setMargins(GNOMEStyle.outerMargin)
        emptyPage = StatusPage(
            title: "No History Yet",
            description: "Daily trend charts appear here once a provider reports local usage. "
                + "Live quota APIs report current windows only; local scanners supply the "
                + "31-day history.",
            iconName: "document-open-recent-symbolic"
        )

        let clamp = Clamp()
        clamp.maximumSize = GNOMEStyle.contentClamp
        clamp.tighteningThreshold = GNOMEStyle.clampTightening
        clamp.child = content
        root.child = clamp
    }

    /// Rebuilds chart groups. `snapshots` must already be ordered.
    func update(snapshots: [ProviderUsageSnapshot]) {
        while let child = content.firstChild {
            content.remove(child)
        }

        let charts = snapshots.flatMap { snapshot -> [(snapshot: ProviderUsageSnapshot, metric: UsageMetric)] in
            snapshot.metrics
                .filter { $0.kind == .chart && !($0.points ?? []).isEmpty }
                .map { (snapshot: snapshot, metric: $0) }
        }

        content.append(GNOMEStyle.pageHeader(
            title: "History",
            description: "Daily local usage trends with accessible point-by-point detail."
        ))
        guard !charts.isEmpty else {
            content.append(emptyPage)
            return
        }

        for entry in charts {
            content.append(chartGroup(entry.snapshot, metric: entry.metric))
        }
    }

    private func chartGroup(_ snapshot: ProviderUsageSnapshot, metric: UsageMetric) -> Widget {
        let points = Array((metric.points ?? []).suffix(ChartView.maximumPoints))
        let group = PreferencesGroup(title: snapshot.displayName)
        group.description = [snapshot.accountLabel, metric.label]
            .compactMap { $0 }.joined(separator: " · ").nilIfEmpty

        let chart = ChartView(points: points, providerName: snapshot.displayName,
                              unitLabel: "tokens")
        let chartContent = Box(
            orientation: GTK_ORIENTATION_VERTICAL,
            spacing: GNOMEStyle.rowSpacing
        )
        chartContent.setMargins(GNOMEStyle.sectionSpacing)
        chartContent.append(chart.widget)
        let dates = Box(
            orientation: GTK_ORIENTATION_HORIZONTAL,
            spacing: GNOMEStyle.controlSpacing
        )
        if let first = points.first, let last = points.last {
            let start = Label(GNOMEFormat.shortDay(first.date))
            start.xalign = 0
            start.hexpand = true
            start.addCSSClass(.caption)
            start.addCSSClass(.dimLabel)
            dates.append(start)
            let end = Label(GNOMEFormat.shortDay(last.date))
            end.xalign = 1
            end.addCSSClass(.caption)
            end.addCSSClass(.dimLabel)
            dates.append(end)
        }
        chartContent.append(dates)
        let chartRow = ListBoxRow()
        chartRow.child = chartContent
        chartRow.selectable = false
        chartRow.activatable = false
        group.add(chartRow)

        let legend = ActionRow(title: "Total over \(points.count) days")
        legend.subtitle = legendSubtitle(points)
        let total = Label("\(GNOMEFormat.tokens(points.reduce(0) { $0 + $1.value })) tokens")
        total.addCSSClass(.numeric)
        total.valign = GTK_ALIGN_CENTER
        legend.addSuffix(total)
        group.add(legend)

        let table = ExpanderRow(title: "Daily Values")
        table.subtitle = "Every chart point as text, newest first"
        for point in points.reversed() {
            let row = ActionRow(title: GNOMEFormat.shortDay(point.date))
            let value = Label("\(GNOMEFormat.tokens(point.value)) tokens")
            value.addCSSClass(.numeric)
            value.valign = GTK_ALIGN_CENTER
            row.addSuffix(value)
            table.addRow(row)
        }
        group.add(table)
        return group
    }

    private func legendSubtitle(_ points: [UsagePoint]) -> String {
        guard let first = points.first, let last = points.last else { return "" }
        return "\(GNOMEFormat.shortDay(first.date)) - \(GNOMEFormat.shortDay(last.date))"
    }
}
