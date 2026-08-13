import Adwaita
import Foundation
import Glibc
import OpenUsageLinuxCore

/// Design tokens for the OpenUsage GNOME shell.
///
/// Colors and typography come from libadwaita itself (CSS classes, accent
/// color, system fonts). This file centralizes the numeric rhythm from
/// DESIGN.md and the small amount of custom CSS the design needs, so every
/// view composes the same tokens instead of inventing ad-hoc values.
@MainActor
enum GNOMEStyle {

    // MARK: - Layout rhythm (DESIGN.md section 3)

    /// Outer margins around scrolled content.
    static let outerMargin = 24
    /// Vertical spacing between boxed sections.
    static let sectionSpacing = 18
    /// Spacing inside a row cluster (title/value/caption stacks).
    static let rowSpacing = 6
    /// Horizontal spacing between sibling controls in one row.
    static let controlSpacing = 8
    /// Content is clamped to preserve readable density on wide windows.
    static let contentClamp = 840
    /// Clamp starts tightening before the hard maximum.
    static let clampTightening = 640
    /// Default and minimum window geometry from the design contract.
    static let defaultWidth = 900
    static let defaultHeight = 760
    static let minimumWidth = 360
    static let minimumHeight = 294
    /// Below this width the header switcher collapses into a bottom bar.
    static let narrowBreakpointWidth = 680.0
    /// Smallest interactive target height (accessibility contract).
    static let minimumTargetHeight = 40
    static let summaryCardPadding = 16

    // MARK: - Chart palette

    struct ChartPalette: Sendable {
        let accentRed: Double
        let accentGreen: Double
        let accentBlue: Double
        /// Alpha used for the baseline/track.
        let trackAlpha: Double
    }

    struct AccentColor: Sendable {
        let red: Double
        let green: Double
        let blue: Double
    }

    /// Live system accent (e.g. blue on stock GNOME, orange on Ubuntu) with
    /// appearance-aware alpha levels. High contrast raises the track alpha so
    /// chart geometry never depends on subtle shades. Falls back to Adwaita
    /// blue when the platform cannot report an accent.
    static func chartPalette(
        dark: Bool,
        highContrast: Bool,
        accentColor: @MainActor () -> AccentColor? = systemAccentColor
    ) -> ChartPalette {
        var accent = (red: 0.208, green: 0.518, blue: 0.894)
        if let rgba = accentColor() {
            accent = (red: rgba.red, green: rgba.green, blue: rgba.blue)
        }
        let trackAlpha: Double
        switch (dark, highContrast) {
        case (false, false): trackAlpha = 0.25
        case (false, true): trackAlpha = 0.55
        case (true, false): trackAlpha = 0.30
        case (true, true): trackAlpha = 0.60
        }
        return ChartPalette(accentRed: accent.red, accentGreen: accent.green,
                            accentBlue: accent.blue, trackAlpha: trackAlpha)
    }

    static func systemAccentColor() -> AccentColor? {
        guard let function = accentColorFunction() else {
            return nil
        }
        guard let rgba = function(OpaquePointer(StyleManager.default.pointer)) else {
            return nil
        }
        defer { g_free(rgba) }
        let components = rgba.assumingMemoryBound(to: Double.self)
        return AccentColor(
            red: components[0],
            green: components[1],
            blue: components[2])
    }

    static func accentColorFunction() -> (
        @convention(c) (OpaquePointer?) -> UnsafeMutableRawPointer?
    )? {
        guard let symbol = dlsym(
            nil,
            "adw_style_manager_get_accent_color_rgba"
        ) else {
            return nil
        }
        return unsafeBitCast(
            symbol,
            to: (@convention(c) (OpaquePointer?) -> UnsafeMutableRawPointer?).self)
    }

    // MARK: - Custom CSS

    /// Small structural accents which libadwaita does not expose as widget
    /// properties. Colors continue to come from the active Adwaita theme.
    static let css = """
    button.ou-copy-success image {
      color: @success_color;
    }

    .ou-summary-card {
        padding: \(summaryCardPadding)px;
        border-radius: 12px;
        background-color: @card_bg_color;
        box-shadow: 0 1px 3px alpha(@shade_color, 0.14);
    }
    .ou-legend-row {
        min-height: 32px;
        padding: 0 4px;
    }
    .ou-chart-card {
        padding: 6px;
    }
    .ou-stat-strip {
        padding: 2px 4px 8px;
    }
    .ou-comparison-track {
        min-height: 8px;
        border-radius: 999px;
        background-color: alpha(@accent_bg_color, 0.14);
    }
    .ou-summary-card .title-1,
    .ou-summary-card .title-2 {
        font-feature-settings: "tnum";
    }
    .ou-navigation button {
        min-width: 0;
        padding-left: 4px;
        padding-right: 4px;
    }
    """

    static func installCSS() {
        let provider = CSSProvider()
        provider.loadFromString(css)
        provider.addToDefaultDisplay()
        retainedCSSProvider = provider
    }

    private static var retainedCSSProvider: CSSProvider?

    static func pageHeader(title: String, description: String) -> Widget {
        let header = Box(
            orientation: GTK_ORIENTATION_VERTICAL,
            spacing: rowSpacing
        )
        let titleLabel = Label(title)
        titleLabel.xalign = 0
        titleLabel.addCSSClass(GNOMETypographyRole.pageTitle.cssClass)
        header.append(titleLabel)

        let descriptionLabel = Label(description)
        descriptionLabel.xalign = 0
        descriptionLabel.wrap = true
        descriptionLabel.addCSSClass(.dimLabel)
        header.append(descriptionLabel)
        return header
    }
}

enum GNOMETypographyRole: Sendable {
    case pageTitle
    case cardTitle
    case heroValue
    case statValue

    var cssClass: String {
        switch self {
        case .pageTitle, .heroValue:
            "title-2"
        case .cardTitle, .statValue:
            "heading"
        }
    }
}

/// Shared copy builders so every view formats values identically.
enum GNOMEFormat {

    static func relativeReset(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(Int(date.timeIntervalSince(now)), 0)
        if seconds < 60 { return "Resets now" }
        if seconds < 3_600 { return "Resets in \(seconds / 60)m" }
        if seconds < 86_400 { return "Resets in \(seconds / 3_600)h" }
        return "Resets in \(seconds / 86_400)d \(seconds % 86_400 / 3_600)h"
    }

    static func relativeRefresh(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(Int(now.timeIntervalSince(date)), 0)
        if seconds < 45 { return "Updated just now" }
        if seconds < 3_600 { return "Updated \(seconds / 60)m ago" }
        if seconds < 86_400 { return "Updated \(seconds / 3_600)h ago" }
        return "Updated \(seconds / 86_400)d ago"
    }

    static func currency(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    static func tokens(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value.rounded())) ?? "\(Int(value.rounded()))"
    }

    static func compactNumber(_ value: Double) -> String {
        let absolute = abs(value)
        let scaled: Double
        let suffix: String
        switch absolute {
        case 1_000_000_000...:
            scaled = value / 1_000_000_000
            suffix = "B"
        case 1_000_000...:
            scaled = value / 1_000_000
            suffix = "M"
        case 1_000...:
            scaled = value / 1_000
            suffix = "K"
        default:
            return tokens(value)
        }
        return String(format: scaled >= 100 ? "%.0f%@" : "%.1f%@", scaled, suffix)
    }

    static func shortDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    static func percent(_ used: Double) -> String {
        "\(Int(used.rounded()))% used"
    }
}

struct GNOMEMetricPresentationSettings: Equatable, Sendable {
    let displayMode: WidgetDisplayMode
    let resetMode: ResetDisplayMode
    let timeFormat: TimeFormatSetting
    let alwaysShowPacing: Bool

    init(
        displayMode: WidgetDisplayMode = .used,
        resetMode: ResetDisplayMode = .relative,
        timeFormat: TimeFormatSetting = .auto,
        alwaysShowPacing: Bool = false
    ) {
        self.displayMode = displayMode
        self.resetMode = resetMode
        self.timeFormat = timeFormat
        self.alwaysShowPacing = alwaysShowPacing
    }

    func presentation(
        for metric: UsageMetric,
        now: Date = Date(),
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> GNOMEMetricPresentation {
        GNOMEMetricPresentation(
            metric: metric,
            displayMode: displayMode,
            resetMode: resetMode,
            timeFormat: timeFormat,
            alwaysShowPacing: alwaysShowPacing,
            now: now,
            locale: locale,
            timeZone: timeZone
        )
    }
}

extension GNOMESettings {
    var metricPresentationSettings: GNOMEMetricPresentationSettings {
        .init(
            displayMode: widgetDisplayMode,
            resetMode: resetDisplayMode,
            timeFormat: timeFormat,
            alwaysShowPacing: alwaysShowPacing
        )
    }
}

struct GNOMEMetricPresentation: Equatable, Sendable {
    let valueText: String
    let resetText: String?
    let pacingText: String?

    init(
        metric: UsageMetric,
        displayMode: WidgetDisplayMode,
        resetMode: ResetDisplayMode,
        timeFormat: TimeFormatSetting,
        alwaysShowPacing: Bool,
        now: Date = Date(),
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) {
        valueText = Self.valueText(metric: metric, displayMode: displayMode)
        resetText = Self.resetText(
            metric: metric,
            mode: resetMode,
            timeFormat: timeFormat,
            now: now,
            locale: locale,
            timeZone: timeZone
        )
        pacingText = Self.pacingText(
            metric: metric,
            alwaysShow: alwaysShowPacing,
            now: now
        )
    }

    private static func valueText(
        metric: UsageMetric,
        displayMode: WidgetDisplayMode
    ) -> String {
        guard let fraction = metric.fraction else {
            return metric.detail ?? String(format: "%.0f", metric.used)
        }
        let displayedFraction = displayMode == .used ? fraction : 1 - fraction
        let percent = Int((displayedFraction * 100).rounded())
        return "\(percent)% \(displayMode.label.lowercased())"
    }

    private static func resetText(
        metric: UsageMetric,
        mode: ResetDisplayMode,
        timeFormat: TimeFormatSetting,
        now: Date,
        locale: Locale,
        timeZone: TimeZone
    ) -> String? {
        guard let resetsAt = metric.resetsAt else { return nil }
        switch mode {
        case .relative:
            return GNOMEFormat.relativeReset(resetsAt, now: now)
        case .absolute:
            return exactResetText(
                resetsAt,
                now: now,
                timeFormat: timeFormat,
                locale: locale,
                timeZone: timeZone
            )
        }
    }

    private static func exactResetText(
        _ date: Date,
        now: Date,
        timeFormat: TimeFormatSetting,
        locale: Locale,
        timeZone: TimeZone
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone

        let day: String
        if calendar.isDate(date, inSameDayAs: now) {
            day = "today"
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
                  calendar.isDate(date, inSameDayAs: tomorrow)
        {
            day = "tomorrow"
        } else {
            let dayFormatter = DateFormatter()
            dayFormatter.locale = locale
            dayFormatter.timeZone = timeZone
            dayFormatter.setLocalizedDateFormatFromTemplate("MMM d")
            day = dayFormatter.string(from: date)
        }

        let timeFormatter = DateFormatter()
        timeFormatter.locale = locale
        timeFormatter.timeZone = timeZone
        switch timeFormat {
        case .auto:
            timeFormatter.setLocalizedDateFormatFromTemplate("j:mm")
        case .twelveHour:
            timeFormatter.dateFormat = "h:mm a"
        case .twentyFourHour:
            timeFormatter.dateFormat = "HH:mm"
        }
        return "Resets \(day) at \(timeFormatter.string(from: date))"
    }

    private static func pacingText(
        metric: UsageMetric,
        alwaysShow: Bool,
        now: Date
    ) -> String? {
        guard metric.kind == .progress,
              let limit = metric.limit,
              metric.used.isFinite,
              limit.isFinite,
              limit > 0,
              let resetsAt = metric.resetsAt,
              let periodMilliseconds = metric.periodDurationMilliseconds,
              periodMilliseconds > 0
        else {
            return nil
        }

        let period = TimeInterval(periodMilliseconds) / 1_000
        let startedAt = resetsAt.addingTimeInterval(-period)
        let elapsed = now.timeIntervalSince(startedAt)
        guard period.isFinite,
              elapsed.isFinite,
              elapsed > 0,
              elapsed < period
        else {
            return nil
        }

        let projectedPercent = max(metric.used, 0) / limit / (elapsed / period) * 100
        let roundedProjection = Int(projectedPercent.rounded())
        if projectedPercent <= 90 {
            guard alwaysShow else { return nil }
            return "On pace · ~\(roundedProjection)% at reset"
        }
        if projectedPercent <= 100 {
            return "Close · ~\(roundedProjection)% at reset"
        }
        return "Will run out · ~\(roundedProjection)% at reset"
    }
}

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
