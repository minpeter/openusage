import Foundation

public struct DevinCredential: Equatable, Sendable {
    public enum Source: String, Equatable, Sendable { case credentialsFile, appState }
    public let apiKey: String
    public let apiServerURL: String?
    public let source: Source

    public init(apiKey: String, apiServerURL: String?, source: Source) {
        self.apiKey = apiKey
        self.apiServerURL = apiServerURL
        self.source = source
    }

    public var effectiveAPIServerURL: String { apiServerURL ?? "https://server.codeium.com" }
    public var instanceID: String { "devin:\(stableProviderIdentity(apiKey))" }
}

public protocol DevinAppStateLoading: Sendable {
    func loadAPIKey(databaseURL: URL, maximumBytes: Int) throws -> String?
}

public struct DevinSQLiteCLIStateLoader: DevinAppStateLoading {
    public init() {}

    public func loadAPIKey(databaseURL: URL, maximumBytes: Int) throws -> String? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "sqlite3", "-readonly", databaseURL.path,
            "SELECT value FROM ItemTable WHERE key = 'windsurfAuthStatus' LIMIT 1;",
        ]
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = try output.fileHandleForReading.read(upToCount: maximumBytes + 1) ?? Data()
        if data.count > maximumBytes {
            process.terminate()
            process.waitUntilExit()
            throw DevinLinuxError.localDataTooLarge
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return devinTrimmed(object["apiKey"] as? String)
    }
}

public struct DevinLinuxCredentialStore: Sendable {
    public static let maximumReadBytes = 512 * 1024
    public let credentialCandidates: [URL]
    public let appStateCandidates: [URL]
    private let appStateLoader: any DevinAppStateLoading

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        appStateLoader: any DevinAppStateLoading = DevinSQLiteCLIStateLoader()
    ) {
        let home = environment["HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let data = environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".local/share")
        let config = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".config")
        credentialCandidates = [
            data.appendingPathComponent("devin/credentials.toml"),
            home.appendingPathComponent(".local/share/devin/credentials.toml"),
        ].uniquedURLs()
        appStateCandidates = [
            config.appendingPathComponent("Devin/User/globalStorage/state.vscdb"),
            config.appendingPathComponent("devin/User/globalStorage/state.vscdb"),
            home.appendingPathComponent(".config/Devin/User/globalStorage/state.vscdb"),
        ].uniquedURLs()
        self.appStateLoader = appStateLoader
    }

    public func loadCredentialsFile() throws -> DevinCredential? {
        for url in credentialCandidates where FileManager.default.fileExists(atPath: url.path) {
            let data = try devinReadBounded(url, maximumBytes: Self.maximumReadBytes)
            guard let text = String(data: data, encoding: .utf8),
                  let key = Self.tomlString(text, key: "windsurf_api_key")
            else { throw DevinLinuxError.invalidCredentials }
            return DevinCredential(
                apiKey: key,
                apiServerURL: Self.cleanServerURL(Self.tomlString(text, key: "api_server_url")),
                source: .credentialsFile
            )
        }
        return nil
    }

    public func loadAppState() throws -> DevinCredential? {
        for url in appStateCandidates where FileManager.default.fileExists(atPath: url.path) {
            if let key = try appStateLoader.loadAPIKey(databaseURL: url, maximumBytes: Self.maximumReadBytes) {
                return DevinCredential(apiKey: key, apiServerURL: nil, source: .appState)
            }
        }
        return nil
    }

    public func loadCredentials() throws -> DevinCredential {
        if let file = try loadCredentialsFile() { return file }
        if let app = try loadAppState() { return app }
        throw DevinLinuxError.notLoggedIn
    }

    public func allCandidates() throws -> [DevinCredential] {
        var result: [DevinCredential] = []
        if let file = try loadCredentialsFile() { result.append(file) }
        if let app = try loadAppState(), !result.contains(where: {
            $0.apiKey == app.apiKey && $0.effectiveAPIServerURL == app.effectiveAPIServerURL
        }) { result.append(app) }
        guard !result.isEmpty else { throw DevinLinuxError.notLoggedIn }
        return result
    }

    public static func cleanServerURL(_ value: String?) -> String? {
        guard var value = devinTrimmed(value), value.hasPrefix("https://") else { return nil }
        while value.last == "/" { value.removeLast() }
        return value.isEmpty ? nil : value
    }

    public static func tomlString(_ text: String, key: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == key
            else { continue }
            var raw = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return nil }
            if let quote = raw.first, quote == "\"" || quote == "'" {
                var escaped = false
                var result = ""
                for character in raw.dropFirst() {
                    if character == quote && !escaped { return devinTrimmed(result) }
                    escaped = character == "\\" && !escaped
                    result.append(character)
                    if character != "\\" { escaped = false }
                }
                return nil
            }
            if let comment = raw.firstIndex(of: "#") { raw = raw[..<comment].trimmingCharacters(in: .whitespacesAndNewlines) }
            return devinTrimmed(String(raw))
        }
        return nil
    }
}

private func devinReadBounded(_ url: URL, maximumBytes: Int) throws -> Data {
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values.isRegularFile == true else { throw DevinLinuxError.invalidCredentials }
    guard (values.fileSize ?? maximumBytes + 1) <= maximumBytes else { throw DevinLinuxError.localDataTooLarge }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
    guard data.count <= maximumBytes else { throw DevinLinuxError.localDataTooLarge }
    return data
}
func devinTrimmed(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    return value
}

private extension Array where Element == URL {
    func uniquedURLs() -> [URL] {
        var seen: Set<String> = []
        return filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
