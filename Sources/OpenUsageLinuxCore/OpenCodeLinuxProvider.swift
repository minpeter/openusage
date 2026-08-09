import Foundation

public struct OpenCodeLinuxPaths: Equatable, Sendable {
    public let dataDirectory: URL
    public var authFile: URL { dataDirectory.appendingPathComponent("auth.json") }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let home = URL(fileURLWithPath: environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path)
        let raw: String
        if let override = environment["OPENCODE_DATA_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            raw = override
        } else if let xdg = environment["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !xdg.isEmpty {
            raw = URL(fileURLWithPath: Self.expandHome(xdg, home: home)).appendingPathComponent("opencode").path
        } else {
            raw = home.appendingPathComponent(".local/share/opencode").path
        }
        dataDirectory = URL(fileURLWithPath: Self.expandHome(raw, home: home)).standardizedFileURL
    }

    public func databaseFiles(fileManager: FileManager = .default) throws -> [URL] {
        let names: [String]
        do { names = try fileManager.contentsOfDirectory(atPath: dataDirectory.path) }
        catch {
            guard fileManager.fileExists(atPath: dataDirectory.path) else { return [] }
            throw OpenCodeLinuxError.databaseUnreadable
        }
        return names.filter { $0.hasPrefix("opencode") && $0.hasSuffix(".db") }.sorted()
            .map { dataDirectory.appendingPathComponent($0) }
    }

    private static func expandHome(_ path: String, home: URL) -> String {
        if path == "~" { return home.path }
        if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))).path }
        return path
    }
}

public enum OpenCodeLinuxError: Error, LocalizedError, Equatable, Sendable {
    case notLoggedIn
    case credentialsUnreadable
    case databaseUnreadable
    case queryTooLarge(maximumBytes: Int)

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            "OpenCode not detected. Log in with OpenCode Go or use OpenCode locally first."
        case .credentialsUnreadable:
            "Couldn't read OpenCode's auth.json. Check its file permissions or log into OpenCode Go again."
        case .databaseUnreadable:
            "Couldn't read OpenCode's local database. Quit OpenCode and refresh, or check the data directory's permissions."
        case .queryTooLarge:
            "OpenCode's local usage query exceeded the safe read limit."
        }
    }
}

public struct OpenCodeLinuxProvider: Sendable {
    public static let links = [ProviderLink(label: "Dashboard", url: "https://opencode.ai/auth")]
    public static let widgets = [
        WidgetDescriptor(id: "opencode.session", title: "Session", metricLabel: "Session"),
        WidgetDescriptor(id: "opencode.weekly", title: "Weekly", metricLabel: "Weekly"),
        WidgetDescriptor(id: "opencode.monthly", title: "Monthly", metricLabel: "Monthly"),
        WidgetDescriptor(id: "opencode.trend", title: "Usage Trend", metricLabel: "Usage Trend"),
        WidgetDescriptor(id: "opencode.today", title: "Today", metricLabel: "Today"),
        WidgetDescriptor(id: "opencode.yesterday", title: "Yesterday", metricLabel: "Yesterday"),
        WidgetDescriptor(id: "opencode.last30", title: "Last 30 Days", metricLabel: "Last 30 Days"),
    ]

    private let paths: OpenCodeLinuxPaths
    private let files: any ProviderFileReading
    private let scanner: OpenCodeLocalScanner
    private let now: @Sendable () -> Date

    public init(
        paths: OpenCodeLinuxPaths = OpenCodeLinuxPaths(),
        files: any ProviderFileReading = BoundedProviderFileReader(),
        scanner: OpenCodeLocalScanner = OpenCodeLocalScanner(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.paths = paths; self.files = files; self.scanner = scanner; self.now = now
    }

    public func hasLocalCredentials() async -> Bool {
        do {
            if try loadAuth() != nil { return true }
        } catch { return true }
        return await scanner.hasHostedUsage()
    }

    public func refresh() async throws -> ProviderUsageSnapshot {
        let refreshedAt = now()
        let auth = try loadAuth()
        guard let scan = try await scanner.scan(now: refreshedAt, hasGoKey: auth != nil) else {
            guard auth != nil else { throw OpenCodeLinuxError.notLoggedIn }
            let windows = OpenCodeGoWindowMath.compute(costs: [], anchorMs: nil, now: refreshedAt)
            return snapshot(plan: "Go", account: auth?.accountLabel,
                            metrics: OpenCodeMetricMapper.capMetrics(windows), at: refreshedAt)
        }

        var metrics: [UsageMetric] = []
        if scan.hasGoSignal {
            let costs = scan.rows.filter { $0.providerID == "opencode-go" }.map { (ms: $0.ms, cost: $0.cost) }
            let windows = OpenCodeGoWindowMath.compute(costs: costs, anchorMs: scan.anchorMs, now: refreshedAt)
            metrics += OpenCodeMetricMapper.capMetrics(windows)
        }
        metrics += OpenCodeMetricMapper.historyMetrics(rows: scan.rows, now: refreshedAt)
        return snapshot(plan: scan.hasGoSignal ? "Go" : nil, account: auth?.accountLabel, metrics: metrics, at: refreshedAt)
    }

    private func snapshot(plan: String?, account: String?, metrics: [UsageMetric], at date: Date) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(providerID: "opencode", displayName: "OpenCode", accountLabel: account,
                              plan: plan, metrics: metrics, links: Self.links, widgets: Self.widgets, refreshedAt: date)
    }

    private struct Auth {
        let key: String
        let accountLabel: String?
    }

    private func loadAuth() throws -> Auth? {
        let data: Data?
        do { data = try files.readIfPresent(paths.authFile) }
        catch { throw OpenCodeLinuxError.credentialsUnreadable }
        guard let data else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenCodeLinuxError.credentialsUnreadable
        }
        guard let entry = root["opencode-go"] as? [String: Any],
              let key = (entry["key"] as? String)?.openCodeTrimmed else { return nil }
        let account = (["email", "account", "username"].lazy.compactMap { (entry[$0] as? String)?.openCodeTrimmed }.first)
        return Auth(key: key, accountLabel: account)
    }
}

private extension String {
    var openCodeTrimmed: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
