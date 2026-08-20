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
        #expect(long == "kali2005611@gmail.com · Pro 20x")
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

        #expect(subtitle == "dev@example.com · Plus · HTTP 401 · Check credentials")
        #expect(!subtitle.contains("\n"))
        #expect(GNOMEProviderRowLayout.lineCount(subtitle) == 1)
    }

    @Test("Header min-height is CSS on the expander header, not a widget request")
    func headerHeightUsesCSS() {
        #expect(GNOMEProviderRowLayout.headerMinHeight == 72)
        #expect(GNOMEProviderRowLayout.headerVerticalPadding == 10)
        #expect(GNOMEProviderRowLayout.css.contains("row.\(GNOMEProviderRowLayout.cssClass) row.header"))
        #expect(GNOMEProviderRowLayout.css.contains("min-height: \(GNOMEProviderRowLayout.headerMinHeight)px"))
        #expect(GNOMEProviderRowLayout.css.contains("padding-top: \(GNOMEProviderRowLayout.headerVerticalPadding)px"))
        #expect(GNOMEProviderRowLayout.css.contains("padding-bottom: \(GNOMEProviderRowLayout.headerVerticalPadding)px"))
        #expect(GNOMEProviderRowLayout.css.contains("row.\(GNOMEProviderRowLayout.cssClass) list.nested"))
        #expect(GNOMEProviderRowLayout.css.contains(".\(GNOMEProviderRowLayout.groupCSSClass) list:not(.nested)"))
        #expect(!GNOMEProviderRowLayout.css.contains("row.\(GNOMEProviderRowLayout.cssClass) > row.header"))
        #expect(!GNOMEProviderRowLayout.css.contains("row.\(GNOMEProviderRowLayout.cssClass).expander {\n        min-height"))
    }
}
