import Adwaita
import Foundation
import OpenUsageLinuxCore

/// Encodes `DBusValue` to and from GVariant via the GVariant text format,
/// and bridges Swift `Duration` and optional strings to GIO call shapes.
enum GIOVariantCodec {
    static func makeTuple(_ values: [DBusValue], signature: String) throws -> OpaquePointer {
        try parse(text: tupleText(values), signature: signature)
    }

    static func make(_ value: DBusValue, signature: String) throws -> OpaquePointer {
        try parse(text: text(value), signature: signature)
    }

    private static func parse(text: String, signature: String) throws -> OpaquePointer {
        guard let type = signature.withCString({ g_variant_type_new($0) }) else {
            throw LinuxDesktopDBusError.invalidReply("GVariant signature")
        }
        defer { g_variant_type_free(type) }
        var error: UnsafeMutablePointer<GError>?
        let value = text.withCString { value in
            g_variant_parse(type, value, nil, nil, &error)
        }
        guard let value else {
            if let error { g_error_free(error) }
            throw LinuxDesktopDBusError.invalidReply("GVariant value")
        }
        return value
    }

    private static func tupleText(_ values: [DBusValue]) -> String {
        if values.isEmpty { return "()" }
        let body = values.map(text).joined(separator: ", ")
        return values.count == 1 ? "(\(body),)" : "(\(body))"
    }

    private static func text(_ value: DBusValue) -> String {
        switch value {
        case .string(let value), .objectPath(let value): return quote(value)
        case .boolean(let value): return value ? "true" : "false"
        case .byte(let value): return "byte \(value)"
        case .uint32(let value): return "uint32 \(value)"
        case .int32(let value): return "int32 \(value)"
        case .array(let values): return "[\(values.map(text).joined(separator: ", "))]"
        case .dictionary(let values):
            return "{\(values.sorted(by: { $0.key < $1.key }).map { "\(quote($0.key)): \(text($0.value))" }.joined(separator: ", "))}"
        case .structure(let values): return tupleText(values)
        case .variant(let value): return "<\(text(value))>"
        }
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    static func tupleChildren(_ value: OpaquePointer) -> [DBusValue] {
        (0..<g_variant_n_children(value)).compactMap { index in
            guard let child = g_variant_get_child_value(value, index) else { return nil }
            defer { g_variant_unref(child) }
            return decode(child)
        }
    }

    private static func decode(_ value: OpaquePointer) -> DBusValue? {
        switch g_variant_classify(value) {
        case G_VARIANT_CLASS_STRING:
            return .string(String(cString: g_variant_get_string(value, nil)))
        case G_VARIANT_CLASS_OBJECT_PATH:
            return .objectPath(String(cString: g_variant_get_string(value, nil)))
        case G_VARIANT_CLASS_BOOLEAN: return .boolean(g_variant_get_boolean(value) != 0)
        case G_VARIANT_CLASS_BYTE: return .byte(g_variant_get_byte(value))
        case G_VARIANT_CLASS_UINT32: return .uint32(g_variant_get_uint32(value))
        case G_VARIANT_CLASS_INT32: return .int32(g_variant_get_int32(value))
        case G_VARIANT_CLASS_VARIANT:
            guard let child = g_variant_get_variant(value) else { return nil }
            defer { g_variant_unref(child) }
            return decode(child).map(DBusValue.variant)
        case G_VARIANT_CLASS_ARRAY:
            if String(cString: g_variant_get_type_string(value)).hasPrefix("a{") {
                var result: [String: DBusValue] = [:]
                for index in 0..<g_variant_n_children(value) {
                    guard let entry = g_variant_get_child_value(value, index) else { continue }
                    defer { g_variant_unref(entry) }
                    let children = tupleChildren(entry)
                    if case .string(let key)? = children.first, let item = children.dropFirst().first { result[key] = item }
                }
                return .dictionary(result)
            }
            return .array(tupleChildren(value))
        case G_VARIANT_CLASS_TUPLE, G_VARIANT_CLASS_DICT_ENTRY:
            return .structure(tupleChildren(value))
        default: return nil
        }
    }
}

extension Duration {
    var gioMilliseconds: Int32 {
        let components = self.components
        let milliseconds = components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
        return Int32(clamping: milliseconds)
    }
}

extension Optional where Wrapped == String {
    func withOptionalCString<Result>(_ body: (UnsafePointer<CChar>?) -> Result) -> Result {
        switch self {
        case .some(let value): value.withCString(body)
        case .none: body(nil)
        }
    }
}
