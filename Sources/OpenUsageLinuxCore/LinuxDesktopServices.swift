import Foundation

public struct LinuxNotification: Equatable, Sendable {
    public let title: String
    public let body: String
    public let iconName: String
    public let urgency: UInt8

    public init(title: String, body: String, iconName: String = "io.github.minpeter.OpenUsage", urgency: UInt8 = 1) {
        self.title = title
        self.body = body
        self.iconName = iconName
        self.urgency = urgency
    }
}

public struct FreedesktopNotificationService: Sendable {
    private let dbus: any LinuxDesktopDBusAdapter

    public init(dbus: any LinuxDesktopDBusAdapter) { self.dbus = dbus }

    @discardableResult
    public func post(_ notification: LinuxNotification, replacesID: UInt32 = 0) async throws -> UInt32 {
        let reply = try await dbus.call(DBusMethodCall(
            destination: "org.freedesktop.Notifications",
            path: "/org/freedesktop/Notifications",
            interface: "org.freedesktop.Notifications",
            member: "Notify",
            arguments: [
                .string("OpenUsage"), .uint32(replacesID), .string(notification.iconName),
                .string(notification.title), .string(notification.body), .array([]),
                .dictionary(["urgency": .variant(.byte(notification.urgency))]), .int32(-1),
            ],
            inputSignature: "(susssasa{sv}i)"
        ))
        guard case .uint32(let notificationID)? = reply.first else {
            throw LinuxDesktopDBusError.invalidReply("Notify")
        }
        return notificationID
    }
}
