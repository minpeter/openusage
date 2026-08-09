import Foundation
import Testing
@testable import OpenUsageLinuxCore

@Suite("Linux desktop services")
struct LinuxDesktopServicesTests {
    @Test("Periodic refresh uses only the repository-wide single-flight entry point")
    func periodicRefreshUsesRepositoryBoundary() async {
        let clock = ManualRefreshClock()
        let repository = FakeRefreshRepository()
        let refreshed = AsyncEvent()
        await repository.setEvent(refreshed)
        let service = LinuxPeriodicRefreshService(repository: repository, interval: .seconds(300), clock: clock)

        await service.start()
        async let observed: Void = refreshed.wait()
        clock.tick()
        await observed
        await service.stop()
        clock.tick()

        #expect(await repository.refreshCount == 1)
    }

    @Test("Freedesktop notification uses Notify and returns the daemon identifier")
    func notificationUsesFreedesktopContract() async throws {
        let dbus = FakeDesktopDBus(replies: [[.uint32(42)]])
        let service = FreedesktopNotificationService(dbus: dbus)

        let identifier = try await service.post(.init(title: "Usage warning", body: "Weekly usage reached 80%"))

        #expect(identifier == 42)
        let call = try #require(await dbus.calls.first)
        #expect(call.destination == "org.freedesktop.Notifications")
        #expect(call.member == "Notify")
        #expect(call.arguments.contains(.string("Usage warning")))
    }

    @Test("Portal activation presents the existing window and stop closes the session")
    func globalShortcutPresentsWindow() async throws {
        let dbus = FakeDesktopDBus(replies: [
            [.objectPath("/portal/request/create")], [.objectPath("/portal/request/bind")], []
        ])
        let presented = AsyncEvent()
        let service = XDGGlobalShortcutsService(dbus: dbus) { await presented.send() }

        try await service.start(shortcut: .init(id: "show", description: "Show OpenUsage"))
        async let observed: Void = presented.wait()
        await dbus.emit(.init(
            path: "/org/freedesktop/portal/desktop", interface: "org.freedesktop.portal.GlobalShortcuts",
            member: "Activated", arguments: [.objectPath("/portal/session/1"), .string("show")]
        ))
        await observed
        await service.stop()

        #expect(await dbus.calls.map(\.member) == ["CreateSession", "BindShortcuts", "Close"])
    }

    @Test("systemd user backend writes bounded service metadata and enables it")
    func systemdUserMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = DesktopCommandRecorder(results: [.init(status: 0), .init(status: 0)])
        let backend = SystemdUserLaunchBackend(
            configHome: root,
            executableURL: URL(fileURLWithPath: "/opt/Open Usage/OpenUsageGNOME"),
            systemctlURL: URL(fileURLWithPath: "/bin/true"),
            runner: runner
        )

        try backend.setEnabled(true)

        let unit = try String(contentsOf: backend.unitFileURL, encoding: .utf8)
        #expect(unit.contains("WantedBy=graphical-session.target"))
        #expect(unit.contains("ExecStart=/opt/Open\\x20Usage/OpenUsageGNOME"))
        #expect(runner.commands.map(\.arguments) == [
            ["--user", "daemon-reload"],
            ["--user", "enable", "--now", "io.github.minpeter.OpenUsage.service"],
        ])
        #expect(runner.commands.allSatisfy { $0.timeout == 5 })
    }

    @Test("StatusNotifierItem exports before registration and activation presents the existing window")
    func trayPresentsWindow() async throws {
        let dbus = FakeDesktopDBus(replies: [[]])
        let presented = AsyncEvent()
        let service = StatusNotifierItemService(dbus: dbus) { await presented.send() }

        try await service.start()
        async let observed: Void = presented.wait()
        await dbus.invokeExported(member: "Activate", arguments: [.int32(0), .int32(0)])
        await observed
        await service.stop()

        #expect(await dbus.events.prefix(2) == ["export", "RegisterStatusNotifierItem"])
        #expect(await dbus.lease.cancelCount == 1)
    }
}

private final class DesktopCommandRecorder: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [CommandResult]
    private var recorded: [CommandInvocation] = []
    init(results: [CommandResult]) { self.results = results }
    var commands: [CommandInvocation] { lock.withLock { recorded } }
    func run(_ invocation: CommandInvocation) throws -> CommandResult {
        lock.withLock {
            recorded.append(invocation)
            return results.removeFirst()
        }
    }
}

private actor FakeRefreshRepository: LinuxDesktopRefreshRepository {
    private(set) var refreshCount = 0
    private var event: AsyncEvent?
    func setEvent(_ event: AsyncEvent) { self.event = event }
    func refresh() async -> [ProviderUsageSnapshot] {
        refreshCount += 1
        await event?.send()
        return []
    }
}

private final class ManualRefreshClock: LinuxPeriodicRefreshClock, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<Void>.Continuation?
    func ticks(every interval: Duration) -> AsyncStream<Void> {
        AsyncStream { continuation in lock.withLock { self.continuation = continuation } }
    }
    func tick() { _ = lock.withLock { continuation?.yield(()) } }
}

private actor AsyncEvent {
    private var pending = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if pending { pending = false; return }
        await withCheckedContinuation { waiter = $0 }
    }
    func send() {
        if let waiter { self.waiter = nil; waiter.resume() } else { pending = true }
    }
}

private actor FakeDesktopDBus: LinuxDesktopDBusAdapter {
    private var replies: [[DBusValue]]
    private var signalContinuations: [(DBusSignalMatch, AsyncStream<DBusSignal>.Continuation)] = []
    private var exported: DBusExportedObject?
    let lease = FakeExportLease()
    private(set) var calls: [DBusMethodCall] = []
    private(set) var events: [String] = []

    init(replies: [[DBusValue]]) { self.replies = replies }

    func call(_ call: DBusMethodCall) async throws -> [DBusValue] {
        calls.append(call)
        events.append(call.member)
        let reply = replies.isEmpty ? [] : replies.removeFirst()
        if case .objectPath(let requestPath)? = reply.first, call.member == "CreateSession" || call.member == "BindShortcuts" {
            let results: [String: DBusValue] = call.member == "CreateSession"
                ? ["session_handle": .objectPath("/portal/session/1")] : [:]
            emit(.init(
                path: requestPath, interface: "org.freedesktop.portal.Request", member: "Response",
                arguments: [.uint32(0), .dictionary(results)]
            ))
        }
        return reply
    }

    func signals(matching match: DBusSignalMatch) async throws -> AsyncStream<DBusSignal> {
        AsyncStream { continuation in signalContinuations.append((match, continuation)) }
    }

    func export(_ object: DBusExportedObject) async throws -> any DBusExportLease {
        exported = object
        events.append("export")
        return lease
    }

    func emit(_ signal: DBusSignal) {
        for (match, continuation) in signalContinuations
        where match.interface == signal.interface && match.member == signal.member
            && (match.path == nil || match.path == signal.path) {
            continuation.yield(signal)
        }
    }
    func invokeExported(member: String, arguments: [DBusValue]) async {
        _ = await exported?.handleMethod(member, arguments)
    }
}

private actor FakeExportLease: DBusExportLease {
    private(set) var cancelCount = 0
    func cancel() { cancelCount += 1 }
}
