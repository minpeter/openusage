import Foundation
#if os(Linux)
import Glibc
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CopilotLinuxCredential: Equatable, Sendable, CustomStringConvertible {
    public let token: String
    public let accountLabel: String?

    public var description: String {
        "CopilotLinuxCredential(accountLabel: \(accountLabel ?? "unknown"), token: <redacted>)"
    }
}

public enum CopilotLinuxError: Error, LocalizedError, Equatable {
    case credentialsMissing
    case credentialsInvalid
    case tokenInvalid
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)
    case quotaUnavailable

    public var errorDescription: String? {
        switch self {
        case .credentialsMissing:
            "Sign in to GitHub Copilot in your editor, or run gh auth login, and try again."
        case .credentialsInvalid:
            "GitHub Copilot credentials could not be read."
        case .tokenInvalid:
            "GitHub token invalid or expired. Re-authenticate (gh auth login) and try again."
        case .connectionFailed:
            "Couldn't reach GitHub. Check your connection."
        case .invalidResponse:
            "Copilot usage response invalid. Try again later."
        case .requestFailed(let status):
            "Copilot usage request failed (HTTP \(status)). Try again later."
        case .quotaUnavailable:
            "Copilot usage data is unavailable for this account."
        }
    }
}

enum CopilotCommandOutputError: Error, Equatable {
    case tooLarge(path: String, maximumBytes: Int)
    case timedOut(path: String)
}

public struct CopilotLinuxCredentialStore: Sendable {
    public typealias SecretReader = @Sendable (_ service: String, _ account: String?) throws -> String?

    public let editorCandidates: [URL]
    public let ghHosts: URL
    private let secretReader: SecretReader

    public init(environment: [String: String] = ProcessInfo.processInfo.environment, secretReader: SecretReader? = nil) {
        let home = environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let config = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".config", isDirectory: true)
        editorCandidates = ["apps.json", "hosts.json"].map {
            config.appendingPathComponent("github-copilot", isDirectory: true).appendingPathComponent($0)
        }
        ghHosts = config.appendingPathComponent("gh", isDirectory: true).appendingPathComponent("hosts.yml")
        self.secretReader = secretReader ?? Self.readSecretService
    }

    public func load() throws -> CopilotLinuxCredential {
        var malformed = false
        for path in editorCandidates where FileManager.default.fileExists(atPath: path.path) {
            do {
                let text = try Self.readBoundedText(path)
                if let credential = Self.editorCredential(text) { return credential }
                if text.data(using: .utf8).flatMap({ try? JSONSerialization.jsonObject(with: $0) }) == nil {
                    malformed = true
                }
            } catch { malformed = true }
        }

        var ghText: String?
        if FileManager.default.fileExists(atPath: ghHosts.path) {
            do { ghText = try Self.readBoundedText(ghHosts) } catch { malformed = true }
        }
        if let ghText, let token = Self.yamlValue(ghText, key: "oauth_token") {
            return CopilotLinuxCredential(token: token, accountLabel: Self.yamlValue(ghText, key: "user"))
        }
        let account = ghText.flatMap { Self.yamlValue($0, key: "user") }
        do {
            if let raw = try secretReader("gh:github.com", account), let token = unwrapGoKeyring(raw) {
                return CopilotLinuxCredential(token: token, accountLabel: account)
            }
        } catch { malformed = true }
        if malformed { throw CopilotLinuxError.credentialsInvalid }
        throw CopilotLinuxError.credentialsMissing
    }

    public static func editorCredential(_ text: String) -> CopilotLinuxCredential? {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for (host, raw) in root where host == "github.com" || host.hasPrefix("github.com:") {
            guard let value = raw as? [String: Any],
                  let token = (value["oauth_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty else { continue }
            let user = copilotCredentialNonEmpty((value["user"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines))
            return CopilotLinuxCredential(token: token, accountLabel: user)
        }
        return nil
    }

    public static func yamlValue(_ text: String, key: String, host: String = "github.com") -> String? {
        let prefix = key + ":", hostHeader = host + ":"
        var inHost = false
        for line in text.split(whereSeparator: \.isNewline) {
            if let first = line.first, !first.isWhitespace {
                inHost = line.trimmingCharacters(in: .whitespaces).hasPrefix(hostHeader)
                continue
            }
            guard inHost else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(prefix) else { continue }
            let value = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Reads a local credential/config file as UTF-8 text with a hard byte ceiling, so a corrupt
    /// or hostile file cannot force an unbounded allocation before parsing.
    private static func readBoundedText(_ url: URL) throws -> String {
        let data = try BoundedProviderFileReader().read(url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProviderFileReadError.unreadable(path: url.path)
        }
        return text
    }

    private static func readSecretService(_ service: String, _ account: String?) throws -> String? {
        var arguments = ["lookup", "service", service]
        if let account { arguments += ["account", account] }
        guard let data = try boundedCommandOutput(
            executablePath: "/usr/bin/secret-tool",
            arguments: arguments,
            maximumBytes: BoundedProviderFileReader.defaultMaximumBytes
        ) else { return nil }
        return copilotCredentialNonEmpty(String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Runs a local helper command while bounding both its lifetime and pipe output. Stdout and
    /// stderr are drained concurrently; output bytes are never included in errors.
    static func boundedCommandOutput(
        executablePath: String,
        arguments: [String],
        maximumBytes: Int,
        timeout: TimeInterval = 5
    ) throws -> Data? {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let terminated = DispatchSemaphore(value: 0)
        let drains = DispatchGroup()
        let state = CopilotCommandOutputState()
        process.terminationHandler = { _ in terminated.signal() }
        try process.run()

        for (pipe, capturesOutput) in [(stdout, true), (stderr, false)] {
            drains.enter()
            DispatchQueue.global().async {
                defer { drains.leave() }
                let reader = pipe.fileHandleForReading
                while let chunk = try? reader.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    guard state.accept(
                        chunk,
                        capturesOutput: capturesOutput,
                        maximumBytes: maximumBytes,
                        path: executablePath
                    ) else {
                        if process.isRunning { process.terminate() }
                        return
                    }
                }
            }
        }

        let deadline = DispatchTime.now() + timeout
        guard terminated.wait(timeout: deadline) == .success,
              drains.wait(timeout: deadline) == .success else {
            let error = state.error ?? .timedOut(path: executablePath)
            terminate(process)
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
            throw error
        }
        if let error = state.error { throw error }
        guard process.terminationStatus == 0 else { return nil }
        return state.output
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        #if os(Linux)
        _ = Glibc.kill(process.processIdentifier, SIGKILL)
        #endif
    }
}

private final class CopilotCommandOutputState: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderrCount = 0
    private var boundedError: CopilotCommandOutputError?

    var output: Data { lock.withLock { stdout } }
    var error: CopilotCommandOutputError? { lock.withLock { boundedError } }

    func accept(_ data: Data, capturesOutput: Bool, maximumBytes: Int, path: String) -> Bool {
        lock.withLock {
            guard boundedError == nil else { return false }
            let currentCount = capturesOutput ? stdout.count : stderrCount
            guard data.count <= maximumBytes - currentCount else {
                boundedError = .tooLarge(path: path, maximumBytes: maximumBytes)
                return false
            }
            if capturesOutput {
                stdout.append(data)
            } else {
                stderrCount += data.count
            }
            return true
        }
    }
}

private func unwrapGoKeyring(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = "go-keyring-base64:"
    if trimmed.hasPrefix(prefix), let data = Data(base64Encoded: String(trimmed.dropFirst(prefix.count))) {
        return copilotCredentialNonEmpty(String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return copilotCredentialNonEmpty(trimmed)
}

private func copilotCredentialNonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
}
