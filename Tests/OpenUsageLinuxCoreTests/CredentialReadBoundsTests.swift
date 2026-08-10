import Foundation
import Testing
@testable import OpenUsageLinuxCore

@Suite("Local credential and config read bounds")
struct CredentialReadBoundsTests {
    private let oversizedPadding = String(repeating: "a", count: BoundedProviderFileReader.defaultMaximumBytes + 4096)

    @Test("Claude discovery skips an account whose identity file exceeds the byte bound")
    func claudeDiscoverySkipsOversizeIdentityFile() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let oversize = root.appendingPathComponent(".claude-oversize")
        let control = root.appendingPathComponent(".claude-control")
        try makeClaudeHome(at: oversize, accountID: "oversize-acct", identityPadding: oversizedPadding, credentialPadding: "")
        try makeClaudeHome(at: control, accountID: "control-acct", identityPadding: "", credentialPadding: "")

        // The oversize file is still valid, discoverable JSON; only its size disqualifies it.
        let identityData = try Data(contentsOf: oversize.appendingPathComponent(".claude.json"))
        #expect(identityData.count > BoundedProviderFileReader.defaultMaximumBytes)
        #expect(parityJSON(identityData) != nil)

        let accounts = ClaudeConfigDirDiscovery(paths: LinuxPaths(environment: ["HOME": root.path])).discover()
        #expect(accounts.map(\.identityKey) == ["control-acct"])
    }

    @Test("Claude discovery skips an account whose credential file exceeds the byte bound")
    func claudeDiscoverySkipsOversizeCredentialFile() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let oversize = root.appendingPathComponent(".claude-oversize")
        let control = root.appendingPathComponent(".claude-control")
        try makeClaudeHome(at: oversize, accountID: "oversize-acct", identityPadding: "", credentialPadding: oversizedPadding)
        try makeClaudeHome(at: control, accountID: "control-acct", identityPadding: "", credentialPadding: "")

        let credentialData = try Data(contentsOf: oversize.appendingPathComponent(".credentials.json"))
        #expect(credentialData.count > BoundedProviderFileReader.defaultMaximumBytes)
        #expect(parityJSON(credentialData) != nil)

        let accounts = ClaudeConfigDirDiscovery(paths: LinuxPaths(environment: ["HOME": root.path])).discover()
        #expect(accounts.map(\.identityKey) == ["control-acct"])
    }

    @Test("Copilot load skips an oversize editor file and falls back to gh hosts")
    func copilotOversizeEditorFileFallsBackToGh() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let editorJSON = """
        {"github.com":{"user":"editor-user","oauth_token":"editor-secret"},"pad":"\(oversizedPadding)"}
        """
        try writeText(editorJSON, to: root.appendingPathComponent("github-copilot/apps.json"))
        try writeText("github.com:\n    user: gh-user\n    oauth_token: gh-secret\n",
                      to: root.appendingPathComponent("gh/hosts.yml"))

        // Would win precedence if the oversize file were read.
        #expect(CopilotLinuxCredentialStore.editorCredential(editorJSON)?.token == "editor-secret")

        let credential = try CopilotLinuxCredentialStore(
            environment: ["HOME": "/home/tester", "XDG_CONFIG_HOME": root.path],
            secretReader: { _, _ in nil }
        ).load()
        #expect(credential.token == "gh-secret")
        #expect(credential.accountLabel == "gh-user")
    }

    @Test("Copilot load reports oversize editor files as invalid, not missing")
    func copilotOversizeEditorFileThrowsCredentialsInvalid() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let editorJSON = """
        {"github.com":{"user":"editor-user","oauth_token":"editor-secret"},"pad":"\(oversizedPadding)"}
        """
        try writeText(editorJSON, to: root.appendingPathComponent("github-copilot/hosts.json"))
        #expect(CopilotLinuxCredentialStore.editorCredential(editorJSON)?.token == "editor-secret")

        let store = CopilotLinuxCredentialStore(
            environment: ["HOME": "/home/tester", "XDG_CONFIG_HOME": root.path],
            secretReader: { _, _ in nil }
        )
        #expect(throws: CopilotLinuxError.credentialsInvalid) { try store.load() }
    }

    @Test("Copilot load rejects an oversize gh hosts file")
    func copilotOversizeGhHostsThrowsCredentialsInvalid() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ghText = "github.com:\n    user: gh-user\n    oauth_token: gh-secret\n# \(oversizedPadding)\n"
        try writeText(ghText, to: root.appendingPathComponent("gh/hosts.yml"))

        // Would yield a token if the oversize file were read.
        #expect(CopilotLinuxCredentialStore.yamlValue(ghText, key: "oauth_token") == "gh-secret")

        let store = CopilotLinuxCredentialStore(
            environment: ["HOME": "/home/tester", "XDG_CONFIG_HOME": root.path],
            secretReader: { _, _ in nil }
        )
        #expect(throws: CopilotLinuxError.credentialsInvalid) { try store.load() }
    }

    @Test("Copilot secret command output is capped before it is buffered")
    func copilotCommandOutputBounded() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let big = root.appendingPathComponent("big.bin")
        try Data(repeating: 0x61, count: 256 * 1024).write(to: big)
        let small = root.appendingPathComponent("small.txt")
        try Data("secret-value\n".utf8).write(to: small)

        do {
            _ = try CopilotLinuxCredentialStore.boundedCommandOutput(
                executablePath: "/bin/cat", arguments: [big.path], maximumBytes: 1024
            )
            Issue.record("expected oversize command output to throw")
        } catch let error as CopilotCommandOutputError {
            #expect(error == .tooLarge(path: "/bin/cat", maximumBytes: 1024))
        }

        let data = try CopilotLinuxCredentialStore.boundedCommandOutput(
            executablePath: "/bin/cat", arguments: [small.path], maximumBytes: 1024
        )
        #expect(data == Data("secret-value\n".utf8))
        #expect(try CopilotLinuxCredentialStore.boundedCommandOutput(
            executablePath: "/bin/cat", arguments: [root.appendingPathComponent("missing").path], maximumBytes: 1024
        ) == nil)
        #expect(try CopilotLinuxCredentialStore.boundedCommandOutput(
            executablePath: root.appendingPathComponent("not-a-tool").path, arguments: [], maximumBytes: 1024
        ) == nil)
    }

    @Test("Copilot secret command drains stderr concurrently")
    func copilotCommandDrainsStderr() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = try makeExecutable(
            at: root.appendingPathComponent("large-stderr"),
            contents: """
            #!/bin/sh
            /usr/bin/head -c 262144 /dev/zero >&2
            printf 'secret-value\\n'
            """
        )

        let data = try CopilotLinuxCredentialStore.boundedCommandOutput(
            executablePath: helper.path,
            arguments: [],
            maximumBytes: 512 * 1024,
            timeout: 1
        )
        #expect(data == Data("secret-value\n".utf8))
    }

    @Test("Copilot secret command has a hard process deadline")
    func copilotCommandTimesOut() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = try makeExecutable(
            at: root.appendingPathComponent("never-exits"),
            contents: """
            #!/bin/sh
            while :; do :; done
            """
        )

        #expect(throws: CopilotCommandOutputError.timedOut(path: helper.path)) {
            try CopilotLinuxCredentialStore.boundedCommandOutput(
                executablePath: helper.path,
                arguments: [],
                maximumBytes: 1024,
                timeout: 0.1
            )
        }
    }

    private func makeClaudeHome(at url: URL, accountID: String, identityPadding: String, credentialPadding: String) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let identity = """
        {"oauthAccount":{"accountUuid":"\(accountID)","emailAddress":"dev@example.com"},"pad":"\(identityPadding)"}
        """
        try Data(identity.utf8).write(to: url.appendingPathComponent(".claude.json"))
        let credentials = """
        {"claudeAiOauth":{"accessToken":"token-\(accountID)"},"pad":"\(credentialPadding)"}
        """
        try Data(credentials.utf8).write(to: url.appendingPathComponent(".credentials.json"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeText(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func makeExecutable(at url: URL, contents: String) throws -> URL {
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
