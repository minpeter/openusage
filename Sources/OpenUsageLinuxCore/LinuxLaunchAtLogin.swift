import Foundation
import Glibc

public struct CommandInvocation: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let standardInput: Data?
    public let timeout: TimeInterval

    public init(executableURL: URL, arguments: [String], standardInput: Data? = nil, timeout: TimeInterval = 5) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.standardInput = standardInput
        self.timeout = timeout
    }
}

public struct CommandResult: Equatable, Sendable {
    public let status: Int32
    public let standardOutput: Data
    public let standardError: Data

    public init(status: Int32, standardOutput: Data = Data(), standardError: Data = Data()) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public protocol CommandRunning: Sendable {
    func run(_ invocation: CommandInvocation) throws -> CommandResult
}

public enum LinuxDesktopCommandError: Error, LocalizedError, Sendable {
    case timedOut
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .timedOut: "Desktop command timed out"
        case .failed(let command): "Desktop command failed: \(command)"
        }
    }
}

/// Process adapter with a hard lifetime bound. Output is drained concurrently so a child cannot block
/// forever on a full pipe before the timeout is enforced.
public struct BoundedCommandRunner: CommandRunning {
    public init() {}

    public func run(_ invocation: CommandInvocation) throws -> CommandResult {
        let process = Process()
        let stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.standardOutput = stdout
        process.standardError = stderr
        if invocation.standardInput != nil { process.standardInput = stdin }
        let terminated = DispatchSemaphore(value: 0)
        let drains = DispatchGroup()
        let output = CommandOutputBox(), errors = CommandOutputBox()
        process.terminationHandler = { _ in terminated.signal() }
        drains.enter()
        DispatchQueue.global().async {
            output.set(stdout.fileHandleForReading.readDataToEndOfFile())
            drains.leave()
        }
        drains.enter()
        DispatchQueue.global().async {
            errors.set(stderr.fileHandleForReading.readDataToEndOfFile())
            drains.leave()
        }
        try process.run()
        if let input = invocation.standardInput {
            DispatchQueue.global().async {
                stdin.fileHandleForWriting.write(input)
                try? stdin.fileHandleForWriting.close()
            }
        }
        guard terminated.wait(timeout: .now() + invocation.timeout) == .success else {
            process.terminate()
            if terminated.wait(timeout: .now() + 1) != .success {
                _ = Glibc.kill(process.processIdentifier, SIGKILL)
                _ = terminated.wait(timeout: .now() + 1)
            }
            _ = drains.wait(timeout: .now() + 1)
            throw LinuxDesktopCommandError.timedOut
        }
        _ = drains.wait(timeout: .now() + 1)
        return CommandResult(
            status: process.terminationStatus,
            standardOutput: output.value,
            standardError: errors.value
        )
    }
}

private final class CommandOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    var value: Data { lock.withLock { data } }
    func set(_ value: Data) { lock.withLock { data = value } }
}

public protocol LinuxLaunchAtLoginBackend: Sendable {
    func isAvailable() -> Bool
    func isEnabled() throws -> Bool
    func setEnabled(_ enabled: Bool) throws
}

public struct LinuxLaunchAtLoginService: Sendable {
    private let portal: (any LinuxLaunchAtLoginBackend)?
    private let systemd: any LinuxLaunchAtLoginBackend
    private let xdgAutostart: any LinuxLaunchAtLoginBackend

    public init(
        portal: (any LinuxLaunchAtLoginBackend)? = nil,
        systemd: any LinuxLaunchAtLoginBackend,
        xdgAutostart: any LinuxLaunchAtLoginBackend
    ) {
        self.portal = portal
        self.systemd = systemd
        self.xdgAutostart = xdgAutostart
    }

    public func isEnabled() throws -> Bool {
        try selectedBackend().isEnabled()
    }

    public func setEnabled(_ enabled: Bool) throws {
        try selectedBackend().setEnabled(enabled)
    }

    private func selectedBackend() -> any LinuxLaunchAtLoginBackend {
        if let portal, portal.isAvailable() { return portal }
        return systemd.isAvailable() ? systemd : xdgAutostart
    }
}

public final class XDGAutostartBackend: LinuxLaunchAtLoginBackend, @unchecked Sendable {
    public let desktopFileURL: URL
    private let executableURL: URL
    private let fileManager: FileManager

    public init(configHome: URL, executableURL: URL, fileManager: FileManager = .default) {
        desktopFileURL = configHome.appendingPathComponent("autostart/io.github.minpeter.OpenUsage.desktop")
        self.executableURL = executableURL
        self.fileManager = fileManager
    }

    public func isAvailable() -> Bool { true }
    public func isEnabled() throws -> Bool { fileManager.fileExists(atPath: desktopFileURL.path) }

    public func setEnabled(_ enabled: Bool) throws {
        if !enabled {
            if fileManager.fileExists(atPath: desktopFileURL.path) { try fileManager.removeItem(at: desktopFileURL) }
            return
        }
        try fileManager.createDirectory(at: desktopFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let escaped = Self.desktopExecArgument(executableURL.path)
        let entry = """
        [Desktop Entry]
        Type=Application
        Name=OpenUsage
        Comment=Track AI subscription usage
        Exec=\(escaped)
        Icon=io.github.minpeter.OpenUsage
        Terminal=false
        X-GNOME-Autostart-enabled=true
        StartupNotify=false

        """
        try Data(entry.utf8).write(to: desktopFileURL, options: .atomic)
    }

    private static func desktopExecArgument(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

public final class SystemdUserLaunchBackend: LinuxLaunchAtLoginBackend, @unchecked Sendable {
    public let unitFileURL: URL
    private let executableURL: URL
    private let systemctlURL: URL
    private let runner: any CommandRunning
    private let fileManager: FileManager

    public init(
        configHome: URL,
        executableURL: URL,
        systemctlURL: URL = URL(fileURLWithPath: "/usr/bin/systemctl"),
        runner: any CommandRunning = BoundedCommandRunner(),
        fileManager: FileManager = .default
    ) {
        unitFileURL = configHome.appendingPathComponent("systemd/user/io.github.minpeter.OpenUsage.service")
        self.executableURL = executableURL
        self.systemctlURL = systemctlURL
        self.runner = runner
        self.fileManager = fileManager
    }

    public func isAvailable() -> Bool { fileManager.isExecutableFile(atPath: systemctlURL.path) }

    public func isEnabled() throws -> Bool {
        guard isAvailable() else { return false }
        return try runSystemctl(["--user", "is-enabled", "io.github.minpeter.OpenUsage.service"]).status == 0
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try fileManager.createDirectory(at: unitFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let escaped = Self.systemdEscape(executableURL.path)
            let unit = """
            [Unit]
            Description=OpenUsage desktop usage monitor
            After=graphical-session.target
            PartOf=graphical-session.target

            [Service]
            Type=simple
            ExecStart=\(escaped)
            Restart=on-failure

            [Install]
            WantedBy=graphical-session.target

            """
            try Data(unit.utf8).write(to: unitFileURL, options: .atomic)
            let result = try runSystemctl(["--user", "daemon-reload"])
            guard result.status == 0 else { throw LinuxDesktopCommandError.failed("systemctl daemon-reload") }
            let enable = try runSystemctl(["--user", "enable", "--now", "io.github.minpeter.OpenUsage.service"])
            guard enable.status == 0 else { throw LinuxDesktopCommandError.failed("systemctl enable") }
        } else {
            let result = try runSystemctl(["--user", "disable", "--now", "io.github.minpeter.OpenUsage.service"])
            guard result.status == 0 else { throw LinuxDesktopCommandError.failed("systemctl disable") }
            if fileManager.fileExists(atPath: unitFileURL.path) { try fileManager.removeItem(at: unitFileURL) }
            _ = try runSystemctl(["--user", "daemon-reload"])
        }
    }

    private func runSystemctl(_ arguments: [String]) throws -> CommandResult {
        try runner.run(CommandInvocation(executableURL: systemctlURL, arguments: arguments, timeout: 5))
    }

    private static func systemdEscape(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: " ", with: "\\x20")
    }
}
