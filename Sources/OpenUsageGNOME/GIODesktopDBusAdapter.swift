import Adwaita
import Foundation
import OpenUsageLinuxCore

/// Real session-bus adapter used by desktop QA. Service code depends only on
/// `LinuxDesktopDBusAdapter`, so a fake can drive every behavior in tests.
/// Retained callback boxes live in GIODesktopSupport.swift; GVariant value
/// bridging lives in GIOVariantCodec.swift.
final class GIODesktopDBusAdapter: LinuxDesktopDBusAdapter, @unchecked Sendable {
    private let connection: OpaquePointer

    init() throws {
        var error: UnsafeMutablePointer<GError>?
        guard let connection = g_bus_get_sync(G_BUS_TYPE_SESSION, nil, &error) else {
            if let error { g_error_free(error) }
            throw LinuxDesktopDBusError.unavailable("session bus")
        }
        self.connection = connection
    }

    deinit { g_object_unref(UnsafeMutableRawPointer(connection)) }

    func call(_ call: DBusMethodCall) async throws -> [DBusValue] {
        let connection = connection
        return try await Task.detached {
            let parameters = try GIOVariantCodec.makeTuple(call.arguments, signature: call.inputSignature)
            defer { g_variant_unref(parameters) }
            var error: UnsafeMutablePointer<GError>?
            let milliseconds = call.timeout.gioMilliseconds
            let reply = call.destination.withCString { destination in
                call.path.withCString { path in
                    call.interface.withCString { interface in
                        call.member.withCString { member in
                            g_dbus_connection_call_sync(
                                connection, destination, path, interface, member, parameters, nil,
                                GDBusCallFlags(rawValue: 0), milliseconds, nil, &error
                            )
                        }
                    }
                }
            }
            guard let reply else {
                if let error { g_error_free(error) }
                throw LinuxDesktopDBusError.unavailable("\(call.interface).\(call.member)")
            }
            defer { g_variant_unref(reply) }
            return GIOVariantCodec.tupleChildren(reply)
        }.value
    }

    func signals(matching match: DBusSignalMatch) async throws -> AsyncStream<DBusSignal> {
        let connection = connection
        return AsyncStream { continuation in
            let box = SignalContinuationBox(continuation)
            let retained = Unmanaged.passRetained(box).toOpaque()
            let subscription = match.sender.withOptionalCString { sender in
                match.path.withOptionalCString { path in
                    match.interface.withCString { interface in
                        match.member.withCString { member in
                            g_dbus_connection_signal_subscribe(
                                connection, sender, interface, member, path, nil, GDBusSignalFlags(rawValue: 0),
                                gioSignalCallback, retained, gioReleaseBox
                            )
                        }
                    }
                }
            }
            let connectionAddress = UInt(bitPattern: connection)
            continuation.onTermination = { _ in
                guard let connection = OpaquePointer(bitPattern: connectionAddress) else { return }
                g_dbus_connection_signal_unsubscribe(connection, subscription)
            }
        }
    }

    func export(_ object: DBusExportedObject) async throws -> any DBusExportLease {
        var error: UnsafeMutablePointer<GError>?
        guard let node = object.introspectionXML.withCString({ g_dbus_node_info_new_for_xml($0, &error) }),
              let interfaces = node.pointee.interfaces,
              let interface = interfaces.pointee
        else {
            if let error { g_error_free(error) }
            throw LinuxDesktopDBusError.invalidReply("introspection XML")
        }
        let box = ExportedObjectBox(object)
        let retained = Unmanaged.passRetained(box).toOpaque()
        var vtable = GDBusInterfaceVTable(
            method_call: gioMethodCallback,
            get_property: gioPropertyCallback,
            set_property: nil,
            padding: (nil, nil, nil, nil, nil, nil, nil, nil)
        )
        let registration = object.path.withCString {
            g_dbus_connection_register_object(connection, $0, interface, &vtable, retained, gioReleaseBox, &error)
        }
        guard registration != 0 else {
            Unmanaged<ExportedObjectBox>.fromOpaque(retained).release()
            g_dbus_node_info_unref(node)
            if let error { g_error_free(error) }
            throw LinuxDesktopDBusError.unavailable("export \(object.path)")
        }
        return GIOExportLease(connection: connection, registration: registration, node: node)
    }
}
