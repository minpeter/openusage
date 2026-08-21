import Testing
@testable import OpenUsageGNOME

@Suite("GNOME provider row layout")
struct GNOMEProviderRowLayoutTests {
    @Test("Short and long identities stay on one subtitle line")
    func identityStaysOneLine() {
        let short = GNOMEProviderRowLayout.subtitle(accountLabel: nil, plan: "Pro")
        let long = GNOMEProviderRowLayout.subtitle(
            accountLabel: "kali2005611@gmail.com",
            plan: "Pro 20x"
        )

        #expect(short == "Pro")
        #expect(long == "Pro 20x")
        #expect(!long.contains("@"))
        #expect(GNOMEProviderRowLayout.lineCount(short) == 1)
        #expect(GNOMEProviderRowLayout.lineCount(long) == 1)
        #expect(GNOMEProviderRowLayout.subtitleLines == 1)
        #expect(GNOMEProviderRowLayout.titleLines == 1)
    }

    @Test("Collapsed status stays on the same subtitle line")
    func collapsedStatusDoesNotWrapHeader() {
        let subtitle = GNOMEProviderRowLayout.subtitle(
            accountLabel: "dev@example.com",
            plan: "Plus",
            collapsedStatus: "HTTP 401 · Check credentials"
        )

        #expect(subtitle == "Plus · HTTP 401 · Check credentials")
        #expect(!subtitle.contains("@"))
        #expect(!subtitle.contains("\n"))
        #expect(GNOMEProviderRowLayout.lineCount(subtitle) == 1)
    }

    @Test("Provider rows never show a raw user id or full email")
    func hidesRawIdentity() {
        #expect(
            GNOMEProviderRowLayout.subtitle(
                accountLabel: "user_01KZZDNQW6KCTH4M3KJMNQWTTC",
                plan: "Ultra"
            ) == "Ultra"
        )
        #expect(
            GNOMEProviderRowLayout.subtitle(
                accountLabel: "user_01KZZDNQW6KCTH4M3KJMNQWTTC",
                plan: nil
            ).isEmpty
        )
        #expect(
            GNOMEProviderRowLayout.subtitle(
                accountLabel: "kali2005611@gmail.com",
                plan: nil
            ) == "k***@gmail.com"
        )
        #expect(GNOMEProviderRowLayout.displayIdentity("user_01KZZDNQW6KCTH4M3KJMNQWTTC") == nil)
        #expect(GNOMEProviderRowLayout.maskEmail("kali2005611@gmail.com") == "k***@gmail.com")
    }

    @Test("Header follows Adwaita action-row density, not a 72px floor")
    func headerHeightUsesCompactCSS() {
        #expect(GNOMEProviderRowLayout.disclosureBottomPadding == 10)
        #expect(GNOMEProviderRowLayout.css.contains(".\(GNOMEProviderRowLayout.groupCSSClass) list:not(.nested)"))
        #expect(GNOMEProviderRowLayout.css.contains("padding-top: 0"))
        #expect(GNOMEProviderRowLayout.css.contains("padding-bottom: 0"))
        #expect(GNOMEProviderRowLayout.css.contains("row.\(GNOMEProviderRowLayout.cssClass).expander"))
        #expect(GNOMEProviderRowLayout.css.contains("row.\(GNOMEProviderRowLayout.cssClass) list.nested"))
        #expect(GNOMEProviderRowLayout.css.contains("padding-bottom: \(GNOMEProviderRowLayout.disclosureBottomPadding)px"))
        #expect(!GNOMEProviderRowLayout.css.contains("min-height"))
        #expect(!GNOMEProviderRowLayout.css.contains("72px"))
        #expect(!GNOMEProviderRowLayout.css.contains("row.\(GNOMEProviderRowLayout.cssClass) row.header"))
        #expect(!GNOMEProviderRowLayout.css.contains("row.\(GNOMEProviderRowLayout.cssClass) > row.header"))
        #expect(!GNOMEProviderRowLayout.css.contains("row.\(GNOMEProviderRowLayout.cssClass).expander {\n        min-height"))
    }
}
