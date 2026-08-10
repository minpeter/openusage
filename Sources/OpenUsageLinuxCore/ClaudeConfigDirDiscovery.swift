import Foundation

public struct ClaudeAccount: Equatable, Sendable {
    public let identityKey: String
    public let accountLabel: String?
    public let configDirectory: URL
    public let instanceID: String

    public init(identityKey: String, accountLabel: String?, configDirectory: URL) {
        self.identityKey = identityKey
        self.accountLabel = accountLabel
        self.configDirectory = configDirectory
        self.instanceID = "claude@\(Self.hash8(identityKey))"
    }

    private static func hash8(_ value: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in value.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return String(format: "%08x", UInt32(truncatingIfNeeded: hash))
    }
}

public struct ClaudeConfigDirDiscovery: Sendable {
    public let paths: LinuxPaths
    private let fileManager: FileManager

    public init(paths: LinuxPaths = LinuxPaths(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    /// Finds account-attributable Claude homes only. Identity plus exact credential shape is the gate;
    /// arbitrary project and temporary directories are never searched.
    public func discover() -> [ClaudeAccount] {
        let reader = BoundedProviderFileReader()
        let defaults = Set(paths.claudeConfigDirectories.map(canonical))
        let homeChildren = directories(in: paths.homeDirectory).filter { $0.lastPathComponent.hasPrefix(".") }
        let configChildren = directories(in: paths.homeDirectory.appendingPathComponent(".config"))
        return (homeChildren + configChildren).sorted { $0.path < $1.path }.compactMap { directory in
            guard !defaults.contains(canonical(directory)) else { return nil }
            let identityFile = directory.appendingPathComponent(".claude.json")
            let credentialFile = directory.appendingPathComponent(".credentials.json")
            guard let identityData = try? reader.read(identityFile),
                  let root = try? JSONSerialization.jsonObject(with: identityData) as? [String: Any],
                  let account = root["oauthAccount"] as? [String: Any],
                  let accountID = nonempty(account["accountUuid"] as? String)?.lowercased(),
                  let credentialData = try? reader.read(credentialFile),
                  let credentialRoot = parityJSON(credentialData),
                  let oauth = credentialRoot["claudeAiOauth"] as? [String: Any],
                  nonempty(oauth["accessToken"] as? String) != nil else { return nil }
            let orgID = nonempty(account["organizationUuid"] as? String)?.lowercased()
            let key = orgID.map { "\(accountID)|\($0)" } ?? accountID
            let email = nonempty(account["emailAddress"] as? String)
            let org = nonempty(account["organizationName"] as? String)
            let label: String?
            if let org { label = email.map { "\($0) (\(org))" } ?? org } else { label = email }
            return ClaudeAccount(identityKey: key, accountLabel: label, configDirectory: directory)
        }
    }

    private func directories(in url: URL) -> [URL] {
        (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]))?.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        } ?? []
    }

    private func canonical(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
    private func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
