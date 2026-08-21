import Adwaita
import Foundation

/// Layout contract for Providers → Connected Accounts rows.
///
/// Adwaita `ExpanderRow` measures height-for-width at an unbounded width, so a
/// wrapping subtitle plus `setSizeRequest` on the whole expander makes long
/// plan names and expanded headers look tighter than a short `Pro` subtitle.
/// Keep the collapsed header one title line + one ellipsized subtitle so
/// every row shares the same compact header.
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

    /// Providers content must fill the window and scroll when an expander
    /// grows. Without `vexpand`, GtkScrolledWindow requests the child's
    /// natural height and the window clips the last metric/link rows.
    @MainActor
    static func configureScrolling(_ window: ScrolledWindow) {
        window.vexpand = true
        window.hexpand = true
        window.setPolicy(horizontal: GTK_POLICY_NEVER, vertical: GTK_POLICY_AUTOMATIC)
    }

    /// Plan/tier, and an optional collapsed status, as a single subtitle line.
    /// Prefer plan only. Raw `user_…` ids never appear. A lone email is masked
    /// only when there is no plan to show.
    static func subtitle(
        accountLabel: String?,
        plan: String?,
        collapsedStatus: String? = nil
    ) -> String {
        let planText = plan?.nilIfEmpty
        let identity = planText == nil ? displayIdentity(accountLabel) : nil
        return [identity, planText, collapsedStatus]
            .compactMap { $0?.nilIfEmpty }
            .joined(separator: " · ")
    }

    /// Sanitized identity for provider-row subtitles when no plan is available.
    static func displayIdentity(_ accountLabel: String?) -> String? {
        guard let raw = accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }
        if isRawUserID(raw) { return nil }
        if let email = isolatedEmail(raw) { return maskEmail(email) }
        return redactIdentityTokens(raw)
    }

    static func isRawUserID(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("user_") else { return false }
        let rest = trimmed.dropFirst(5)
        return !rest.isEmpty && rest.allSatisfy { $0.isLetter || $0.isNumber }
    }

    static func maskEmail(_ email: String) -> String {
        let parts = email.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let local = parts.first, let domain = parts.last, !local.isEmpty else {
            return email
        }
        return "\(local.prefix(1))***@\(domain)"
    }

    private static func isolatedEmail(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("@") && !trimmed.contains(" ") ? trimmed : nil
    }

    private static func redactIdentityTokens(_ value: String) -> String? {
        let tokens = value.split(whereSeparator: { $0.isWhitespace || $0 == "·" || $0 == "|" })
        let kept = tokens.compactMap { token -> String? in
            let piece = String(token)
            if isRawUserID(piece) { return nil }
            if piece.contains("@") { return maskEmail(piece) }
            return piece
        }
        .filter { !$0.isEmpty }
        return kept.isEmpty ? nil : kept.joined(separator: " ")
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
        overflow: visible;
    }
    """
}
