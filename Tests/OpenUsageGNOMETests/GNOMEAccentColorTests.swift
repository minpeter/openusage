import Testing
@testable import OpenUsageGNOME

@MainActor
@Suite("GNOME accent color compatibility")
struct GNOMEAccentColorTests {
    @Test("missing libadwaita accent API uses the Adwaita blue fallback")
    func missingAccentAPI() {
        let palette = GNOMEStyle.chartPalette(
            dark: false,
            highContrast: false,
            accentColor: { nil })

        #expect(palette.accentRed == 0.208)
        #expect(palette.accentGreen == 0.518)
        #expect(palette.accentBlue == 0.894)
    }

    @Test("available libadwaita accent API drives the chart palette")
    func availableAccentAPI() {
        let palette = GNOMEStyle.chartPalette(
            dark: true,
            highContrast: true,
            accentColor: { GNOMEStyle.AccentColor(red: 0.9, green: 0.4, blue: 0.2) })

        #expect(palette.accentRed == 0.9)
        #expect(palette.accentGreen == 0.4)
        #expect(palette.accentBlue == 0.2)
        #expect(palette.trackAlpha == 0.60)
    }

}
