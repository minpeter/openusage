import Adwaita
import Foundation

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
    static let outerMargin = 18
    /// Vertical spacing between boxed sections.
    static let sectionSpacing = 12
    /// Spacing inside a row cluster (title/value/caption stacks).
    static let rowSpacing = 6
    /// Horizontal spacing between sibling controls in one row.
    static let controlSpacing = 8
    /// Content is clamped to preserve readable density on wide windows.
    static let contentClamp = 720
    /// Clamp starts tightening before the hard maximum.
    static let clampTightening = 560
    /// Default and minimum window geometry from the design contract.
    static let defaultWidth = 720
    static let defaultHeight = 720
    static let minimumWidth = 360
    static let minimumHeight = 294
    /// Below this width the header switcher collapses into a bottom bar.
    static let narrowBreakpointWidth = 640.0
    /// Smallest interactive target height (accessibility contract).
    static let minimumTargetHeight = 40

    // MARK: - Chart palette

    struct ChartPalette: Sendable {
        let accentRed: Double
        let accentGreen: Double
        let accentBlue: Double
        /// Alpha used for the fill under the accent stroke.
        let fillAlpha: Double
        /// Alpha used for the baseline/track.
        let trackAlpha: Double
    }

    /// Live system accent (e.g. blue on stock GNOME, orange on Ubuntu) with
    /// appearance-aware alpha levels. High contrast raises the track alpha so
    /// chart geometry never depends on subtle shades. Falls back to Adwaita
    /// blue when the platform cannot report an accent.
    static func chartPalette(dark: Bool, highContrast: Bool) -> ChartPalette {
        var accent = (red: 0.208, green: 0.518, blue: 0.894)
        if let rgba = adw_style_manager_get_accent_color_rgba(
            OpaquePointer(StyleManager.default.pointer)
        ) {
            accent = (red: Double(rgba.pointee.red), green: Double(rgba.pointee.green),
                      blue: Double(rgba.pointee.blue))
            g_free(rgba)
        }
        let fillAlpha: Double
        let trackAlpha: Double
        switch (dark, highContrast) {
        case (false, false): (fillAlpha, trackAlpha) = (0.18, 0.25)
        case (false, true): (fillAlpha, trackAlpha) = (0.30, 0.55)
        case (true, false): (fillAlpha, trackAlpha) = (0.22, 0.30)
        case (true, true): (fillAlpha, trackAlpha) = (0.35, 0.60)
        }
        return ChartPalette(accentRed: accent.red, accentGreen: accent.green,
                            accentBlue: accent.blue, fillAlpha: fillAlpha, trackAlpha: trackAlpha)
    }

    // MARK: - Custom CSS

    /// The only custom CSS in the app: a plan/state pill built from
    /// libadwaita accent tokens. No hardcoded colors.
    static let css = """
    .ou-pill {
        padding: 2px 9px;
        border-radius: 999px;
    }
    .ou-pill.accent {
        background-color: alpha(@accent_bg_color, 0.16);
        color: @accent_bg_color;
    }
    .ou-pill.success {
        background-color: alpha(@success_bg_color, 0.18);
        color: @success_bg_color;
    }
    .ou-pill.warning {
        background-color: alpha(@warning_bg_color, 0.20);
        color: @warning_bg_color;
    }
    .ou-pill.error {
        background-color: alpha(@error_bg_color, 0.18);
        color: @error_bg_color;
    }
    """

    static func installCSS() {
        let provider = CSSProvider()
        provider.loadFromString(css)
        provider.addToDefaultDisplay()
        retainedCSSProvider = provider
    }

    private static var retainedCSSProvider: CSSProvider?
}

/// Shared copy builders so every view formats values identically.
@MainActor
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

    static func shortDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    static func percent(_ used: Double) -> String {
        "\(Int(used.rounded()))% used"
    }
}

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
