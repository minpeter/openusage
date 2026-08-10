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

    @Test("Packaged launch at login never writes sandbox-private native entries")
    func packagedLaunchAvoidsSandboxPrivateEntry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = URL(fileURLWithPath: "/app/bin/OpenUsageGNOME")
        let xdg = XDGAutostartBackend(configHome: root, executableURL: executable)
        let requester = RecordingPortalRequester()
        let service = LinuxLaunchAtLoginService(
            portal: FlatpakPortalLaunchBackend(
                requester: requester,
                flatpakDetector: { true }
            ),
            systemd: SystemdUserLaunchBackend(
                configHome: root,
                executableURL: executable,
                systemctlURL: root.appendingPathComponent("missing-systemctl")
            ),
            xdgAutostart: xdg
        )

        try service.setEnabled(true)

        #expect(!FileManager.default.fileExists(atPath: xdg.desktopFileURL.path))
        #expect(requester.updates == [true])

        try service.setEnabled(false)

        #expect(requester.updates == [true, false])
    }

    @Test("Native launch falls back when the portal is unavailable")
    func nativeLaunchFallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = URL(fileURLWithPath: "/opt/OpenUsageGNOME")
        let xdg = XDGAutostartBackend(configHome: root, executableURL: executable)
        let requester = RecordingPortalRequester()
        let service = LinuxLaunchAtLoginService(
            portal: FlatpakPortalLaunchBackend(
                requester: requester,
                flatpakDetector: { false }
            ),
            systemd: SystemdUserLaunchBackend(
                configHome: root,
                executableURL: executable,
                systemctlURL: root.appendingPathComponent("missing-systemctl")
            ),
            xdgAutostart: xdg
        )

        try service.setEnabled(true)

        #expect(FileManager.default.fileExists(atPath: xdg.desktopFileURL.path))
        #expect(requester.updates.isEmpty)
    }

    @Test("StatusNotifierItem exports before registration and activation presents the existing window")
    func trayPresentsWindow() async throws {
        let dbus = FakeDesktopDBus(replies: [[]])
        let presented = AsyncEvent()
        let service = StatusNotifierItemService(dbus: dbus) { await presented.send() }
        let configuration = StatusNotifierItemConfiguration(
            label: "Grok · 36%",
            labelGuide: "GitHub Copilot · 100%"
        )

        try await service.start(configuration: configuration)
        async let observed: Void = presented.wait()
        await dbus.invokeExported(member: "Activate", arguments: [.int32(0), .int32(0)])
        await observed
        await service.stop()

        #expect(await dbus.events.prefix(2) == ["export", "RegisterStatusNotifierItem"])
        let registration = try #require(await dbus.calls.first)
        #expect(registration.arguments == [.string("io.github.minpeter.OpenUsage")])
        #expect(await dbus.exportedProperty("Menu") == .objectPath("/NO_DBUSMENU"))
        #expect(await dbus.exportedProperty("XAyatanaLabel") == .string("Grok · 36%"))
        #expect(await dbus.exportedProperty("XAyatanaLabelGuide") == .string("GitHub Copilot · 100%"))
        #expect(await dbus.lease.cancelCount == 1)
    }

    @Test("StatusNotifierItem updates usage properties without re-registering")
    func trayUpdatesUsageSummary() async throws {
        let dbus = FakeDesktopDBus(replies: [[]])
        let service = StatusNotifierItemService(dbus: dbus) {}
        let updated = StatusNotifierItemConfiguration(
            title: "Claude · 82%",
            label: "Claude · 82%",
            tooltip: "Session · 82% used"
        )

        try await service.start()
        try await service.update(configuration: updated)
        try await service.update(configuration: updated)

        #expect(await dbus.events == [
            "export", "RegisterStatusNotifierItem",
        ])
        #expect(await dbus.lease.cancelCount == 0)
        #expect(await dbus.lease.propertyUpdates == [
            RecordedPropertyUpdate(
                interface: "org.kde.StatusNotifierItem",
                changed: [
                    "Title": .string("Claude · 82%"),
                    "ToolTip": .structure([
                        .string("io.github.minpeter.OpenUsage"), .array([]),
                        .string("Claude · 82%"), .string("Session · 82% used"),
                    ]),
                    "XAyatanaLabel": .string("Claude · 82%"),
                ]
            ),
        ])
        #expect(await dbus.lease.signalEmissions == [
            RecordedSignalEmission(
                signal: DBusSignal(
                    path: "/StatusNotifierItem",
                    interface: "org.kde.StatusNotifierItem",
                    member: "XAyatanaNewLabel",
                    arguments: [.string("Claude · 82%"), .string("GitHub Copilot · 100%")]
                ),
                signature: "(ss)"
            ),
        ])

        await service.stop()
        #expect(await dbus.lease.cancelCount == 1)
    }

    @Test("StatusNotifierItem clears stale usage label while preserving icon fallback")
    func trayClearsUsageLabel() async throws {
        let dbus = FakeDesktopDBus(replies: [[]])
        let service = StatusNotifierItemService(dbus: dbus) {}

        try await service.start(configuration: StatusNotifierItemConfiguration(
            title: "Grok · 36%",
            label: "Grok · 36%",
            tooltip: "Weekly limit · 36% used"
        ))
        try await service.update(configuration: StatusNotifierItemConfiguration(
            label: "",
            tooltip: "No active usage quotas"
        ))

        #expect(await dbus.events == ["export", "RegisterStatusNotifierItem"])
        #expect(await dbus.exportedProperty("IconName") == .string("io.github.minpeter.OpenUsage"))
        #expect(await dbus.lease.propertyUpdates == [
            RecordedPropertyUpdate(
                interface: "org.kde.StatusNotifierItem",
                changed: [
                    "Title": .string("OpenUsage"),
                    "ToolTip": .structure([
                        .string("io.github.minpeter.OpenUsage"), .array([]),
                        .string("OpenUsage"), .string("No active usage quotas"),
                    ]),
                    "XAyatanaLabel": .string(""),
                ]
            ),
        ])
        #expect(await dbus.lease.signalEmissions.last == RecordedSignalEmission(
            signal: DBusSignal(
                path: "/StatusNotifierItem",
                interface: "org.kde.StatusNotifierItem",
                member: "XAyatanaNewLabel",
                arguments: [.string(""), .string("GitHub Copilot · 100%")]
            ),
            signature: "(ss)"
        ))
    }

    @Test("Switching to icon-only updates the live item without re-registering")
    func trayDisplayModeUpdatesInPlace() async throws {
        let dbus = FakeDesktopDBus(replies: [[]])
        let service = StatusNotifierItemService(dbus: dbus) {}
        let snapshots = [
            ProviderUsageSnapshot(
                providerID: "claude",
                instanceID: "claude",
                displayName: "Claude",
                accountLabel: nil,
                plan: nil,
                metrics: [UsageMetric(
                    kind: .progress,
                    label: "Session",
                    used: 82,
                    limit: 100
                )],
                links: [],
                refreshedAt: Date(timeIntervalSince1970: 0)
            ),
        ]

        try await service.start(configuration: .usage(
            snapshots: snapshots,
            displayMode: .mostUrgent
        ))
        try await service.update(configuration: .usage(
            snapshots: snapshots,
            displayMode: .iconOnly
        ))

        #expect(await dbus.events == ["export", "RegisterStatusNotifierItem"])
        #expect(await dbus.lease.propertyUpdates == [
            RecordedPropertyUpdate(
                interface: "org.kde.StatusNotifierItem",
                changed: [
                    "Title": .string("OpenUsage"),
                    "ToolTip": .structure([
                        .string("io.github.minpeter.OpenUsage"), .array([]),
                        .string("OpenUsage"), .string("Claude · Session · 82% used"),
                    ]),
                    "XAyatanaLabel": .string(""),
                ]
            ),
        ])
        #expect(await dbus.lease.signalEmissions.last?.signal.arguments == [
            .string(""), .string("GitHub Copilot · 100%"),
        ])
    }

    @Test("An older tray revision cannot overwrite a newer display selection")
    func trayIgnoresStaleRevision() async throws {
        let dbus = FakeDesktopDBus(replies: [[]])
        let service = StatusNotifierItemService(dbus: dbus) {}
        let visible = StatusNotifierItemConfiguration(
            title: "Claude · 82%",
            label: "Claude · 82%",
            tooltip: "Session · 82% used"
        )
        let iconOnly = StatusNotifierItemConfiguration(
            label: "",
            tooltip: "Claude · Session · 82% used"
        )

        try await service.start(configuration: visible)
        try await service.update(configuration: iconOnly, revision: 2)
        try await service.update(configuration: visible, revision: 1)

        #expect(await dbus.events == ["export", "RegisterStatusNotifierItem"])
        #expect(await dbus.lease.propertyUpdates.count == 1)
        #expect(await dbus.lease.propertyUpdates.first?.changed["XAyatanaLabel"] == .string(""))
        #expect(await dbus.lease.signalEmissions.count == 1)
    }

    @Test("Concurrent tray updates commit in revision order")
    func traySerializesConcurrentRevisions() async throws {
        let dbus = FakeDesktopDBus(replies: [[]])
        let service = StatusNotifierItemService(dbus: dbus) {}
        let initial = StatusNotifierItemConfiguration(
            title: "Initial · 10%",
            label: "Initial · 10%",
            tooltip: "Session · 10% used"
        )
        let older = StatusNotifierItemConfiguration(
            title: "Older · 40%",
            label: "Older · 40%",
            tooltip: "Session · 40% used"
        )
        let newer = StatusNotifierItemConfiguration(
            title: "Newer · 80%",
            label: "Newer · 80%",
            tooltip: "Session · 80% used"
        )

        try await service.start(configuration: initial)
        await dbus.lease.blockNextPropertyUpdate()

        let olderUpdate = Task {
            try await service.update(configuration: older, revision: 1)
        }
        await dbus.lease.waitUntilPropertyUpdateStarts()

        let newerUpdate = Task {
            try await service.update(configuration: newer, revision: 2)
        }
        await service.waitUntilMutationQueueHasWaiter()

        await dbus.lease.releasePropertyUpdate()
        try await olderUpdate.value
        try await newerUpdate.value
        try await service.update(configuration: newer, revision: 3)

        #expect(await dbus.lease.propertyUpdates.compactMap {
            $0.changed["XAyatanaLabel"]
        } == [
            .string("Older · 40%"),
            .string("Newer · 80%"),
        ])
        #expect(await dbus.lease.signalEmissions.map {
            $0.signal.arguments.first
        } == [
            .string("Older · 40%"),
            .string("Newer · 80%"),
        ])
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

private final class RecordingPortalRequester: BackgroundPortalRequesting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Bool] = []
    var updates: [Bool] { lock.withLock { recorded } }

    func setAutostart(_ enabled: Bool) throws -> Bool {
        lock.withLock { recorded.append(enabled) }
        return enabled
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

    func exportedProperty(_ name: String) -> DBusValue? {
        exported?.properties[name]
    }
}

private actor FakeExportLease: DBusExportLease {
    private(set) var cancelCount = 0
    private(set) var propertyUpdates: [RecordedPropertyUpdate] = []
    private(set) var signalEmissions: [RecordedSignalEmission] = []
    private var shouldBlockNextPropertyUpdate = false
    private let propertyUpdateStarted = AsyncEvent()
    private let propertyUpdateRelease = AsyncEvent()

    func blockNextPropertyUpdate() {
        shouldBlockNextPropertyUpdate = true
    }

    func waitUntilPropertyUpdateStarts() async {
        await propertyUpdateStarted.wait()
    }

    func releasePropertyUpdate() async {
        await propertyUpdateRelease.send()
    }

    func updateProperties(interface: String, changed: [String: DBusValue]) async {
        if shouldBlockNextPropertyUpdate {
            shouldBlockNextPropertyUpdate = false
            await propertyUpdateStarted.send()
            await propertyUpdateRelease.wait()
        }
        propertyUpdates.append(.init(interface: interface, changed: changed))
    }

    func emit(_ signal: DBusSignal, signature: String) {
        signalEmissions.append(.init(signal: signal, signature: signature))
    }

    func cancel() { cancelCount += 1 }
}

private struct RecordedPropertyUpdate: Equatable {
    let interface: String
    let changed: [String: DBusValue]
}

private struct RecordedSignalEmission: Equatable {
    let signal: DBusSignal
    let signature: String
}
