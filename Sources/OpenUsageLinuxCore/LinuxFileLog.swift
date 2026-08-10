import Foundation
import Glibc

public enum LinuxLogLevel: String, Codable, CaseIterable, Sendable {
    case error
    case warn
    case info
    case debug

    public init(persistedValue: String?) {
        self = persistedValue
            .flatMap { Self(rawValue: $0.lowercased()) }
            ?? .info
    }

    public var label: String {
        switch self {
        case .error: "Error"
        case .warn: "Warning"
        case .info: "Info"
        case .debug: "Debug"
        }
    }

    fileprivate var severity: Int {
        switch self {
        case .error: 0
        case .warn: 1
        case .info: 2
        case .debug: 3
        }
    }
}

public struct LinuxLogPaths: Equatable, Sendable {
    public let directory: URL

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let home = environment["HOME"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser
        let stateRoot = environment["XDG_STATE_HOME"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? home.appendingPathComponent(".local/state", isDirectory: true)
        directory = stateRoot.appendingPathComponent("openusage", isDirectory: true)
    }

    public var file: URL {
        directory.appendingPathComponent("openusage.log")
    }
}

public final class LinuxFileLogger: @unchecked Sendable {
    public static let defaultMaximumBytes = 10_000_000

    private let file: URL
    private let lock = NSLock()
    private let maximumBytes: Int
    private var level: LinuxLogLevel

    public init(
        file: URL = LinuxLogPaths().file,
        level: LinuxLogLevel = .info,
        maximumBytes: Int = LinuxFileLogger.defaultMaximumBytes
    ) {
        self.file = file
        self.level = level
        self.maximumBytes = max(1, maximumBytes)
    }

    public func setLevel(_ level: LinuxLogLevel) {
        lock.withLock {
            self.level = level
        }
    }

    public func write(
        _ lineLevel: LinuxLogLevel,
        _ message: String,
        at date: Date = Date()
    ) throws {
        try lock.withLock {
            guard lineLevel.severity <= level.severity else { return }
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let timestamp = ISO8601DateFormatter().string(from: date)
            let normalized = message
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            var data = Data(
                "\(timestamp) [\(lineLevel.rawValue.uppercased())] \(normalized)\n".utf8
            )
            if data.count > maximumBytes {
                data = Data(data.prefix(maximumBytes))
                data[data.index(before: data.endIndex)] = 0x0A
            }
            try rotateIfNeeded(incomingBytes: data.count)
            let descriptor = file.path.withCString {
                Glibc.open(
                    $0,
                    O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC,
                    mode_t(0o600)
                )
            }
            guard descriptor >= 0 else { throw Self.posixError(path: file.path) }
            defer { _ = Glibc.close(descriptor) }
            guard Glibc.fchmod(descriptor, mode_t(0o600)) == 0 else {
                throw Self.posixError(path: file.path)
            }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Glibc.write(
                        descriptor,
                        bytes.baseAddress?.advanced(by: offset),
                        bytes.count - offset
                    )
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else {
                        throw Self.posixError(path: file.path)
                    }
                    offset += count
                }
            }
        }
    }

    private func rotateIfNeeded(incomingBytes: Int) throws {
        guard let size = (
            try? FileManager.default.attributesOfItem(atPath: file.path)[.size]
        ) as? NSNumber,
            size.intValue + incomingBytes > maximumBytes
        else {
            return
        }
        let archive = file.deletingPathExtension()
            .appendingPathExtension("1.log")
        if FileManager.default.fileExists(atPath: archive.path) {
            try FileManager.default.removeItem(at: archive)
        }
        try FileManager.default.moveItem(at: file, to: archive)
    }

    private static func posixError(path: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSFilePathErrorKey: path]
        )
    }
}
