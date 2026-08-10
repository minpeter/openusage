import Foundation
import Testing
@testable import OpenUsageLinuxCore

@Suite("Linux file logging")
struct LinuxFileLogTests {
    @Test("XDG state path and log level persist only permitted lines")
    func levelGatesPrivateFileLog() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = LinuxLogPaths(environment: [
            "HOME": root.appendingPathComponent("home").path,
            "XDG_STATE_HOME": root.appendingPathComponent("state").path,
        ]).file
        let logger = LinuxFileLogger(file: file, level: .info)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        try logger.write(.debug, "hidden-debug", at: now)
        try logger.write(.info, "visible-info", at: now)
        try logger.write(.error, "visible-error", at: now)
        logger.setLevel(.debug)
        try logger.write(.debug, "visible-debug", at: now)

        let text = try String(contentsOf: file, encoding: .utf8)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(!text.contains("hidden-debug"))
        #expect(text.contains("[INFO] visible-info"))
        #expect(text.contains("[ERROR] visible-error"))
        #expect(text.contains("[DEBUG] visible-debug"))
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("Invalid persisted levels fall back to Info")
    func invalidLevelFallsBackToInfo() {
        #expect(LinuxLogLevel(persistedValue: "trace") == .info)
        #expect(LinuxLogLevel(persistedValue: "ERROR") == .error)
        #expect(LinuxLogLevel(persistedValue: nil) == .info)
    }

    @Test("File log rotates to one bounded archive")
    func rotatesBoundedArchive() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("openusage.log")
        let logger = LinuxFileLogger(
            file: file,
            level: .debug,
            maximumBytes: 120
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        try logger.write(.info, String(repeating: "a", count: 40), at: now)
        try logger.write(.info, String(repeating: "b", count: 40), at: now)
        try logger.write(.info, String(repeating: "c", count: 40), at: now)

        let currentSize = try #require(
            (FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue
        )
        let archive = file.deletingPathExtension()
            .appendingPathExtension("1.log")
        let archiveSize = try #require(
            (FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?.intValue
        )
        #expect(currentSize <= 120)
        #expect(archiveSize <= 120)
    }
}
