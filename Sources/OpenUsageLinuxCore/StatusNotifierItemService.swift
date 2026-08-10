import Foundation

public struct StatusNotifierItemConfiguration: Equatable, Sendable {
    public let serviceName: String
    public let id: String
    public let title: String
    public let label: String
    public let labelGuide: String
    public let iconName: String
    public let tooltip: String

    public init(
        serviceName: String = "io.github.minpeter.OpenUsage",
        id: String = "openusage",
        title: String = "OpenUsage",
        label: String = "",
        labelGuide: String = "GitHub Copilot · 100%",
        iconName: String = "io.github.minpeter.OpenUsage",
        tooltip: String = "OpenUsage - AI subscription usage"
    ) {
        self.serviceName = serviceName
        self.id = id
        self.title = title
        self.label = label
        self.labelGuide = labelGuide
        self.iconName = iconName
        self.tooltip = tooltip
    }
}

/// Exports the StatusNotifierItem object before registering it with the watcher. Activate and
/// SecondaryActivate both present the already-owned dashboard window; this service never creates UI.
public actor StatusNotifierItemService {
    private static let interfaceName = "org.kde.StatusNotifierItem"
    private static let objectPath = "/StatusNotifierItem"

    private let dbus: any LinuxDesktopDBusAdapter
    private let presentWindow: @Sendable () async -> Void
    private var exportLease: (any DBusExportLease)?
    private var configuration: StatusNotifierItemConfiguration?
    private var latestUpdateRevision: UInt64?
    private let mutationGate = StatusNotifierItemMutationGate()

    public init(dbus: any LinuxDesktopDBusAdapter, presentWindow: @escaping @Sendable () async -> Void) {
        self.dbus = dbus
        self.presentWindow = presentWindow
    }

    public func start(configuration: StatusNotifierItemConfiguration = .init()) async throws {
        await mutationGate.acquire()
        do {
            try await startWithMutationPermit(configuration: configuration)
        } catch {
            await mutationGate.release()
            throw error
        }
        await mutationGate.release()
    }

    private func startWithMutationPermit(configuration: StatusNotifierItemConfiguration) async throws {
        guard exportLease == nil else { return }
        let presentWindow = presentWindow
        let object = DBusExportedObject(
            path: Self.objectPath,
            introspectionXML: Self.introspectionXML,
            properties: Self.properties(for: configuration),
            propertySignatures: [
                "Category": "s", "Id": "s", "Title": "s", "Status": "s", "IconName": "s",
                "Menu": "o", "ToolTip": "(sa(iiay)ss)", "XAyatanaLabel": "s", "XAyatanaLabelGuide": "s",
            ],
            handleMethod: { member, _ in
                if member == "Activate" || member == "SecondaryActivate" { await presentWindow() }
                return []
            }
        )
        let lease = try await dbus.export(object)
        do {
            _ = try await dbus.call(DBusMethodCall(
                destination: "org.kde.StatusNotifierWatcher",
                path: "/StatusNotifierWatcher",
                interface: "org.kde.StatusNotifierWatcher",
                member: "RegisterStatusNotifierItem",
                arguments: [.string(configuration.serviceName)],
                inputSignature: "(s)"
            ))
            exportLease = lease
            self.configuration = configuration
        } catch {
            await lease.cancel()
            throw error
        }
    }

    public func update(configuration: StatusNotifierItemConfiguration) async throws {
        await mutationGate.acquire()
        do {
            try await apply(configuration: configuration)
        } catch {
            await mutationGate.release()
            throw error
        }
        await mutationGate.release()
    }

    public func update(
        configuration: StatusNotifierItemConfiguration,
        revision: UInt64
    ) async throws {
        await mutationGate.acquire()
        if let latestUpdateRevision, revision < latestUpdateRevision {
            await mutationGate.release()
            return
        }
        latestUpdateRevision = revision
        do {
            try await apply(configuration: configuration)
        } catch {
            await mutationGate.release()
            throw error
        }
        await mutationGate.release()
    }

    private func apply(configuration: StatusNotifierItemConfiguration) async throws {
        guard self.configuration != configuration else { return }
        guard let current = self.configuration, let lease = exportLease else {
            try await startWithMutationPermit(configuration: configuration)
            return
        }
        if current.serviceName != configuration.serviceName {
            exportLease = nil
            self.configuration = nil
            await lease.cancel()
            try await startWithMutationPermit(configuration: configuration)
            return
        }

        let changed = Self.changedProperties(from: current, to: configuration)
        try await lease.updateProperties(interface: Self.interfaceName, changed: changed)
        if current.label != configuration.label || current.labelGuide != configuration.labelGuide {
            try await lease.emit(
                DBusSignal(
                    path: Self.objectPath,
                    interface: Self.interfaceName,
                    member: "XAyatanaNewLabel",
                    arguments: [.string(configuration.label), .string(configuration.labelGuide)]
                ),
                signature: "(ss)"
            )
        }
        self.configuration = configuration
    }

    public func stop() async {
        await mutationGate.acquire()
        let lease = exportLease
        exportLease = nil
        configuration = nil
        latestUpdateRevision = nil
        await lease?.cancel()
        await mutationGate.release()
    }

    func waitUntilMutationQueueHasWaiter() async {
        await mutationGate.waitUntilQueued(count: 1)
    }

    public static let introspectionXML = """
    <node><interface name="org.kde.StatusNotifierItem">
      <method name="Activate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
      <method name="SecondaryActivate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
      <signal name="XAyatanaNewLabel"><arg type="s"/><arg type="s"/></signal>
      <property name="Category" type="s" access="read"/><property name="Id" type="s" access="read"/>
      <property name="Title" type="s" access="read"/><property name="Status" type="s" access="read"/>
      <property name="IconName" type="s" access="read"/><property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
      <property name="Menu" type="o" access="read"/>
      <property name="XAyatanaLabel" type="s" access="read"/>
      <property name="XAyatanaLabelGuide" type="s" access="read"/>
    </interface></node>
    """

    private static func properties(for configuration: StatusNotifierItemConfiguration) -> [String: DBusValue] {
        [
            "Category": .string("ApplicationStatus"),
            "Id": .string(configuration.id),
            "Title": .string(configuration.title),
            "Status": .string("Active"),
            "IconName": .string(configuration.iconName),
            "Menu": .objectPath("/NO_DBUSMENU"),
            "ToolTip": .structure([
                .string(configuration.iconName), .array([]),
                .string(configuration.title), .string(configuration.tooltip),
            ]),
            "XAyatanaLabel": .string(configuration.label),
            "XAyatanaLabelGuide": .string(configuration.labelGuide),
        ]
    }

    private static func changedProperties(
        from current: StatusNotifierItemConfiguration,
        to updated: StatusNotifierItemConfiguration
    ) -> [String: DBusValue] {
        let currentProperties = properties(for: current)
        return properties(for: updated).filter { currentProperties[$0.key] != $0.value }
    }
}

private actor StatusNotifierItemMutationGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var queueObservers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            resumeSatisfiedObservers()
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isHeld = false
            return
        }
        waiters.removeFirst().resume()
    }

    func waitUntilQueued(count: Int) async {
        guard waiters.count < count else { return }
        await withCheckedContinuation { continuation in
            queueObservers.append((count, continuation))
        }
    }

    private func resumeSatisfiedObservers() {
        var pending: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for observer in queueObservers {
            if waiters.count >= observer.count {
                observer.continuation.resume()
            } else {
                pending.append(observer)
            }
        }
        queueObservers = pending
    }
}
