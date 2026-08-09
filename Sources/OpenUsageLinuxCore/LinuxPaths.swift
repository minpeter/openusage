import Foundation

public struct LinuxPaths: Equatable, Sendable {
    public let homeDirectory: URL
    public let configDirectory: URL
    public let cacheDirectory: URL
    public let claudeCredentials: URL
    public let codexAuthCandidates: [URL]
    public let claudeConfigDirectories: [URL]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let home = environment["HOME"].flatMap(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser
        let configRoot = environment["XDG_CONFIG_HOME"].flatMap(URL.init(fileURLWithPath:))
            ?? home.appendingPathComponent(".config", isDirectory: true)
        let cacheRoot = environment["XDG_CACHE_HOME"].flatMap(URL.init(fileURLWithPath:))
            ?? home.appendingPathComponent(".cache", isDirectory: true)

        homeDirectory = home
        configDirectory = configRoot.appendingPathComponent("openusage", isDirectory: true)
        cacheDirectory = cacheRoot.appendingPathComponent("openusage", isDirectory: true)
        let claudeDefaults = [
            configRoot.appendingPathComponent("claude", isDirectory: true),
            home.appendingPathComponent(".claude", isDirectory: true),
        ]
        let configuredClaude = environment["CLAUDE_CONFIG_DIR"]?.split(separator: ",").map {
            Self.expandTilde(String($0).trimmingCharacters(in: .whitespaces), home: home)
        }.filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0, isDirectory: true) }
        claudeConfigDirectories = configuredClaude?.isEmpty == false ? configuredClaude! : claudeDefaults
        claudeCredentials = claudeConfigDirectories.last!
            .appendingPathComponent(".credentials.json")
        let codexHome = environment["CODEX_HOME"].map { Self.expandTilde($0, home: home) }
        codexAuthCandidates = codexHome.map { [URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("auth.json")] } ?? [
            configRoot
                .appendingPathComponent("codex", isDirectory: true)
                .appendingPathComponent("auth.json"),
            home
                .appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent("auth.json"),
        ]
    }

    private static func expandTilde(_ path: String, home: URL) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return home.path + String(path.dropFirst())
    }

    public func prepareStorage(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    public var snapshotCache: URL {
        cacheDirectory.appendingPathComponent("snapshots.json")
    }
}
