import Foundation
import Testing
@testable import OpenUsageLinuxCore

@Suite("Linux settings service")
struct LinuxSettingsServiceTests {
    @Test("Current providers and arbitrary account instances retain stable order and visibility")
    func providerInstancesRetainOrderAndVisibility() throws {
        #expect(Set(LinuxProviderCatalog.currentProviderIDs) == [
            "antigravity", "claude", "codex", "copilot", "cursor", "devin",
            "grok", "opencode", "openrouter", "pi", "zai",
        ])

        let claude = LinuxProviderInstanceID(providerID: "claude")
        let work = LinuxProviderInstanceID(providerID: "claude", accountInstanceID: "account-work-v1")
        let codex = LinuxProviderInstanceID(providerID: "codex")
        let future = LinuxProviderInstanceID(providerID: "future-provider", accountInstanceID: "opaque-7")
        var settings = LinuxSettings()

        settings.reconcileProviderInstances([claude, work, codex, future])
        settings.moveProviderInstance(future, before: work)
        settings.setVisible(false, for: work)
        settings.setCustomLabel("Work", for: work)
        settings.setRefreshInterval(.fifteenMinutes, for: work)

        #expect(settings.orderedProviderInstances(from: [work, future, codex, claude]) == [claude, future, work, codex])
        #expect(settings.settings(for: claude).isVisible)
        #expect(!settings.settings(for: work).isVisible)
        #expect(settings.settings(for: work).customLabel == "Work")
        #expect(settings.effectiveRefreshInterval(for: work) == .fifteenMinutes)

        let decoded = try JSONDecoder().decode(LinuxSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        #expect(decoded.providerOrder.contains(future))
    }

    @Test("Missing providers retain their slots and newly discovered accounts append")
    func temporarilyMissingInstancesRetainSlots() {
        let personal = LinuxProviderInstanceID(providerID: "claude")
        let work = LinuxProviderInstanceID(providerID: "claude", accountInstanceID: "work")
        let codex = LinuxProviderInstanceID(providerID: "codex")
        var settings = LinuxSettings(providerOrder: [personal, work, codex])

        settings.reconcileProviderInstances([personal, codex])
        #expect(settings.providerOrder == [personal, work, codex])

        let secondCodex = LinuxProviderInstanceID(providerID: "codex", accountInstanceID: "team")
        settings.reconcileProviderInstances([personal, work, codex, secondCodex])
        #expect(settings.providerOrder == [personal, work, codex, secondCodex])
    }

    @Test("XDG store persists appearance, cadence, launch behavior, and account settings")
    func xdgStoreRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = LinuxPaths(environment: [
            "HOME": root.path,
            "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
            "XDG_CACHE_HOME": root.appendingPathComponent("cache").path,
        ])
        let storage = XDGSettingsStorage(paths: paths)
        let account = LinuxProviderInstanceID(providerID: "openrouter", accountInstanceID: "team-primary")
        var expected = LinuxSettings(
            refreshInterval: .thirtyMinutes,
            appearance: .dark,
            launchAtLogin: true
        )
        expected.reconcileProviderInstances([account])
        expected.setVisible(false, for: account)
        expected.setCustomLabel("Team Router", for: account)

        try storage.save(expected)
        let loadedValue = try storage.load()
        let loaded = try #require(loadedValue)

        #expect(loaded == expected)
        #expect(storage.fileURL.path == root.appendingPathComponent("config/openusage/settings.json").path)
        let attributes = try FileManager.default.attributesOfItem(atPath: storage.fileURL.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o077 == 0)
        let persisted = try String(contentsOf: storage.fileURL, encoding: .utf8)
        #expect(!persisted.lowercased().contains("secret"))
    }

    @Test("Unsupported settings schemas fail explicitly")
    func unsupportedSchemaFails() throws {
        let data = Data(#"{"schemaVersion":999}"#.utf8)
        #expect(throws: LinuxSettingsError.unsupportedSchema(999)) {
            try LinuxSettings.decode(data)
        }
    }

    @Test("A versioned store migrates once and persists across production restarts")
    func versionedStoreMigratesAndPersistsAcrossRestarts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacyURL = root.appendingPathComponent("settings.json")
        let destinationURL = root.appendingPathComponent("gnome-settings.json")
        let account = LinuxProviderInstanceID(providerID: "claude", accountInstanceID: "work")
        var original = LinuxSettings(providerOrder: [account], appearance: .dark)
        original.setVisible(false, for: account)
        let legacyBytes = try JSONEncoder().encode(original)
        try legacyBytes.write(to: legacyURL)

        let firstProcess = VersionedJSONSettingsStorage(
            fileURL: destinationURL,
            legacyFileURL: legacyURL
        )
        let migrated = try #require(try firstProcess.loadMigratingLegacy(LinuxSettings.self))
        #expect(migrated == original)
        #expect(try Data(contentsOf: legacyURL) == legacyBytes)

        var changed = migrated
        changed.setCustomLabel("Work", for: account)
        try firstProcess.save(changed)

        let restartedProcess = VersionedJSONSettingsStorage(
            fileURL: destinationURL,
            legacyFileURL: legacyURL
        )
        #expect(try restartedProcess.loadMigratingLegacy(LinuxSettings.self) == changed)
        #expect(try Data(contentsOf: legacyURL) == legacyBytes)
    }

    @Test("An incompatible legacy schema is preserved and never claimed")
    func incompatibleLegacySchemaIsPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacyURL = root.appendingPathComponent("settings.json")
        let destinationURL = root.appendingPathComponent("gnome-settings.json")
        let futureBytes = Data(#"{"schemaVersion":999,"providerInstances":[{"future":true}]}"#.utf8)
        try futureBytes.write(to: legacyURL)
        let storage = VersionedJSONSettingsStorage(
            fileURL: destinationURL,
            legacyFileURL: legacyURL
        )

        #expect(throws: LinuxSettingsError.unsupportedSchema(999)) {
            try storage.loadMigratingLegacy(LinuxSettings.self)
        }
        #expect(throws: LinuxSettingsError.unsupportedSchema(999)) {
            try storage.save(LinuxSettings())
        }
        #expect(try Data(contentsOf: legacyURL) == futureBytes)
        #expect(!FileManager.default.fileExists(atPath: destinationURL.path))
    }

    @Test("Malformed owned documents survive failed loads and saves byte for byte")
    func malformedOwnedDocumentIsPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destinationURL = root.appendingPathComponent("gnome-settings.json")
        let malformedBytes = Data(#"{"schemaVersion":1,"providerOrder":["#.utf8)
        try malformedBytes.write(to: destinationURL)
        let storage = VersionedJSONSettingsStorage(fileURL: destinationURL)

        #expect(throws: (any Error).self) {
            try storage.loadMigratingLegacy(LinuxSettings.self)
        }
        #expect(throws: (any Error).self) {
            try storage.save(LinuxSettings())
        }
        #expect(try Data(contentsOf: destinationURL) == malformedBytes)
    }
}
