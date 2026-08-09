import Adwaita
import Foundation
import OpenUsageLinuxCore

/// Versioned XDG JSON settings for the GNOME shell (Linux parity matrix:
/// UserDefaults/settings -> versioned XDG JSON). Secrets never enter this
/// file; credentials stay in the Secret Service.
struct GNOMESettings: Codable, Equatable, Sendable {
    enum Appearance: String, Codable, CaseIterable, Sendable {
        case system
        case light
        case dark
    }

    var version = 1
    var appearance: Appearance = .system
    var periodicRefreshEnabled = true
    var refreshIntervalMinutes = 5
    var providerOrder: [String] = []
    var hiddenProviderIDs: [String]?
    var launchAtLogin: Bool?
    var analyticsEnabled: Bool?
    var localAPIEnabled: Bool?
    var localAPIPort: Int?

    static let minimumInterval = 1
    static let maximumInterval = 60
}

/// Loads and saves settings next to the snapshot cache.
struct GNOMESettingsStore: Sendable {
    private let fileURL: URL

    init(paths: LinuxPaths = LinuxPaths()) {
        fileURL = paths.configDirectory.appendingPathComponent("settings.json")
    }

    func load() -> GNOMESettings {
        guard let data = try? Data(contentsOf: fileURL) else { return GNOMESettings() }
        return (try? JSONDecoder().decode(GNOMESettings.self, from: data)) ?? GNOMESettings()
    }

    func save(_ settings: GNOMESettings) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(settings).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("OpenUsage: failed to save GNOME settings: \(error.localizedDescription)")
        }
    }
}
