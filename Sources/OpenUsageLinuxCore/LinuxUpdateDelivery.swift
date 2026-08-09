public struct LinuxUpdateDelivery: Equatable, Sendable {
    public enum Channel: String, Sendable {
        case flatpak
        case packageManager
    }

    public let channel: Channel

    public init(environment: [String: String]) {
        channel = environment["FLATPAK_ID"] == nil ? .packageManager : .flatpak
    }

    public var isManaged: Bool {
        true
    }

    public var supportsInApplicationInstall: Bool {
        false
    }

    public var userMessage: String {
        switch channel {
        case .flatpak:
            "Updates are installed by GNOME Software or your Flatpak manager."
        case .packageManager:
            "Updates are installed by your Linux package manager."
        }
    }
}
