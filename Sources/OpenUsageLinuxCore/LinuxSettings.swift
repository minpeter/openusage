import Foundation

/// Stable identity for one provider card. `accountInstanceID` is an opaque, durable identifier minted
/// by account discovery; it is deliberately not an email address, token, or array position.
public struct LinuxProviderInstanceID: Codable, Hashable, Sendable, Comparable {
    public let providerID: String
    public let accountInstanceID: String?

    public init(providerID: String, accountInstanceID: String? = nil) {
        self.providerID = providerID
        self.accountInstanceID = accountInstanceID
    }

    /// The identifier shared with snapshots and Secret Service attributes.
    public var rawValue: String {
        accountInstanceID.map { "\(providerID):\($0)" } ?? providerID
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum LinuxProviderCatalog {
    /// Current provider families. Settings are not restricted to this list: unknown/new provider and
    /// account instances are retained and reconciled generically.
    public static let currentProviderIDs = [
        "claude", "codex", "cursor", "antigravity", "copilot", "devin",
        "grok", "opencode", "openrouter", "pi", "zai",
    ]
}

public enum LinuxRefreshInterval: Int, Codable, CaseIterable, Sendable {
    case oneMinute = 1
    case fiveMinutes = 5
    case fifteenMinutes = 15
    case thirtyMinutes = 30
    case oneHour = 60

    public var seconds: TimeInterval { TimeInterval(rawValue * 60) }
}

public enum LinuxAppearance: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark
}

public struct LinuxProviderInstanceSettings: Codable, Equatable, Sendable {
    public var instance: LinuxProviderInstanceID
    public var isVisible: Bool
    public var customLabel: String?
    public var refreshInterval: LinuxRefreshInterval?

    public init(
        instance: LinuxProviderInstanceID,
        isVisible: Bool = true,
        customLabel: String? = nil,
        refreshInterval: LinuxRefreshInterval? = nil
    ) {
        self.instance = instance
        self.isVisible = isVisible
        self.customLabel = customLabel
        self.refreshInterval = refreshInterval
    }
}

public enum LinuxSettingsError: Error, Equatable, LocalizedError {
    case unsupportedSchema(Int)
    case documentTooLarge

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): "Unsupported Linux settings schema \(version)"
        case .documentTooLarge: "Linux settings document exceeds the size limit"
        }
    }
}

/// Versioned, secret-free settings document stored under XDG_CONFIG_HOME.
public struct LinuxSettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var providerOrder: [LinuxProviderInstanceID]
    public var providerInstances: [LinuxProviderInstanceSettings]
    public var refreshInterval: LinuxRefreshInterval
    public var appearance: LinuxAppearance
    public var launchAtLogin: Bool
    /// Default-on anonymous analytics preference. Missing values from older schema-v1 files remain on.
    public var analyticsEnabled: Bool

    public init(
        providerOrder: [LinuxProviderInstanceID] = [],
        providerInstances: [LinuxProviderInstanceSettings] = [],
        refreshInterval: LinuxRefreshInterval = .fiveMinutes,
        appearance: LinuxAppearance = .system,
        launchAtLogin: Bool = false,
        analyticsEnabled: Bool = true
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.providerOrder = Self.uniqued(providerOrder)
        self.providerInstances = Self.uniquedSettings(providerInstances)
        self.refreshInterval = refreshInterval
        self.appearance = appearance
        self.launchAtLogin = launchAtLogin
        self.analyticsEnabled = analyticsEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, providerOrder, providerInstances, refreshInterval, appearance, launchAtLogin
        case analyticsEnabled
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard version <= Self.currentSchemaVersion else { throw LinuxSettingsError.unsupportedSchema(version) }
        schemaVersion = Self.currentSchemaVersion
        providerOrder = Self.uniqued(try values.decodeIfPresent([LinuxProviderInstanceID].self, forKey: .providerOrder) ?? [])
        providerInstances = Self.uniquedSettings(
            try values.decodeIfPresent([LinuxProviderInstanceSettings].self, forKey: .providerInstances) ?? []
        )
        refreshInterval = try values.decodeIfPresent(LinuxRefreshInterval.self, forKey: .refreshInterval) ?? .fiveMinutes
        appearance = try values.decodeIfPresent(LinuxAppearance.self, forKey: .appearance) ?? .system
        launchAtLogin = try values.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        analyticsEnabled = try values.decodeIfPresent(Bool.self, forKey: .analyticsEnabled) ?? true
    }

    public static func decode(_ data: Data) throws -> LinuxSettings {
        try JSONDecoder().decode(LinuxSettings.self, from: data)
    }

    /// Adds newly discovered instances without deleting temporarily unavailable accounts or moving
    /// existing cards. This keeps account-level customization stable across sign-out and discovery.
    public mutating func reconcileProviderInstances(_ available: [LinuxProviderInstanceID]) {
        let known = Set(providerOrder)
        providerOrder.append(contentsOf: Self.uniqued(available).filter { !known.contains($0) })
    }

    public func orderedProviderInstances(from available: [LinuxProviderInstanceID]) -> [LinuxProviderInstanceID] {
        let uniqueAvailable = Self.uniqued(available)
        let availableSet = Set(uniqueAvailable)
        let persisted = providerOrder.filter { availableSet.contains($0) }
        let persistedSet = Set(persisted)
        return persisted + uniqueAvailable.filter { !persistedSet.contains($0) }
    }

    public mutating func moveProviderInstance(
        _ instance: LinuxProviderInstanceID,
        before destination: LinuxProviderInstanceID?
    ) {
        providerOrder.removeAll { $0 == instance }
        if let destination, let index = providerOrder.firstIndex(of: destination) {
            providerOrder.insert(instance, at: index)
        } else {
            providerOrder.append(instance)
        }
    }

    public func settings(for instance: LinuxProviderInstanceID) -> LinuxProviderInstanceSettings {
        providerInstances.first { $0.instance == instance } ?? LinuxProviderInstanceSettings(instance: instance)
    }

    public mutating func setVisible(_ visible: Bool, for instance: LinuxProviderInstanceID) {
        update(instance) { $0.isVisible = visible }
    }

    public mutating func setCustomLabel(_ label: String?, for instance: LinuxProviderInstanceID) {
        let normalized = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        update(instance) { $0.customLabel = normalized?.isEmpty == false ? normalized : nil }
    }

    public mutating func setRefreshInterval(
        _ interval: LinuxRefreshInterval?,
        for instance: LinuxProviderInstanceID
    ) {
        update(instance) { $0.refreshInterval = interval }
    }

    public func effectiveRefreshInterval(for instance: LinuxProviderInstanceID) -> LinuxRefreshInterval {
        settings(for: instance).refreshInterval ?? refreshInterval
    }

    private mutating func update(
        _ instance: LinuxProviderInstanceID,
        change: (inout LinuxProviderInstanceSettings) -> Void
    ) {
        if let index = providerInstances.firstIndex(where: { $0.instance == instance }) {
            change(&providerInstances[index])
        } else {
            var value = LinuxProviderInstanceSettings(instance: instance)
            change(&value)
            providerInstances.append(value)
        }
    }

    private static func uniqued(_ values: [LinuxProviderInstanceID]) -> [LinuxProviderInstanceID] {
        var seen: Set<LinuxProviderInstanceID> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static func uniquedSettings(
        _ values: [LinuxProviderInstanceSettings]
    ) -> [LinuxProviderInstanceSettings] {
        var seen: Set<LinuxProviderInstanceID> = []
        return values.filter { seen.insert($0.instance).inserted }
    }
}

/// Storage for a versioned JSON document that is moving away from a path previously shared with
/// another schema. Migration is copy-only: the legacy file remains owned by its original store.
/// Existing destination or legacy bytes must decode before a save can claim or replace the file.
public struct VersionedJSONSettingsStorage: Sendable {
    public static var maximumDocumentBytes: Int { 1_048_576 }

    public let fileURL: URL
    public let legacyFileURL: URL?

    public init(fileURL: URL, legacyFileURL: URL? = nil) {
        self.fileURL = fileURL
        self.legacyFileURL = legacyFileURL
    }

    public func loadMigratingLegacy<Document: Codable>(_ type: Document.Type) throws -> Document? {
        if let document = try decodeIfPresent(type, from: fileURL) {
            return document
        }
        guard let legacyFileURL,
              let document = try decodeIfPresent(type, from: legacyFileURL)
        else {
            return nil
        }
        try write(document)
        return document
    }

    public func save<Document: Codable>(_ document: Document) throws {
        if try decodeIfPresent(Document.self, from: fileURL) == nil,
           let legacyFileURL
        {
            _ = try decodeIfPresent(Document.self, from: legacyFileURL)
        }
        try write(document)
    }

    private func decodeIfPresent<Document: Decodable>(
        _ type: Document.Type,
        from url: URL
    ) throws -> Document? {
        do {
            guard let data = try BoundedProviderFileReader(maximumBytes: Self.maximumDocumentBytes)
                .readIfPresent(url)
            else {
                return nil
            }
            return try JSONDecoder().decode(type, from: data)
        } catch ProviderFileReadError.tooLarge {
            throw LinuxSettingsError.documentTooLarge
        }
    }

    private func write<Document: Encodable>(_ document: Document) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= Self.maximumDocumentBytes else { throw LinuxSettingsError.documentTooLarge }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

public protocol LinuxSettingsStorage: Sendable {
    func load() throws -> LinuxSettings?
    func save(_ settings: LinuxSettings) throws
}

public struct XDGSettingsStorage: LinuxSettingsStorage {
    public static let maximumDocumentBytes = 1_048_576
    public let fileURL: URL

    public init(paths: LinuxPaths = LinuxPaths()) {
        fileURL = paths.configDirectory.appendingPathComponent("settings.json")
    }

    public func load() throws -> LinuxSettings? {
        do {
            guard let data = try BoundedProviderFileReader(maximumBytes: Self.maximumDocumentBytes)
                .readIfPresent(fileURL)
            else {
                return nil
            }
            return try LinuxSettings.decode(data)
        } catch ProviderFileReadError.tooLarge {
            throw LinuxSettingsError.documentTooLarge
        }
    }

    public func save(_ settings: LinuxSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        guard data.count <= Self.maximumDocumentBytes else { throw LinuxSettingsError.documentTooLarge }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
