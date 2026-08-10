import Foundation
import Testing
@testable import OpenUsageGNOME

@Suite("GNOME settings")
struct GNOMESettingsTests {
    @Test("Missing display preferences decode to macOS-equivalent defaults")
    func displayPreferenceDefaults() throws {
        let settings = try JSONDecoder().decode(
            GNOMESettings.self,
            from: Data(#"{"version":1}"#.utf8)
        )

        #expect(settings.menuBarStyle == .text)
        #expect(settings.widgetDisplayMode == .used)
        #expect(settings.resetDisplayMode == .relative)
        #expect(settings.alwaysShowPacing == false)
        #expect(settings.density == .regular)
        #expect(settings.timeFormat == .auto)
        #expect(settings.notifyAlmostOut)
        #expect(settings.notifyCuttingItClose)
        #expect(settings.notifyWillRunOut)
    }

    @Test("Display preferences survive a JSON round trip")
    func displayPreferenceRoundTrip() throws {
        var settings = GNOMESettings()
        settings.menuBarStyle = .bars
        settings.widgetDisplayMode = .remaining
        settings.resetDisplayMode = .absolute
        settings.alwaysShowPacing = true
        settings.density = .compact
        settings.timeFormat = .twentyFourHour
        settings.notifyAlmostOut = false
        settings.notifyCuttingItClose = false
        settings.notifyWillRunOut = false

        let decoded = try JSONDecoder().decode(
            GNOMESettings.self,
            from: JSONEncoder().encode(settings)
        )

        #expect(decoded.menuBarStyle == .bars)
        #expect(decoded.widgetDisplayMode == .remaining)
        #expect(decoded.resetDisplayMode == .absolute)
        #expect(decoded.alwaysShowPacing)
        #expect(decoded.density == .compact)
        #expect(decoded.timeFormat == .twentyFourHour)
        #expect(!decoded.notifyAlmostOut)
        #expect(!decoded.notifyCuttingItClose)
        #expect(!decoded.notifyWillRunOut)
    }

    @Test("Sync directory survives restart and blank input restores the default")
    func syncDirectoryRoundTrip() throws {
        var settings = GNOMESettings()
        settings.setSyncDirectory("  /home/tester/Usage Sync  ")

        let persisted = try JSONEncoder().encode(settings)
        var restarted = try JSONDecoder().decode(GNOMESettings.self, from: persisted)

        #expect(restarted.syncDirectoryPath == "/home/tester/Usage Sync")
        restarted.setSyncDirectory(" \n ")
        #expect(restarted.syncDirectoryPath == nil)
    }
}
