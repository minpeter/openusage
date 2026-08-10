internal import CDesktopPortal
import Foundation

public enum FlatpakPortalLaunchError: Error, LocalizedError, Sendable {
    case unavailable
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "Background portal is unavailable"
        case .failed(let message):
            "Background portal failed: \(message)"
        }
    }
}

public protocol BackgroundPortalRequesting: Sendable {
    func setAutostart(_ enabled: Bool) throws -> Bool
}

public struct GIOBackgroundPortalClient: BackgroundPortalRequesting {
    private let timeoutMilliseconds: UInt32

    public init(timeout: Duration = .seconds(15)) {
        let components = timeout.components
        let seconds = max(0, components.seconds)
        let milliseconds = seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
        timeoutMilliseconds = UInt32(clamping: milliseconds)
    }

    public func setAutostart(_ enabled: Bool) throws -> Bool {
        var result = OpenUsagePortalResult(success: 0, autostart: 0, error_message: nil)
        defer { openusage_portal_result_clear(&result) }
        guard openusage_portal_set_autostart(
            enabled ? 1 : 0,
            timeoutMilliseconds,
            &result
        ) != 0 else {
            let message = result.error_message.map { String(cString: $0) } ?? "Unknown portal error"
            throw FlatpakPortalLaunchError.failed(message)
        }
        return result.autostart != 0
    }
}

public final class FlatpakPortalLaunchBackend: LinuxLaunchAtLoginBackend, @unchecked Sendable {
    private let requester: any BackgroundPortalRequesting
    private let flatpakDetector: @Sendable () -> Bool
    private let lock = NSLock()
    private var enabled: Bool

    public init(
        initiallyEnabled: Bool = false,
        requester: any BackgroundPortalRequesting = GIOBackgroundPortalClient(),
        flatpakDetector: @escaping @Sendable () -> Bool = {
            ProcessInfo.processInfo.environment["FLATPAK_ID"] != nil
                || FileManager.default.fileExists(atPath: "/.flatpak-info")
        }
    ) {
        enabled = initiallyEnabled
        self.requester = requester
        self.flatpakDetector = flatpakDetector
    }

    public func isAvailable() -> Bool {
        flatpakDetector()
    }

    public func isEnabled() throws -> Bool {
        lock.withLock { enabled }
    }

    public func setEnabled(_ enabled: Bool) throws {
        let applied = try requester.setAutostart(enabled)
        guard applied == enabled else {
            throw FlatpakPortalLaunchError.failed("Portal returned an unexpected autostart state")
        }
        lock.withLock { self.enabled = enabled }
    }
}
