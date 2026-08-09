import Foundation
import Testing
@testable import OpenUsageLinuxCore

@Suite("Antigravity and OpenCode Linux parity")
struct AntigravityOpenCodeParityTests {
    private let now = Self.date("2026-07-12T12:00:00Z")

    @Test("Linux provider paths honor XDG and explicit overrides")
    func linuxPaths() {
        let environment = [
            "HOME": "/home/tester",
            "XDG_CONFIG_HOME": "/xdg/config",
            "XDG_DATA_HOME": "/xdg/data",
            "ANTIGRAVITY_CREDENTIALS_PATH": "/secrets/antigravity.json",
            "OPENCODE_DATA_DIR": "/var/lib/opencode/",
        ]

        #expect(AntigravityLinuxPaths(environment: environment).credentialCandidates.map(\.path) == [
            "/secrets/antigravity.json",
            "/xdg/data/agy/auth.json",
            "/xdg/config/agy/auth.json",
            "/home/tester/.local/share/agy/auth.json",
            "/home/tester/.config/agy/auth.json",
        ])
        let openCode = OpenCodeLinuxPaths(environment: environment)
        #expect(openCode.dataDirectory.path == "/var/lib/opencode")
        #expect(openCode.authFile.path == "/var/lib/opencode/auth.json")
    }

    @Test("Provider file reader rejects oversized credentials before loading them")
    func boundedFileRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("auth.json")
        try Data(repeating: 0x61, count: 9).write(to: file)

        let reader = BoundedProviderFileReader(maximumBytes: 8)
        #expect(throws: ProviderFileReadError.tooLarge(path: file.path, maximumBytes: 8)) {
            try reader.read(file)
        }
    }

    @Test("Antigravity exact summary fixture maps four pools and account identity")
    func antigravitySummaryParity() async throws {
        let paths = AntigravityLinuxPaths(environment: [
            "HOME": "/home/tester",
            "XDG_DATA_HOME": "/xdg/data",
            "ANTIGRAVITY_CREDENTIALS_PATH": "/secrets/antigravity.json",
        ])
        let credential = """
        {"token":{"access_token":"ya29.test","refresh_token":"1//refresh","expiry":"2099-01-01T00:00:00Z","id_token":"\(Self.jwt(email: "dev@example.com"))"}}
        """
        let summary = """
        {"groups":[
          {"buckets":[
            {"bucketId":"3p-weekly","remainingFraction":1,"resetTime":"2026-07-13T00:00:00Z"},
            {"bucketId":"3p-5h","remainingFraction":0.4,"resetTime":"2026-07-12T15:30:00Z"}]},
          {"buckets":[
            {"bucketId":"gemini-5h","remainingFraction":0.75,"resetTime":"2026-07-12T16:00:00Z"},
            {"bucketId":"gemini-weekly","remainingFraction":0.9,"resetTime":"2026-07-13T00:00:00Z"}]}
        ]}
        """
        let provider = AntigravityLinuxProvider(
            paths: paths,
            files: MemoryProviderFiles(["/secrets/antigravity.json": Data(credential.utf8)]),
            client: AntigravityFixtureClient(summary: Data(summary.utf8), plan: "Google AI Pro"),
            now: { Self.date("2026-07-12T12:00:00Z") }
        )

        let snapshot = try await provider.refresh()

        #expect(snapshot.providerID == "antigravity")
        #expect(snapshot.accountLabel == "dev@example.com")
        #expect(snapshot.plan == "Pro")
        #expect(snapshot.metrics.map { $0.label } == ["Session", "Weekly", "Claude", "Claude Weekly"])
        #expect(snapshot.metrics.map { $0.used } == [25, 10, 60, 0])
        #expect(snapshot.metrics.allSatisfy { $0.limit == 100 })
        #expect(snapshot.widgets.map { $0.id } == [
            "antigravity.geminiPro", "antigravity.geminiWeekly",
            "antigravity.claude", "antigravity.claudeWeekly",
        ])
    }

    @Test("Antigravity malformed credential and missing credential remain typed")
    func antigravityTypedErrors() async {
        let paths = AntigravityLinuxPaths(environment: [
            "HOME": "/home/tester", "ANTIGRAVITY_CREDENTIALS_PATH": "/auth.json",
        ])
        let missing = AntigravityLinuxProvider(
            paths: paths, files: MemoryProviderFiles(), client: AntigravityFixtureClient(summary: Data()), now: { self.now }
        )
        await #expect(throws: AntigravityLinuxError.notSignedIn) { try await missing.refresh() }

        let malformed = AntigravityLinuxProvider(
            paths: paths,
            files: MemoryProviderFiles(["/auth.json": Data("{}".utf8)]),
            client: AntigravityFixtureClient(summary: Data()),
            now: { self.now }
        )
        await #expect(throws: AntigravityLinuxError.invalidCredentialData) { try await malformed.refresh() }
    }

    @Test("OpenCode exact local rows produce Go caps, spend tiles, trend, links, and identity")
    func openCodeLocalParity() async throws {
        let paths = OpenCodeLinuxPaths(environment: [
            "HOME": "/home/tester", "XDG_DATA_HOME": "/xdg/data",
        ])
        let auth = #"{"opencode-go":{"type":"api","key":"sk-test","email":"go@example.com"}}"#
        let rowJSON = "[" + [
            Self.row("2026-07-12T11:00:00Z", 2, 1_000, "glm-5.2", "opencode-go"),
            Self.row("2026-07-12T10:00:00Z", 1, 500, "gpt-5.5", "opencode"),
            Self.row("2026-07-11T10:00:00Z", 3, 2_000, "kimi-k2.6", "opencode-go"),
        ].joined(separator: ",") + "]"
        let rows = Data(rowJSON.utf8)
        let sqlite = OpenCodeFixtureSQLite(
            values: ["/xdg/data/opencode/opencode.db": rows],
            anchors: ["/xdg/data/opencode/opencode.db": String(Self.date("2026-03-05T09:30:00Z").timeIntervalSince1970 * 1000)]
        )
        let provider = OpenCodeLinuxProvider(
            paths: paths,
            files: MemoryProviderFiles([paths.authFile.path: Data(auth.utf8)]),
            scanner: OpenCodeLocalScanner(
                sqlite: sqlite,
                databasePaths: { [URL(fileURLWithPath: "/xdg/data/opencode/opencode.db")] }
            ),
            now: { Self.date("2026-07-12T12:00:00Z") }
        )

        let snapshot = try await provider.refresh()

        #expect(snapshot.plan == "Go")
        #expect(snapshot.accountLabel == "go@example.com")
        #expect(snapshot.metrics.map { $0.label } == [
            "Session", "Weekly", "Monthly", "Today", "Yesterday", "Last 30 Days", "Usage Trend",
        ])
        #expect(snapshot.metrics[0].used == 2)
        #expect(snapshot.metrics[0].limit == 12)
        #expect(snapshot.metrics[1].used == 5)
        #expect(snapshot.metrics[1].limit == 30)
        #expect(snapshot.metrics[2].used == 5)
        #expect(snapshot.metrics[2].limit == 60)
        #expect(snapshot.metrics[3].values == [
            UsageValue(label: "Cost", value: 3, unit: .dollars),
            UsageValue(label: "Tokens", value: 1_500, unit: .tokens),
        ])
        #expect(snapshot.metrics[4].values?.last?.value == 2_000)
        #expect(snapshot.metrics[5].values?.first?.value == 6)
        #expect(snapshot.metrics[6].points?.count == 31)
        #expect(snapshot.links == [ProviderLink(label: "Dashboard", url: "https://opencode.ai/auth")])
        #expect(snapshot.widgets.map { $0.id } == [
            "opencode.session", "opencode.weekly", "opencode.monthly", "opencode.trend",
            "opencode.today", "opencode.yesterday", "opencode.last30",
        ])
    }

    @Test("OpenCode scans every release database and preserves typed read failures")
    func openCodeDatabaseParity() async throws {
        let next = "/data/opencode-next.db"
        let stable = "/data/opencode.db"
        let scanner = OpenCodeLocalScanner(
            sqlite: OpenCodeFixtureSQLite(
                values: [next: Data("[]".utf8)],
                failures: [stable]
            ),
            databasePaths: { [URL(fileURLWithPath: stable), URL(fileURLWithPath: next)] }
        )
        let partial = try await scanner.scan(now: now, hasGoKey: false)
        #expect(partial != nil)

        let failed = OpenCodeLocalScanner(
            sqlite: OpenCodeFixtureSQLite(failures: [stable, next]),
            databasePaths: { [URL(fileURLWithPath: stable), URL(fileURLWithPath: next)] }
        )
        await #expect(throws: OpenCodeLinuxError.databaseUnreadable) {
            try await failed.scan(now: self.now, hasGoKey: false)
        }
    }

    @Test("OpenCode absent footprint and unreadable auth are distinct typed errors")
    func openCodeTypedErrors() async {
        let paths = OpenCodeLinuxPaths(environment: ["HOME": "/home/tester", "OPENCODE_DATA_DIR": "/oc"])
        let scanner = OpenCodeLocalScanner(sqlite: OpenCodeFixtureSQLite(), databasePaths: { [] })
        let absent = OpenCodeLinuxProvider(paths: paths, files: MemoryProviderFiles(), scanner: scanner, now: { self.now })
        await #expect(throws: OpenCodeLinuxError.notLoggedIn) { try await absent.refresh() }

        let malformed = OpenCodeLinuxProvider(
            paths: paths,
            files: MemoryProviderFiles([paths.authFile.path: Data("not json".utf8)]),
            scanner: scanner,
            now: { self.now }
        )
        await #expect(throws: OpenCodeLinuxError.credentialsUnreadable) { try await malformed.refresh() }
    }

    private static func row(_ iso: String, _ cost: Double, _ tokens: Int, _ model: String, _ provider: String) -> String {
        "[\(date(iso).timeIntervalSince1970 * 1000),\(cost),\(tokens),\"\(model)\",\"\(provider)\"]"
    }

    private static func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private static func jwt(email: String) -> String {
        let payload = Data("{\"email\":\"\(email)\"}".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "e30.\(payload).signature"
    }
}

private struct MemoryProviderFiles: ProviderFileReading {
    let files: [String: Data]
    init(_ files: [String: Data] = [:]) { self.files = files }
    func readIfPresent(_ url: URL) throws -> Data? { files[url.path] }
}

private struct AntigravityFixtureClient: AntigravityUsageFetching {
    let summary: Data
    let plan: String?
    init(summary: Data, plan: String? = nil) { self.summary = summary; self.plan = plan }
    func fetch(accessToken: String) async throws -> AntigravityUsagePayload {
        AntigravityUsagePayload(summary: summary, plan: plan)
    }
}

private struct OpenCodeFixtureSQLite: OpenCodeSQLiteAccessing {
    let values: [String: Data]
    let anchors: [String: String]
    let failures: Set<String>

    init(values: [String: Data] = [:], anchors: [String: String] = [:], failures: Set<String> = []) {
        self.values = values; self.anchors = anchors; self.failures = failures
    }

    func query(path: URL, sql: String, maximumBytes: Int) throws -> Data? {
        if failures.contains(path.path) { throw OpenCodeLinuxError.databaseUnreadable }
        if sql.contains("json_group_array") { return values[path.path] }
        if sql.contains("MIN(time_created)"), let anchor = anchors[path.path] { return Data(anchor.utf8) }
        return nil
    }
}
