import Foundation
import Testing
@testable import OpenUsageLinuxCore

@Suite("Freedesktop Secret Service")
struct LinuxSecretServiceTests {
    @Test("Credential keys distinguish every provider account instance")
    func credentialKeysAreInstanceScoped() throws {
        let runner = RecordingCommandRunner(results: [
            CommandResult(status: 0),
            CommandResult(status: 0, standardOutput: Data("account-secret\n".utf8)),
            CommandResult(status: 0),
        ])
        let service = SecretToolService(runner: runner, executableURL: URL(fileURLWithPath: "/fake/secret-tool"))
        let backend = SecretServiceCredentialBackend(service: service)
        let personal = LinuxCredentialKey(
            instance: LinuxProviderInstanceID(providerID: "openrouter"),
            kind: "api-key"
        )
        let team = LinuxCredentialKey(
            instance: LinuxProviderInstanceID(providerID: "openrouter", accountInstanceID: "team-v2"),
            kind: "api-key"
        )
        let secret = Data("account-secret".utf8)

        try backend.store(secret, for: team)
        #expect(try backend.load(for: team) == secret)
        try backend.remove(team)

        let commands = runner.commands
        #expect(commands.count == 3)
        #expect(commands[0].arguments.first == "store")
        #expect(commands[0].standardInput == secret)
        #expect(!commands[0].arguments.contains("account-secret"))
        #expect(commands[0].arguments.contains("openrouter:team-v2"))
        #expect(commands[1].arguments.first == "lookup")
        #expect(commands[2].arguments.first == "clear")
        #expect(service.attributes(for: personal) != service.attributes(for: team))
    }

    @Test("Secret command errors never expose command output or secret input")
    func failuresDoNotExposeSecrets() {
        let secret = "do-not-log-this"
        let runner = RecordingCommandRunner(results: [
            CommandResult(status: 7, standardError: Data("daemon repeated do-not-log-this".utf8))
        ])
        let backend = SecretServiceCredentialBackend(service: SecretToolService(
            runner: runner,
            executableURL: URL(fileURLWithPath: "/fake/secret-tool")
        ))
        let key = LinuxCredentialKey(instance: .init(providerID: "zai"), kind: "api-key")

        do {
            try backend.store(Data(secret.utf8), for: key)
            Issue.record("Expected Secret Service failure")
        } catch {
            #expect(!String(describing: error).contains(secret))
            #expect(!error.localizedDescription.contains(secret))
        }
    }

    @Test("A deterministic fake backend follows the typed credential contract")
    func typedBackendSupportsFakes() throws {
        let fake: any LinuxCredentialBackend = MemoryCredentialBackend()
        let key = LinuxCredentialKey(
            instance: .init(providerID: "claude", accountInstanceID: "stable-account-42"),
            kind: "oauth"
        )
        try fake.store(Data("token".utf8), for: key)
        #expect(try fake.load(for: key) == Data("token".utf8))
        try fake.remove(key)
        #expect(try fake.load(for: key) == nil)
    }
}

@Suite("Linux launch at login")
struct LinuxLaunchAtLoginTests {
    @Test("Launch service prefers systemd and uses XDG fallback when unavailable")
    func backendSelectionIsDeterministic() throws {
        let systemd = FakeLaunchBackend(available: false)
        let xdg = FakeLaunchBackend(available: true)
        let service = LinuxLaunchAtLoginService(systemd: systemd, xdgAutostart: xdg)

        try service.setEnabled(true)

        #expect(systemd.updates.isEmpty)
        #expect(xdg.updates == [true])
        #expect(try service.isEnabled())
    }

    @Test("XDG autostart writes a safely escaped desktop entry and removes it on disable")
    func xdgAutostartRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = XDGAutostartBackend(
            configHome: root,
            executableURL: URL(fileURLWithPath: "/opt/Open Usage/bin/openusage")
        )

        try backend.setEnabled(true)
        #expect(try backend.isEnabled())
        let entry = try String(contentsOf: backend.desktopFileURL, encoding: .utf8)
        #expect(entry.contains("Exec=\"/opt/Open Usage/bin/openusage\""))
        #expect(entry.contains("X-GNOME-Autostart-enabled=true"))

        try backend.setEnabled(false)
        #expect(!(try backend.isEnabled()))
    }
}

private final class RecordingCommandRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [CommandResult]
    private(set) var commands: [CommandInvocation] = []

    init(results: [CommandResult]) { queued = results }

    func run(_ invocation: CommandInvocation) throws -> CommandResult {
        lock.lock()
        defer { lock.unlock() }
        commands.append(invocation)
        return queued.removeFirst()
    }
}

private final class MemoryCredentialBackend: LinuxCredentialBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [LinuxCredentialKey: Data] = [:]

    func load(for key: LinuxCredentialKey) throws -> Data? {
        lock.withLock { values[key] }
    }

    func store(_ secret: Data, for key: LinuxCredentialKey) throws {
        lock.withLock { values[key] = secret }
    }

    func remove(_ key: LinuxCredentialKey) throws {
        _ = lock.withLock { values.removeValue(forKey: key) }
    }
}

private final class FakeLaunchBackend: LinuxLaunchAtLoginBackend, @unchecked Sendable {
    let available: Bool
    var updates: [Bool] = []

    init(available: Bool) { self.available = available }
    func isAvailable() -> Bool { available }
    func isEnabled() throws -> Bool { updates.last ?? false }
    func setEnabled(_ enabled: Bool) throws { updates.append(enabled) }
}
