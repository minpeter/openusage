import Foundation

public struct StatusNotifierItemConfiguration: Equatable, Sendable {
    public let id: String
    public let title: String
    public let iconName: String
    public let tooltip: String

    public init(
        id: String = "openusage",
        title: String = "OpenUsage",
        iconName: String = "io.github.minpeter.OpenUsage",
        tooltip: String = "OpenUsage - AI subscription usage"
    ) {
        self.id = id
        self.title = title
        self.iconName = iconName
        self.tooltip = tooltip
    }
}

/// Exports the StatusNotifierItem object before registering it with the watcher. Activate and
/// SecondaryActivate both present the already-owned dashboard window; this service never creates UI.
public actor StatusNotifierItemService {
    private let dbus: any LinuxDesktopDBusAdapter
    private let presentWindow: @Sendable () async -> Void
    private var exportLease: (any DBusExportLease)?

    public init(dbus: any LinuxDesktopDBusAdapter, presentWindow: @escaping @Sendable () async -> Void) {
        self.dbus = dbus
        self.presentWindow = presentWindow
    }

    public func start(configuration: StatusNotifierItemConfiguration = .init()) async throws {
        guard exportLease == nil else { return }
        let presentWindow = presentWindow
        let object = DBusExportedObject(
            path: "/StatusNotifierItem",
            introspectionXML: Self.introspectionXML,
            properties: [
                "Category": .string("ApplicationStatus"), "Id": .string(configuration.id),
                "Title": .string(configuration.title), "Status": .string("Active"),
                "IconName": .string(configuration.iconName),
                "ToolTip": .structure([.string(configuration.iconName), .array([]), .string(configuration.title), .string(configuration.tooltip)]),
            ],
            propertySignatures: [
                "Category": "s", "Id": "s", "Title": "s", "Status": "s", "IconName": "s",
                "ToolTip": "(sa(iiay)ss)",
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
                arguments: [.string("/StatusNotifierItem")],
                inputSignature: "(s)"
            ))
            exportLease = lease
        } catch {
            await lease.cancel()
            throw error
        }
    }

    public func stop() async {
        let lease = exportLease
        exportLease = nil
        await lease?.cancel()
    }

    public static let introspectionXML = """
    <node><interface name="org.kde.StatusNotifierItem">
      <method name="Activate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
      <method name="SecondaryActivate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
      <property name="Category" type="s" access="read"/><property name="Id" type="s" access="read"/>
      <property name="Title" type="s" access="read"/><property name="Status" type="s" access="read"/>
      <property name="IconName" type="s" access="read"/><property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
    </interface></node>
    """
}
