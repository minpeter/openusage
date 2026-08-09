import Foundation

/// Values used at the injectable D-Bus boundary. Keeping the wire model in LinuxCore lets desktop
/// services be exercised against deterministic fakes without a running session bus.
public indirect enum DBusValue: Equatable, Sendable {
    case string(String)
    case objectPath(String)
    case boolean(Bool)
    case byte(UInt8)
    case uint32(UInt32)
    case int32(Int32)
    case array([DBusValue])
    case dictionary([String: DBusValue])
    case structure([DBusValue])
    case variant(DBusValue)
}

public struct DBusMethodCall: Equatable, Sendable {
    public let destination: String
    public let path: String
    public let interface: String
    public let member: String
    public let arguments: [DBusValue]
    /// Complete tuple signature for `arguments` (for example `(s)` or `()`).
    public let inputSignature: String
    public let timeout: Duration

    public init(
        destination: String,
        path: String,
        interface: String,
        member: String,
        arguments: [DBusValue] = [],
        inputSignature: String = "()",
        timeout: Duration = .seconds(5)
    ) {
        self.destination = destination
        self.path = path
        self.interface = interface
        self.member = member
        self.arguments = arguments
        self.inputSignature = inputSignature
        self.timeout = timeout
    }
}

public struct DBusSignalMatch: Equatable, Sendable {
    public let sender: String?
    public let path: String?
    public let interface: String
    public let member: String

    public init(sender: String? = nil, path: String? = nil, interface: String, member: String) {
        self.sender = sender
        self.path = path
        self.interface = interface
        self.member = member
    }
}

public struct DBusSignal: Equatable, Sendable {
    public let path: String
    public let interface: String
    public let member: String
    public let arguments: [DBusValue]

    public init(path: String, interface: String, member: String, arguments: [DBusValue] = []) {
        self.path = path
        self.interface = interface
        self.member = member
        self.arguments = arguments
    }
}

public protocol DBusExportLease: Sendable {
    func cancel() async
}

public struct DBusExportedObject: Sendable {
    public typealias MethodHandler = @Sendable (_ member: String, _ arguments: [DBusValue]) async -> [DBusValue]

    public let path: String
    public let introspectionXML: String
    public let properties: [String: DBusValue]
    public let propertySignatures: [String: String]
    public let handleMethod: MethodHandler

    public init(
        path: String,
        introspectionXML: String,
        properties: [String: DBusValue] = [:],
        propertySignatures: [String: String] = [:],
        handleMethod: @escaping MethodHandler
    ) {
        self.path = path
        self.introspectionXML = introspectionXML
        self.properties = properties
        self.propertySignatures = propertySignatures
        self.handleMethod = handleMethod
    }
}

/// Session-bus operations required by the Linux desktop integrations. The concrete GIO adapter lives
/// in the GNOME target; tests inject an in-memory implementation.
public protocol LinuxDesktopDBusAdapter: Sendable {
    func call(_ call: DBusMethodCall) async throws -> [DBusValue]
    func signals(matching match: DBusSignalMatch) async throws -> AsyncStream<DBusSignal>
    func export(_ object: DBusExportedObject) async throws -> any DBusExportLease
}

public enum LinuxDesktopDBusError: Error, Equatable, LocalizedError, Sendable {
    case unavailable(String)
    case invalidReply(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .unavailable(let service): "D-Bus service is unavailable: \(service)"
        case .invalidReply(let method): "D-Bus method returned an invalid reply: \(method)"
        case .timedOut: "D-Bus operation timed out"
        }
    }
}
