import Foundation
import Testing
@testable import OpenUsageLinuxCore

@Suite("Credential file security")
struct CredentialFileSecurityTests {
    @Test("Claude credential replacement remains private")
    func claudeReplacementPermissions() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("claude")
        let path = config.appendingPathComponent(".credentials.json")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try Data(#"{"claudeAiOauth":{"accessToken":"old"}}"#.utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)

        try LinuxCredentialStore().saveClaude(
            ClaudeCredentials(accessToken: "fresh"),
            configDirectory: config
        )

        #expect(try permissions(path) == 0o600)
    }

    @Test("New Codex credential files are private")
    func codexFirstWritePermissions() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = LinuxPaths(environment: ["HOME": root.path])

        try LinuxCredentialStore(paths: paths).saveCodex(
            CodexCredentials(
                accessToken: "fresh",
                refreshToken: "refresh",
                idToken: nil,
                accountID: nil,
                apiKey: nil
            )
        )

        #expect(try permissions(paths.codexAuthCandidates[0]) == 0o600)
    }

    @Test("Refreshed token cache rejects unsafe permissions")
    func cacheRejectsUnsafePermissions() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("antigravity-token.json")
        let cache = AntigravityRefreshedTokenCache(path: path)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        await cache.store(
            AntigravityTokenRefresh(accessToken: "fresh", expiresIn: 3600),
            sourceRefreshToken: "refresh",
            now: now
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)

        #expect(await cache.load(sourceRefreshToken: "refresh", now: now) == nil)
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }

    @Test("Claude save rejects oversized existing credentials")
    func claudeSaveRejectsOversizedDocument() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("claude")
        let path = config.appendingPathComponent(".credentials.json")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 1_048_577).write(to: path)

        #expect(throws: LinuxUsageError.invalidCredentials("Claude")) {
            try LinuxCredentialStore().saveClaude(
                ClaudeCredentials(accessToken: "fresh"),
                configDirectory: config
            )
        }
        #expect(try FileManager.default.attributesOfItem(atPath: path.path)[.size] as? NSNumber == 1_048_577)
    }

    @Test("Codex save rejects oversized existing credentials")
    func codexSaveRejectsOversizedDocument() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = LinuxPaths(environment: ["HOME": root.path])
        let path = paths.codexAuthCandidates[0]
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: 1_048_577).write(to: path)

        #expect(throws: LinuxUsageError.invalidCredentials("Codex")) {
            try LinuxCredentialStore(paths: paths).saveCodex(
                CodexCredentials(
                    accessToken: "fresh",
                    refreshToken: nil,
                    idToken: nil,
                    accountID: nil,
                    apiKey: nil
                )
            )
        }
        #expect(try FileManager.default.attributesOfItem(atPath: path.path)[.size] as? NSNumber == 1_048_577)
    }

    private func permissions(_ path: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func temporaryDirectory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }
}
