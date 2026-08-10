import Adwaita
import Foundation
import OpenUsageLinuxCore

enum MenuBarStyle: String, Codable, CaseIterable, Sendable {
    case text
    case bars

    var label: String {
        switch self {
        case .text: "Text"
        case .bars: "Bars"
        }
    }
}

enum WidgetDisplayMode: String, Codable, CaseIterable, Sendable {
    case used
    case remaining

    var label: String {
        switch self {
        case .used: "Used"
        case .remaining: "Left"
        }
    }
}

enum ResetDisplayMode: String, Codable, CaseIterable, Sendable {
    case relative
    case absolute

    var label: String {
        switch self {
        case .relative: "Countdown"
        case .absolute: "Exact Time"
        }
    }
}

enum DensitySetting: String, Codable, CaseIterable, Sendable {
    case regular
    case compact

    var label: String {
        switch self {
        case .regular: "Default"
        case .compact: "Compact"
        }
    }
}

enum TimeFormatSetting: String, Codable, CaseIterable, Sendable {
    case auto
    case twelveHour = "12h"
    case twentyFourHour = "24h"

    var label: String {
        switch self {
        case .auto: "Auto"
        case .twelveHour: "12-hour"
        case .twentyFourHour: "24-hour"
        }
    }
}

struct MetricPreferenceKey: Codable, Equatable, Hashable, Sendable {
    let kind: String
    let label: String

    init(metric: UsageMetric) {
        kind = metric.kind.rawValue
        label = metric.label
    }
}

enum MetricVisibilitySection: String, Codable, Sendable {
    case alwaysVisible
    case onDemand
}

struct MetricLayoutEntry: Codable, Equatable, Sendable {
    let key: MetricPreferenceKey
    var isEnabled: Bool
    var section: MetricVisibilitySection
}

struct ProviderMetricLayout: Codable, Equatable, Sendable {
    var entries: [MetricLayoutEntry]

    init(entries: [MetricLayoutEntry] = []) {
        self.entries = entries
    }

    mutating func reconcile(with metrics: [UsageMetric]) {
        var knownKeys: Set<MetricPreferenceKey> = []
        entries = entries.filter { knownKeys.insert($0.key).inserted }

        for metric in metrics {
            let key = MetricPreferenceKey(metric: metric)
            guard knownKeys.insert(key).inserted else { continue }
            entries.append(.init(key: key, isEnabled: true, section: .alwaysVisible))
        }
    }

    func entry(for key: MetricPreferenceKey) -> MetricLayoutEntry? {
        entries.first { $0.key == key }
    }

    mutating func setEnabled(_ isEnabled: Bool, for key: MetricPreferenceKey) {
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return }
        entries[index].isEnabled = isEnabled
    }

    mutating func move(
        _ key: MetricPreferenceKey,
        to section: MetricVisibilitySection,
        at requestedIndex: Int
    ) {
        guard let sourceIndex = entries.firstIndex(where: { $0.key == key }) else { return }
        var entry = entries.remove(at: sourceIndex)
        entry.section = section

        let sectionIndices = entries.indices.filter { entries[$0].section == section }
        let targetIndex = max(requestedIndex, 0)
        let insertionIndex: Int
        if targetIndex < sectionIndices.count {
            insertionIndex = sectionIndices[targetIndex]
        } else if let lastIndex = sectionIndices.last {
            insertionIndex = lastIndex + 1
        } else if section == .alwaysVisible,
                  let firstOnDemand = entries.firstIndex(where: { $0.section == .onDemand })
        {
            insertionIndex = firstOnDemand
        } else {
            insertionIndex = entries.endIndex
        }
        entries.insert(entry, at: insertionIndex)
    }

    func displayedMetrics(
        from metrics: [UsageMetric],
        in section: MetricVisibilitySection
    ) -> [UsageMetric] {
        var metricsByKey: [MetricPreferenceKey: UsageMetric] = [:]
        for metric in metrics {
            let key = MetricPreferenceKey(metric: metric)
            if metricsByKey[key] == nil {
                metricsByKey[key] = metric
            }
        }

        return entries.compactMap { entry in
            guard entry.isEnabled, entry.section == section else { return nil }
            return metricsByKey[entry.key]
        }
    }
}

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
    var trayUsageDisplayMode = TrayUsageDisplayMode.defaultValue
    var menuBarStyle: MenuBarStyle = .text
    var widgetDisplayMode: WidgetDisplayMode = .used
    var resetDisplayMode: ResetDisplayMode = .relative
    var alwaysShowPacing = false
    var density: DensitySetting = .regular
    var timeFormat: TimeFormatSetting = .auto
    var metricLayouts: [String: ProviderMetricLayout] = [:]
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
        case version, appearance, trayUsageDisplayMode, periodicRefreshEnabled
        case menuBarStyle, widgetDisplayMode, resetDisplayMode, alwaysShowPacing
        case density, timeFormat, metricLayouts
        case refreshIntervalMinutes, providerOrder
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
        trayUsageDisplayMode = try values.decodeIfPresent(
            TrayUsageDisplayMode.self,
            forKey: .trayUsageDisplayMode
        ) ?? .defaultValue
        menuBarStyle = try values.decodeIfPresent(MenuBarStyle.self, forKey: .menuBarStyle) ?? .text
        widgetDisplayMode = try values.decodeIfPresent(
            WidgetDisplayMode.self,
            forKey: .widgetDisplayMode
        ) ?? .used
        resetDisplayMode = try values.decodeIfPresent(
            ResetDisplayMode.self,
            forKey: .resetDisplayMode
        ) ?? .relative
        alwaysShowPacing = try values.decodeIfPresent(Bool.self, forKey: .alwaysShowPacing) ?? false
        density = try values.decodeIfPresent(DensitySetting.self, forKey: .density) ?? .regular
        timeFormat = try values.decodeIfPresent(TimeFormatSetting.self, forKey: .timeFormat) ?? .auto
        metricLayouts = try values.decodeIfPresent(
            [String: ProviderMetricLayout].self,
            forKey: .metricLayouts
        ) ?? [:]
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
        if FileManager.default.fileExists(atPath: storage.fileURL.path) {
            try storage.save(settings)
            return
        }

        let destinationStorage = VersionedJSONSettingsStorage(fileURL: storage.fileURL)
        guard let legacyData = try BoundedProviderFileReader(
            maximumBytes: VersionedJSONSettingsStorage.maximumDocumentBytes
        ).readIfPresent(legacyFileURL) else {
            try destinationStorage.save(settings)
            return
        }
        do {
            _ = try GNOMESettingsDecoder.decode(legacyData)
            try destinationStorage.save(settings)
        } catch {
            // A schemaVersion discriminator identifies a core-owned document even when that core
            // version is newer than this binary. Its bytes remain untouched at the legacy path.
            if GNOMESettingsDecoder.isCoreDocument(legacyData) {
                try destinationStorage.save(settings)
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
