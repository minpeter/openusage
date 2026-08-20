import Foundation

/// Layout contract for Providers → Connected Accounts rows.
///
/// Adwaita `ExpanderRow` measures height-for-width at an unbounded width, so a
/// wrapping subtitle plus `setSizeRequest` on the whole expander makes long
/// identities (`email · Pro 20x`) and expanded headers look tighter than a
/// short `Pro` subtitle. Keep the collapsed header one title line + one
/// ellipsized subtitle so every row shares the same compact header.
///
/// Do not force a header `min-height` above Adwaita's action-row (~50px).
/// A 72px floor evens rows by growing the short `Pro` header and makes
/// every collapsed row look padded. Size comes from the one-line subtitle,
/// not extra chrome.
enum GNOMEProviderRowLayout {
    static let cssClass = "ou-provider-row"
    static let groupCSSClass = "ou-connected-accounts"

    /// Disclosure inset so expanded content does not hug the boxed-list edge.
    /// First and last collapsed rows stay even by zeroing the group list inset.
    static let disclosureBottomPadding = 10
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
    row.\(cssClass) list.nested {
        padding-top: 0;
        padding-bottom: \(disclosureBottomPadding)px;
    }
    """
}
