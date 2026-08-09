import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(Linux)
import Glibc
#endif
import Testing
@testable import OpenUsageLinuxCore

@Suite("Linux usage API contract")
struct LinuxUsageAPIContractTests {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Usage preserves identity, provider metadata, and every metric shape")
    func usagePreservesCompleteSnapshot() throws {
        let snapshot = ProviderUsageSnapshot(
            providerID: "future-provider",
            instanceID: "future-provider@team",
            displayName: "Future Provider Team",
            accountLabel: "team@example.com",
            plan: "Enterprise",
            metrics: [
                UsageMetric(kind: .progress, label: "Session", used: 25, limit: 100, resetsAt: date, periodDurationMilliseconds: 18_000_000),
                UsageMetric(kind: .values, label: "Today", used: 0, values: [UsageValue(label: "Cost", value: 2.5, unit: .dollars)]),
                UsageMetric(kind: .badge, label: "Status", used: 0, text: "Ready"),
                UsageMetric(kind: .chart, label: "History", used: 0, points: [UsagePoint(date: date, value: 4.2)]),
                UsageMetric(kind: .text, label: "Notice", used: 0, text: "OK"),
            ],
            links: [ProviderLink(label: "Console", url: "https://example.com/console")],
            widgets: [WidgetDescriptor(id: "future-provider@team.session", title: "Session", metricLabel: "Session")],
            refreshedAt: date,
            warning: "cached"
        )
        let state = LinuxUsageAPIState(knownProviderIDs: ["future-provider"], snapshots: [snapshot], generatedAt: date)

        let response = LinuxUsageAPI.respond(method: "GET", path: "/v1/usage/future-provider", state: state)
        #expect(response.status == 200)
        let body = try #require(response.body)
        let array = try #require(JSONSerialization.jsonObject(with: body) as? [[String: Any]])
        let json = try #require(array.first)
        #expect(json["providerId"] as? String == "future-provider")
        #expect(json["instanceId"] as? String == "future-provider@team")
        #expect(json["accountLabel"] as? String == "team@example.com")
        #expect((json["links"] as? [[String: Any]])?.first?["url"] as? String == "https://example.com/console")
        #expect((json["widgets"] as? [[String: Any]])?.first?["id"] as? String == "future-provider@team.session")
        let lines = try #require(json["lines"] as? [[String: Any]])
        #expect(lines.compactMap { $0["type"] as? String } == ["progress", "text", "badge", "barChart", "text"])
        #expect(lines.compactMap { $0["kind"] as? String } == ["progress", "values", "badge", "chart", "text"])
        #expect((lines.first?["format"] as? [String: Any])?["kind"] as? String == "percent")
        #expect((lines[1]["values"] as? [[String: Any]])?.first?["unit"] as? String == "dollars")
    }

    @Test("Selection supports provider families and exact instance IDs without a hardcoded catalog")
    func genericSelection() throws {
        let snapshots = [
            ProviderUsageSnapshot(providerID: "new-adapter", instanceID: "new-adapter@one", displayName: "One", plan: nil, metrics: []),
            ProviderUsageSnapshot(providerID: "new-adapter", instanceID: "new-adapter@two", displayName: "Two", plan: nil, metrics: []),
        ]
        let state = LinuxUsageAPIState(knownProviderIDs: ["new-adapter"], snapshots: snapshots)

        let family = LinuxUsageAPI.respond(method: "GET", path: "/v1/usage/new-adapter", state: state)
        let exact = LinuxUsageAPI.respond(method: "GET", path: "/v1/usage/new-adapter@two", state: state)
        let unknown = LinuxUsageAPI.respond(method: "GET", path: "/v1/usage/nope", state: state)

        let familyBody = try #require(family.body)
        #expect((try JSONSerialization.jsonObject(with: familyBody) as? [Any])?.count == 2)
        let exactBody = try #require(exact.body)
        let exactJSON = try #require(JSONSerialization.jsonObject(with: exactBody) as? [[String: Any]])
        #expect(exactJSON.map { $0["instanceId"] as? String } == ["new-adapter@two"])
        #expect(unknown.status == 404)
        #expect(String(data: try #require(unknown.body), encoding: .utf8) == #"{"error":"provider_not_found"}"#)
    }

    @Test("Limits envelope is stable and keyed by account instance")
    func limitsEnvelope() throws {
        let snapshot = ProviderUsageSnapshot(
            providerID: "new-adapter", instanceID: "new-adapter@one", displayName: "New Adapter",
            accountLabel: "one", plan: "Pro",
            metrics: [UsageMetric(kind: .progress, label: "Weekly", used: 30, limit: 100, resetsAt: date)],
            widgets: [WidgetDescriptor(id: "new-adapter@one.weekly", title: "Weekly", metricLabel: "Weekly")],
            refreshedAt: date
        )
        let response = LinuxUsageAPI.respond(method: "GET", path: "/v1/limits", state: LinuxUsageAPIState(knownProviderIDs: ["new-adapter"], snapshots: [snapshot], generatedAt: date))
        let body = try #require(response.body)
        let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let providers = try #require(root["providers"] as? [String: Any])
        #expect(root["schema"] as? String == "openusage.limits.v1")
        #expect(providers["new-adapter@one"] != nil)
    }

    @Test("Port is configurable by environment and command line")
    func configurablePort() throws {
        #expect(try LinuxAPIArguments.parse([], environment: ["OPENUSAGE_PORT": "7000"]).port == 7000)
        #expect(try LinuxAPIArguments.parse(["--port", "7001"], environment: ["OPENUSAGE_PORT": "7000"]).port == 7001)
        #expect(try LinuxAPIArguments.parse(["--port", "0"], environment: [:]).port == 0)
        #expect(throws: LinuxCLIError.self) {
            try LinuxAPIArguments.parse(["--port", "70000"], environment: [:])
        }
    }

    @Test("Real API binary shuts down cleanly on SIGINT and SIGTERM after serving a request")
    func realBinarySignalShutdown() async throws {
        try await exerciseRealBinary(signal: SIGINT)
        try await exerciseRealBinary(signal: SIGTERM)
    }

    @Test("Loopback server serves JSON and shuts down idempotently")
    func loopbackLifecycle() async throws {
        let server = try LoopbackHTTPServer(port: 0, source: APIFixtureSource())
        try server.start()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/v1/usage")!)
        request.timeoutInterval = 2
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect((try JSONSerialization.jsonObject(with: data) as? [Any])?.count == 1)
        server.stop()
        server.stop()
        server.waitUntilStopped()
    }

    private func exerciseRealBinary(signal: Int32) async throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("openusage-api")
        #expect(FileManager.default.isExecutableFile(atPath: executable.path))

        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--port", "0"]
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

        let readiness = errors.fileHandleForReading.availableData
        let readyText = String(decoding: readiness, as: UTF8.self)
        let portText = readyText.split(separator: ":").last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let port = try #require(portText.flatMap(Int.init))
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/limits")!)
        request.timeoutInterval = 5
        let (body, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(root["schema"] as? String == "openusage.limits.v1")

        #expect(Glibc.kill(process.processIdentifier, signal) == 0)
        process.waitUntilExit()
        let remainingErrors = errors.fileHandleForReading.readDataToEndOfFile()
        let errorText = readyText + String(decoding: remainingErrors, as: UTF8.self)
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 0)
        #expect(!errorText.contains("Signal 4"))
        #expect(!errorText.contains("Illegal instruction"))
        #expect(!errorText.contains("Swift runtime failure"))
    }

    @Test("Router rejects oversized serialized responses")
    func boundedResponse() {
        let huge = String(repeating: "x", count: LinuxUsageAPI.maximumResponseBytes + 1)
        let snapshot = ProviderUsageSnapshot(providerID: "large", displayName: huge, plan: nil, metrics: [])
        let response = LinuxUsageAPI.respond(method: "GET", path: "/v1/usage", state: LinuxUsageAPIState(knownProviderIDs: ["large"], snapshots: [snapshot]))
        #expect(response.status == 503)
        #expect(response.body.map { $0.count < 100 } == true)
    }
}

private actor APIFixtureSource: ProviderSnapshotSource {
    func knownProviderIDs() -> Set<String> { ["fixture"] }
    func snapshots(force: Bool) -> [ProviderUsageSnapshot] {
        [ProviderUsageSnapshot(providerID: "fixture", displayName: "Fixture", plan: nil, metrics: [])]
    }
}
