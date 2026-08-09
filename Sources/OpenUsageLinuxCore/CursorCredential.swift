import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CursorLinuxCredential: Equatable, Sendable, CustomStringConvertible {
    public let accessToken: String
    public let refreshToken: String?
    public let accountLabel: String?
    fileprivate let databasePath: String

    public var description: String {
        "CursorLinuxCredential(accountLabel: \(accountLabel ?? "unknown"), accessToken: <redacted>, refreshToken: \(refreshToken == nil ? "none" : "<redacted>"))"
    }
}

public enum CursorLinuxError: Error, LocalizedError, Equatable {
    case credentialsMissing
    case credentialsInvalid
    case notLoggedIn
    case sessionExpired
    case tokenExpired
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)
    case usageAfterRefreshFailed
    case requestBasedUnavailable(String)
    case totalUsageLimitMissing
    case noActiveSubscription

    public var errorDescription: String? {
        switch self {
        case .credentialsMissing, .notLoggedIn:
            "Not logged in. Sign in via Cursor app or run `agent login`."
        case .credentialsInvalid:
            "Cursor credentials could not be read."
        case .sessionExpired:
            "Session expired. Sign in via Cursor app or run `agent login`."
        case .tokenExpired:
            "Token expired. Sign in via Cursor app or run `agent login`."
        case .connectionFailed:
            "Couldn't connect. Check your connection."
        case .invalidResponse:
            "Usage response invalid. Try again later."
        case .requestFailed(let status):
            "Usage request failed (HTTP \(status)). Try again later."
        case .usageAfterRefreshFailed:
            "Usage request failed after refresh. Try again."
        case .requestBasedUnavailable(let message):
            message
        case .totalUsageLimitMissing:
            "Total usage limit missing from API response."
        case .noActiveSubscription:
            "No active Cursor subscription."
        }
    }
}

public struct CursorLinuxCredentialStore: Sendable {
    public typealias StateValueReader = @Sendable (_ databasePath: String, _ key: String) throws -> String?
    public typealias StateValueWriter = @Sendable (_ databasePath: String, _ key: String, _ value: String) throws -> Void

    public let stateDatabaseCandidates: [URL]
    private let stateValue: StateValueReader
    private let writeStateValue: StateValueWriter?

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        stateValue: StateValueReader? = nil,
        writeStateValue: StateValueWriter? = nil
    ) {
        let home = environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let config = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".config", isDirectory: true)
        stateDatabaseCandidates = ["Cursor", "cursor"].map {
            config.appendingPathComponent($0, isDirectory: true)
                .appendingPathComponent("User/globalStorage/state.vscdb")
        }
        self.stateValue = stateValue ?? Self.readSQLiteValue
        self.writeStateValue = writeStateValue ?? Self.writeSQLiteValue
    }

    public func load() throws -> CursorLinuxCredential {
        var foundDatabase = false
        for database in stateDatabaseCandidates {
            if FileManager.default.fileExists(atPath: database.path) { foundDatabase = true }
            do {
                let access = try stateValue(database.path, "cursorAuth/accessToken")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let refresh = try stateValue(database.path, "cursorAuth/refreshToken")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let access, !access.isEmpty {
                    return CursorLinuxCredential(
                        accessToken: access,
                        refreshToken: refresh?.isEmpty == false ? refresh : nil,
                        accountLabel: Self.accountLabel(access),
                        databasePath: database.path
                    )
                }
                if let refresh, !refresh.isEmpty {
                    throw CursorLinuxError.credentialsInvalid
                }
            } catch let error as CursorLinuxError {
                throw error
            } catch {
                if FileManager.default.fileExists(atPath: database.path) {
                    throw CursorLinuxError.credentialsInvalid
                }
            }
        }
        if foundDatabase { throw CursorLinuxError.credentialsInvalid }
        throw CursorLinuxError.credentialsMissing
    }

    public func saveAccessToken(_ token: String, for credential: CursorLinuxCredential) throws {
        guard let writeStateValue else { return }
        try writeStateValue(credential.databasePath, "cursorAuth/accessToken", token)
    }

    public static func accountLabel(_ token: String) -> String? {
        guard let subject = cursorJWTPayload(token)?["sub"] as? String else { return nil }
        let parts = subject.split(separator: "|", omittingEmptySubsequences: false)
        let value = String(parts.count > 1 ? parts[1] : parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func expiration(_ token: String) -> Date? {
        guard let value = cursorCredentialNumber(cursorJWTPayload(token)?["exp"]) else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    private static func readSQLiteValue(_ path: String, _ key: String) throws -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let escaped = key.replacingOccurrences(of: "'", with: "''")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-batch", "-noheader", path, "SELECT value FROM ItemTable WHERE key = '\(escaped)' LIMIT 1;"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CursorLinuxError.credentialsInvalid }
        let value = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func writeSQLiteValue(_ path: String, _ key: String, _ value: String) throws {
        let escapedKey = key.replacingOccurrences(of: "'", with: "''")
        let escapedValue = value.replacingOccurrences(of: "'", with: "''")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-batch", path]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        input.fileHandleForWriting.write(Data("INSERT OR REPLACE INTO ItemTable (key, value) VALUES ('\(escapedKey)', '\(escapedValue)');\n".utf8))
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CursorLinuxError.credentialsInvalid }
    }
}

private func cursorCredentialNumber(_ value: Any?) -> Double? {
    if value is Bool { return nil }
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? String { return Double(value) }
    return nil
}

private func cursorJWTPayload(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count > 1 else { return nil }
    var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
    guard let data = Data(base64Encoded: encoded) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}
