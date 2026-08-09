import Foundation

public struct LinuxGlobalShortcut: Equatable, Sendable {
    public let id: String
    public let description: String
    public let preferredTrigger: String?

    public init(id: String = "present-window", description: String = "Show OpenUsage", preferredTrigger: String? = nil) {
        self.id = id
        self.description = description
        self.preferredTrigger = preferredTrigger
    }
}

/// Owns one GlobalShortcuts portal session. `stop()` closes the portal session and cancels signal
/// consumption, so tests and app shutdown never leave an unbounded listener behind.
public actor XDGGlobalShortcutsService {
    private let dbus: any LinuxDesktopDBusAdapter
    private let presentWindow: @Sendable () async -> Void
    private var sessionPath: String?
    private var signalTask: Task<Void, Never>?

    public init(dbus: any LinuxDesktopDBusAdapter, presentWindow: @escaping @Sendable () async -> Void) {
        self.dbus = dbus
        self.presentWindow = presentWindow
    }

    public func start(shortcut: LinuxGlobalShortcut = LinuxGlobalShortcut()) async throws {
        guard sessionPath == nil else { return }
        let token = "openusage_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let createResults = try await portalRequest(
            member: "CreateSession",
            arguments: [.dictionary(["session_handle_token": .variant(.string(token))])],
            signature: "(a{sv})"
        )
        guard case .objectPath(let path)? = createResults["session_handle"]?.unwrapped else {
            throw LinuxDesktopDBusError.invalidReply("CreateSession")
        }

        var options: [String: DBusValue] = ["description": .variant(.string(shortcut.description))]
        if let trigger = shortcut.preferredTrigger {
            options["preferred_trigger"] = .variant(.string(trigger))
        }
        // Subscribe before binding so an activation immediately following the successful portal
        // response cannot be lost.
        let signals = try await dbus.signals(matching: DBusSignalMatch(
            sender: "org.freedesktop.portal.Desktop",
            path: "/org/freedesktop/portal/desktop",
            interface: "org.freedesktop.portal.GlobalShortcuts",
            member: "Activated"
        ))
        _ = try await portalRequest(
            member: "BindShortcuts",
            arguments: [
                .objectPath(path), .array([.structure([.string(shortcut.id), .dictionary(options)])]),
                .string(""), .dictionary([:]),
            ],
            signature: "(oa(sa{sv})sa{sv})"
        )
        sessionPath = path
        let presentWindow = presentWindow
        signalTask = Task {
            for await signal in signals {
                guard !Task.isCancelled,
                      case .objectPath(let activatedSession)? = signal.arguments.first,
                      case .string(let activatedID)? = signal.arguments.dropFirst().first,
                      activatedSession == path, activatedID == shortcut.id else { continue }
                await presentWindow()
            }
        }
    }

    private func portalRequest(
        member: String,
        arguments: [DBusValue],
        signature: String
    ) async throws -> [String: DBusValue] {
        let responses = try await dbus.signals(matching: DBusSignalMatch(
            sender: "org.freedesktop.portal.Desktop",
            interface: "org.freedesktop.portal.Request",
            member: "Response"
        ))
        let reply = try await dbus.call(DBusMethodCall(
            destination: "org.freedesktop.portal.Desktop",
            path: "/org/freedesktop/portal/desktop",
            interface: "org.freedesktop.portal.GlobalShortcuts",
            member: member,
            arguments: arguments,
            inputSignature: signature
        ))
        guard case .objectPath(let requestPath)? = reply.first else {
            throw LinuxDesktopDBusError.invalidReply(member)
        }
        return try await withThrowingTaskGroup(of: [String: DBusValue].self) { group in
            group.addTask {
                for await response in responses where response.path == requestPath {
                    guard case .uint32(0)? = response.arguments.first,
                          case .dictionary(let results)? = response.arguments.dropFirst().first else {
                        throw LinuxDesktopDBusError.invalidReply(member)
                    }
                    return results
                }
                throw LinuxDesktopDBusError.unavailable("portal response")
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw LinuxDesktopDBusError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw LinuxDesktopDBusError.timedOut }
            return result
        }
    }

    public func stop() async {
        signalTask?.cancel()
        signalTask = nil
        guard let path = sessionPath else { return }
        sessionPath = nil
        _ = try? await dbus.call(DBusMethodCall(
            destination: "org.freedesktop.portal.Desktop",
            path: path,
            interface: "org.freedesktop.portal.Session",
            member: "Close"
        ))
    }
}

private extension DBusValue {
    var unwrapped: DBusValue {
        if case .variant(let value) = self { return value.unwrapped }
        return self
    }
}
