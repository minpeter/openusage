import Foundation

/// Layout contract for Providers → Connected Accounts rows.
///
/// Adwaita `ExpanderRow` measures height-for-width at an unbounded width, so a
/// wrapping subtitle plus `setSizeRequest` on the whole expander makes long
/// identities (`email · Pro 20x`) and expanded headers look tighter than a
/// short `Pro` subtitle. Keep the collapsed header one title line + one
/// ellipsized subtitle, and size that header with CSS — not a widget request.
enum GNOMEProviderRowLayout {
    static let cssClass = "ou-provider-row"
    static let groupCSSClass = "ou-connected-accounts"

    /// Comfortable collapsed header for title + one subtitle line.
    static let headerMinHeight = 72
    /// Symmetric inset so the first and last boxed-list rows match.
    static let headerVerticalPadding = 10
    static let titleLines = 1
    static let subtitleLines = 1

    /// Identity, and an optional collapsed status, as a single subtitle line.
    static func subtitle(
        accountLabel: String?,
        plan: String?,
        collapsedStatus: String? = nil
    ) -> String {
        [accountLabel, plan, collapsedStatus]
            .compactMap { $0?.nilIfEmpty }
            .joined(separator: " · ")
    }

    static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    static let css = """
    .\(groupCSSClass) list:not(.nested) {
        padding-top: 0;
        padding-bottom: 0;
    }
    row.\(cssClass).expander {
        padding: 0;
    }
    row.\(cssClass) > row.header {
        min-height: \(headerMinHeight)px;
        padding-top: \(headerVerticalPadding)px;
        padding-bottom: \(headerVerticalPadding)px;
    }
    row.\(cssClass) > list.nested {
        padding-top: 0;
        padding-bottom: \(headerVerticalPadding)px;
    }
    """
}
