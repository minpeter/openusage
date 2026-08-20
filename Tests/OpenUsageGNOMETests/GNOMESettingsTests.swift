import Foundation
import OpenUsageLinuxCore
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

    @Test("Proxy controls survive restart and blank input disables proxying")
    func proxySettingsRoundTrip() throws {
        var settings = GNOMESettings()
        try settings.setProxy(
            enabled: true,
            url: " http://proxy.example.com:8080 ",
            bypassText: "internal.example.com, localhost"
        )

        let persisted = try JSONEncoder().encode(settings)
        var restarted = try JSONDecoder().decode(GNOMESettings.self, from: persisted)

        #expect(restarted.proxyEnabled)
        #expect(restarted.proxyURL == "http://proxy.example.com:8080")
        #expect(restarted.proxyBypassHosts == ["internal.example.com", "localhost"])
        #expect(try restarted.proxyConfiguration()?.host == "proxy.example.com")

        try restarted.setProxy(enabled: false, url: "", bypassText: "")
        #expect(!restarted.proxyEnabled)
        #expect(try restarted.proxyConfiguration() == nil)
    }

    @Test("Log level survives restart with Info as the migration default")
    func logLevelRoundTrip() throws {
        let migrated = try JSONDecoder().decode(
            GNOMESettings.self,
            from: Data(#"{"version":1}"#.utf8)
        )
        #expect(migrated.logLevel == .info)

        var settings = migrated
        settings.logLevel = .debug
        let restarted = try JSONDecoder().decode(
            GNOMESettings.self,
            from: JSONEncoder().encode(settings)
        )
        #expect(restarted.logLevel == .debug)
    }

    @Test("Persistence failures are returned to the controller")
    func persistenceFailureIsObservable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a directory".utf8).write(to: root)
        let store = GNOMESettingsStore(paths: LinuxPaths(environment: [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "XDG_CONFIG_HOME": root.path,
        ]))

        #expect(throws: (any Error).self) {
            try store.save(GNOMESettings())
        }
    }

    @Test("Launch-at-login failure reconciles the actual backend state")
    func launchAtLoginFailureReconciliation() {
        let actual = DashboardController.reconciledLaunchAtLoginState(
            fallback: false
        ) {
            true
        }
        let unavailable = DashboardController.reconciledLaunchAtLoginState(
            fallback: true
        ) {
            throw CocoaError(.fileReadUnknown)
        }

        #expect(actual)
        #expect(unavailable)
    }

    @Test("Provider order empty-state is only for an empty list")
    func providerOrderEmptyBanner() {
        #expect(SettingsProvidersPresentation.showsEmptyOrderBanner(order: []))
        #expect(!SettingsProvidersPresentation.showsEmptyOrderBanner(order: [
            "antigravity", "claude",
        ]))
    }
}
