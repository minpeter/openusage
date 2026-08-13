import Foundation
import Testing
@testable import OpenUsageLinuxCore

@Suite("Linux CLI contract")
struct LinuxCLIContractTests {
    @Test("Arguments match macOS provider, force, help, and version behavior")
    func arguments() throws {
        let parsed = try LinuxCLIArguments.parse(["Future-Provider@Team", "--force"])
        #expect(parsed.providerID == "future-provider@team")
        #expect(parsed.force)
        #expect(try LinuxCLIArguments.parse(["--help"]).showHelp)
        #expect(try LinuxCLIArguments.parse(["-v"]).showVersion)
        #expect(throws: LinuxCLIError.self) { try LinuxCLIArguments.parse(["--json"]) }
        #expect(throws: LinuxCLIError.self) { try LinuxCLIArguments.parse(["one", "two"]) }
    }

    @Test("CLI emits limits JSON selected through an injectable snapshot source")
    func injectableSource() async throws {
        let source = CLIFixtureSource()
        let output = await LinuxCLIRunner.run(arguments: ["future-provider@work", "--force"], source: source, version: "1.2.3")

        #expect(output.exitCode == 0)
        #expect(output.standardError.isEmpty)
        let root = try #require(JSONSerialization.jsonObject(with: output.standardOutput) as? [String: Any])
        let providers = try #require(root["providers"] as? [String: Any])
        #expect(providers.keys.sorted() == ["future-provider@work"])
        #expect(await source.receivedForce())
    }

    @Test("Unknown provider and provider errors use macOS exit semantics")
    func errorSemantics() async {
        let source = CLIFixtureSource()
        let unknown = await LinuxCLIRunner.run(arguments: ["nope"], source: source)
        #expect(unknown.exitCode == 2)
        #expect(String(data: unknown.standardError, encoding: .utf8)?.contains("Unknown provider: nope") == true)

        await source.setFailure(true)
        let warning = await LinuxCLIRunner.run(arguments: [], source: source)
        #expect(warning.exitCode == 4)
        #expect(!warning.standardOutput.isEmpty)
        #expect(String(data: warning.standardError, encoding: .utf8)?.contains("warning:") == true)
    }

    @Test("Real no-argument executable flushes JSON without URLSession teardown warnings")
    func realExecutableLifetime() throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("openusage")
        #expect(FileManager.default.isExecutableFile(atPath: executable.path))

        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let process = Process()
        process.executableURL = executable
        process.environment = [
            "HOME": home.path,
            "XDG_CONFIG_HOME": home.appendingPathComponent("config").path,
            "XDG_CACHE_HOME": home.appendingPathComponent("cache").path,
            "XDG_DATA_HOME": home.appendingPathComponent("data").path,
            "PATH": "/usr/bin:/bin",
        ]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        try process.run()
        process.waitUntilExit()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: stderr, as: UTF8.self)

        #expect(process.terminationStatus == 4)
        let root = try #require(JSONSerialization.jsonObject(with: stdout) as? [String: Any])
        #expect(root["schema"] as? String == "openusage.limits.v1")
        #expect(!errorText.contains("_MultiHandle deallocated"))
        #expect(!errorText.contains("non-zero retain count"))
    }

    @Test("Missing Secret Service exits cleanly without corrupting memory")
    func missingSecretServiceCleanup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("probe.c")
        let executable = root.appendingPathComponent("probe")
        try """
        #include "CSecretService.h"
        int main(void) {
            OpenUsageSecretResult result = {0};
            GError *error = g_error_new_literal(
                G_IO_ERROR,
                G_IO_ERROR_FAILED,
                "expected failure"
            );
            openusage_secret_fail(&result, error, "fallback");
            g_clear_error(&error);
            openusage_secret_result_clear(&result);
            return 0;
        }
        """.write(to: source, atomically: true, encoding: .utf8)

        let flags = try Self.commandOutput(
            executable: "/usr/bin/pkg-config",
            arguments: ["--cflags", "--libs", "gio-2.0", "glib-2.0"])
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        compile.arguments = [
            source.path,
            "-I",
            FileManager.default.currentDirectoryPath
                + "/Sources/CSecretService/include",
            "-o",
            executable.path,
        ] + flags
        try compile.run()
        compile.waitUntilExit()
        #expect(compile.terminationStatus == 0)

        let process = Process()
        process.executableURL = executable
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 0)
    }

    private static func commandOutput(
        executable: String,
        arguments: [String]
    ) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self)
    }

    @Test("Help documents JSON and does not read providers")
    func help() async {
        let source = CLIFixtureSource()
        let output = await LinuxCLIRunner.run(arguments: ["--help"], source: source)
        let text = String(data: output.standardOutput, encoding: .utf8) ?? ""
        #expect(output.exitCode == 0)
        #expect(text.contains("Usage: openusage"))
        #expect(text.contains("Output is always JSON"))
        #expect(await source.loadCount() == 0)
    }
}

private actor CLIFixtureSource: ProviderSnapshotSource {
    private var forced = false
    private var loads = 0
    private var failure = false

    func knownProviderIDs() -> Set<String> { ["future-provider"] }
    func snapshots(force: Bool) -> [ProviderUsageSnapshot] {
        forced = force
        loads += 1
        return [ProviderUsageSnapshot(
            providerID: "future-provider", instanceID: "future-provider@work",
            displayName: "Future Provider", accountLabel: "work", plan: "Pro",
            metrics: [UsageMetric(kind: .progress, label: "Session", used: 10, limit: 100)],
            widgets: [WidgetDescriptor(id: "future-provider@work.session", title: "Session", metricLabel: "Session")],
            errorMessage: failure ? "provider unavailable" : nil
        )]
    }

    func receivedForce() -> Bool { forced }
    func loadCount() -> Int { loads }
    func setFailure(_ value: Bool) { failure = value }
}
