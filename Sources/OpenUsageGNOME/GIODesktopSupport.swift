import Adwaita
import Foundation
import OpenUsageLinuxCore

/// Retained boxes and C callbacks backing `GIODesktopDBusAdapter`: GIO owns
/// raw pointers to these for signal subscriptions and exported objects, so
/// each is balanced by `gioReleaseBox`.
final class SignalContinuationBox: @unchecked Sendable {
    let continuation: AsyncStream<DBusSignal>.Continuation
    init(_ continuation: AsyncStream<DBusSignal>.Continuation) { self.continuation = continuation }
}

final class ExportedObjectBox: @unchecked Sendable {
    let object: DBusExportedObject
    private let lock = NSLock()
    private var properties: [String: DBusValue]

    init(_ object: DBusExportedObject) {
        self.object = object
        properties = object.properties
    }

    func property(named name: String) -> (value: DBusValue, signature: String)? {
        lock.withLock {
            guard let value = properties[name], let signature = object.propertySignatures[name] else { return nil }
            return (value, signature)
        }
    }

    func updateProperties(_ changed: [String: DBusValue]) {
        lock.withLock {
            for (name, value) in changed {
                properties[name] = value
            }
        }
    }
}

final class GIOExportLease: DBusExportLease, @unchecked Sendable {
    private let lock = NSLock()
    private let connection: OpaquePointer
    private let path: String
    private let box: ExportedObjectBox
    private var registration: UInt32
    private var node: UnsafeMutablePointer<GDBusNodeInfo>?

    init(
        connection: OpaquePointer,
        path: String,
        box: ExportedObjectBox,
        registration: UInt32,
        node: UnsafeMutablePointer<GDBusNodeInfo>
    ) {
        self.connection = connection
        self.path = path
        self.box = box
        self.registration = registration
        self.node = node
    }

    func updateProperties(interface: String, changed: [String: DBusValue]) async throws {
        box.updateProperties(changed)
        let parameters = try GIOVariantCodec.makeTuple([
            .string(interface),
            .dictionary([:]),
            .array(changed.keys.sorted().map(DBusValue.string)),
        ], signature: "(sa{sv}as)")
        defer { g_variant_unref(parameters) }
        try emit(
            path: path,
            interface: "org.freedesktop.DBus.Properties",
            member: "PropertiesChanged",
            parameters: parameters
        )
    }

    func emit(_ signal: DBusSignal, signature: String) async throws {
        let parameters = try GIOVariantCodec.makeTuple(signal.arguments, signature: signature)
        defer { g_variant_unref(parameters) }
        try emit(
            path: signal.path,
            interface: signal.interface,
            member: signal.member,
            parameters: parameters
        )
    }

    func cancel() async {
        let (registration, node) = lock.withLock {
            let values = (self.registration, self.node)
            self.registration = 0
            self.node = nil
            return values
        }
        if registration != 0 { g_dbus_connection_unregister_object(connection, registration) }
        if let node { g_dbus_node_info_unref(node) }
    }

    private func emit(path: String, interface: String, member: String, parameters: OpaquePointer) throws {
        var error: UnsafeMutablePointer<GError>?
        let emitted = path.withCString { path in
            interface.withCString { interface in
                member.withCString { member in
                    g_dbus_connection_emit_signal(
                        connection, nil, path, interface, member, parameters, &error
                    )
                }
            }
        }
        guard emitted != 0 else {
            if let error { g_error_free(error) }
            throw LinuxDesktopDBusError.unavailable("\(interface).\(member)")
        }
    }

    deinit {
        if registration != 0 { g_dbus_connection_unregister_object(connection, registration) }
        if let node { g_dbus_node_info_unref(node) }
    }
}

nonisolated(unsafe) let gioSignalCallback: GDBusSignalCallback = { _, _, path, interface, member, parameters, userData in
    guard let path, let interface, let member, let parameters, let userData else { return }
    let box = Unmanaged<SignalContinuationBox>.fromOpaque(userData).takeUnretainedValue()
    box.continuation.yield(DBusSignal(
        path: String(cString: path), interface: String(cString: interface), member: String(cString: member),
        arguments: GIOVariantCodec.tupleChildren(parameters)
    ))
}

nonisolated(unsafe) let gioMethodCallback: GDBusInterfaceMethodCallFunc = {
    _, _, _, _, method, parameters, invocation, userData in
    guard let method, let invocation, let userData else { return }
    let box = Unmanaged<ExportedObjectBox>.fromOpaque(userData).takeUnretainedValue()
    let arguments = parameters.map(GIOVariantCodec.tupleChildren) ?? []
    let member = String(cString: method)
    g_dbus_method_invocation_return_value(invocation, nil)
    Task { _ = await box.object.handleMethod(member, arguments) }
}

nonisolated(unsafe) let gioPropertyCallback: GDBusInterfaceGetPropertyFunc = {
    _, _, _, _, property, _, userData in
    guard let property, let userData else { return nil }
    let box = Unmanaged<ExportedObjectBox>.fromOpaque(userData).takeUnretainedValue()
    let name = String(cString: property)
    guard let property = box.property(named: name) else { return nil }
    return try? GIOVariantCodec.make(property.value, signature: property.signature)
}

nonisolated(unsafe) let gioReleaseBox: GDestroyNotify = { pointer in
    guard let pointer else { return }
    Unmanaged<AnyObject>.fromOpaque(pointer).release()
}
