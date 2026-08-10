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

    static let currentVersion = 1

    var version = Self.currentVersion
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

    private enum CodingKeys: String, CodingKey {
        case version, appearance, periodicRefreshEnabled, refreshIntervalMinutes, providerOrder
        case hiddenProviderIDs, launchAtLogin, analyticsEnabled, localAPIEnabled, localAPIPort
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try values.decode(Int.self, forKey: .version)
        guard decodedVersion == Self.currentVersion else {
            throw GNOMESettingsError.unsupportedVersion(decodedVersion)
        }
        version = Self.currentVersion
        appearance = try values.decodeIfPresent(Appearance.self, forKey: .appearance) ?? .system
        periodicRefreshEnabled = try values.decodeIfPresent(Bool.self, forKey: .periodicRefreshEnabled) ?? true
        refreshIntervalMinutes = try values.decodeIfPresent(Int.self, forKey: .refreshIntervalMinutes) ?? 5
        providerOrder = try values.decodeIfPresent([String].self, forKey: .providerOrder) ?? []
        hiddenProviderIDs = try values.decodeIfPresent([String].self, forKey: .hiddenProviderIDs)
        launchAtLogin = try values.decodeIfPresent(Bool.self, forKey: .launchAtLogin)
        analyticsEnabled = try values.decodeIfPresent(Bool.self, forKey: .analyticsEnabled)
        localAPIEnabled = try values.decodeIfPresent(Bool.self, forKey: .localAPIEnabled)
        localAPIPort = try values.decodeIfPresent(Int.self, forKey: .localAPIPort)
    }
}

enum GNOMESettingsError: Error, LocalizedError {
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            "Unsupported GNOME settings schema \(version)"
        }
    }
}

/// Owns `gnome-settings.json`. The historical shared `settings.json` is read only for a one-time,
/// copy-only migration when it is a valid GNOME v1 document; it is never modified or removed.
struct GNOMESettingsStore: Sendable {
    private let storage: VersionedJSONSettingsStorage
    private let legacyFileURL: URL

    init(paths: LinuxPaths = LinuxPaths()) {
        legacyFileURL = paths.configDirectory.appendingPathComponent("settings.json")
        storage = VersionedJSONSettingsStorage(
            fileURL: paths.configDirectory.appendingPathComponent("gnome-settings.json"),
            legacyFileURL: legacyFileURL
        )
    }

    func load() -> GNOMESettings {
        do {
            return try storage.loadMigratingLegacy(GNOMESettings.self) ?? GNOMESettings()
        } catch {
            NSLog("OpenUsage: GNOME settings were not loaded or migrated: \(error.localizedDescription)")
            return GNOMESettings()
        }
    }

    func save(_ settings: GNOMESettings) {
        do {
            try savePreservingLegacyOwnership(settings)
        } catch {
            NSLog("OpenUsage: failed to save GNOME settings: \(error.localizedDescription)")
        }
    }

    private func savePreservingLegacyOwnership(_ settings: GNOMESettings) throws {
        guard !FileManager.default.fileExists(atPath: storage.fileURL.path),
              FileManager.default.fileExists(atPath: legacyFileURL.path)
        else {
            try storage.save(settings)
            return
        }

        let legacyData = try Data(contentsOf: legacyFileURL, options: [.mappedIfSafe])
        do {
            _ = try GNOMESettingsDecoder.decode(legacyData)
            try storage.save(settings)
        } catch {
            // A schemaVersion discriminator identifies a core-owned document even when that core
            // version is newer than this binary. Its bytes remain untouched at the legacy path.
            if GNOMESettingsDecoder.isCoreDocument(legacyData) {
                try VersionedJSONSettingsStorage(fileURL: storage.fileURL).save(settings)
            } else {
                throw error
            }
        }
    }
}

private enum GNOMESettingsDecoder {
    static func decode(_ data: Data) throws -> GNOMESettings {
        try JSONDecoder().decode(GNOMESettings.self, from: data)
    }

    static func isCoreDocument(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["schemaVersion"] != nil
    }
}
