import Foundation

/// Banked SuperGrok usage-limit resets from grok.com Settings → Usage.
///
/// Weekly percent still comes from `GET …/billing?format=credits`. This RPC is the
/// dedicated source for on-demand reset tokens — the same class of unofficial HTTP
/// Codex uses for `rate-limit-reset-credits`. Auth is the Grok CLI OIDC bearer from
/// `~/.grok/auth.json`; no cookies.
///
///     POST https://grok.com/prod_mc_billing.ConsumerUiSvc/GetRemainingResets
///     Content-Type: application/grpc-web+proto
///
///     message ConsumerGetRemainingResetsResp {
///       repeated ConsumerResetToken tokens = 10;
///     }
///     message ConsumerResetToken {
///       string token_id = 10;
///       google.protobuf.Timestamp validity_start = 20;
///       google.protobuf.Timestamp validity_end = 30;
///     }
///
/// Field numbers and the empty-request frame were verified against a live SuperGrok
/// Heavy capture (2026-08-13) and the grok.com Settings → Usage "Reset Available" card.
public enum GrokRemainingResets: Sendable {
    public static let metricLabel = "Usage Limit Resets"
    public static let widgetID = "grok.usageLimitResets"
    public static let url = URL(string: "https://grok.com/prod_mc_billing.ConsumerUiSvc/GetRemainingResets")!
    /// Uncompressed grpc-web frame around an empty protobuf message.
    public static let emptyRequest = Data([0x00, 0x00, 0x00, 0x00, 0x00])

    public struct Token: Equatable, Sendable {
        public let tokenID: String
        public let validFrom: Date?
        public let expiresAt: Date?

        public init(tokenID: String, validFrom: Date?, expiresAt: Date?) {
            self.tokenID = tokenID
            self.validFrom = validFrom
            self.expiresAt = expiresAt
        }

        public func isAvailable(at now: Date) -> Bool {
            guard let expiresAt else { return true }
            return expiresAt > now
        }
    }

    public struct Snapshot: Equatable, Sendable {
        public let tokens: [Token]
        public let availableCount: Int
        public let availableExpiries: [Date]

        public init(tokens: [Token], now: Date = Date()) {
            self.tokens = tokens
            let available = tokens.filter { $0.isAvailable(at: now) }
            availableCount = available.count
            availableExpiries = available.compactMap(\.expiresAt).sorted()
        }
    }

    /// `nil` when the body is not a usable grpc-web protobuf message, or when
    /// the trailer `grpc-status` is present and non-zero. An empty data frame
    /// is a real zero-count snapshot, not a miss — proto3 omits a repeated
    /// field when there are no tokens.
    public static func decode(grpcWeb data: Data, now: Date = Date()) -> Snapshot? {
        guard let frames = grpcWebFrames(in: data) else { return nil }
        if let status = frames.status, status != 0 { return nil }
        guard let message = frames.message,
              let tokens = parseTokens(in: message) else { return nil }
        return Snapshot(tokens: tokens, now: now)
    }

    /// Best-effort: a non-2xx or unparseable body omits the row (Codex-consistent
    /// "missing field" behavior). A decoded empty token list is `0 available`.
    public static func snapshot(httpStatus: Int, body: Data, now: Date = Date()) -> Snapshot? {
        guard (200..<300).contains(httpStatus) else { return nil }
        return decode(grpcWeb: body, now: now)
    }
}

// MARK: - grpc-web + proto (length-delimited fields only)

private struct GrpcWebFrames {
    var message: Data?
    var status: Int?
}

private func grpcWebFrames(in data: Data) -> GrpcWebFrames? {
    var offset = 0
    var frames = GrpcWebFrames()
    while offset + 5 <= data.count {
        let flags = data[offset]
        let length = Int(data[offset + 1]) << 24
            | Int(data[offset + 2]) << 16
            | Int(data[offset + 3]) << 8
            | Int(data[offset + 4])
        offset += 5
        guard offset + length <= data.count else { return nil }
        let payload = data.subdata(in: offset..<(offset + length))
        offset += length
        if flags & 0x80 == 0 {
            frames.message = payload
        } else if let status = grpcStatus(in: payload) {
            frames.status = status
        }
    }
    return frames
}

private func grpcStatus(in trailer: Data) -> Int? {
    guard let text = String(data: trailer, encoding: .utf8) else { return nil }
    for line in text.split(whereSeparator: \.isNewline) {
        let parts = line.split(separator: ":", maxSplits: 1)
        guard parts.first?.trimmingCharacters(in: .whitespaces).lowercased() == "grpc-status",
              let raw = parts.dropFirst().first?.trimmingCharacters(in: .whitespaces),
              let code = Int(raw)
        else { continue }
        return code
    }
    return nil
}

private func parseTokens(in message: Data) -> [GrokRemainingResets.Token]? {
    guard let fields = protoFields(in: message) else { return nil }
    var tokens: [GrokRemainingResets.Token] = []
    for (field, value) in fields where field == 10 {
        guard let token = parseToken(in: value) else { continue }
        tokens.append(token)
    }
    return tokens
}

private func parseToken(in message: Data) -> GrokRemainingResets.Token? {
    guard let fields = protoFields(in: message) else { return nil }
    var tokenID: String?
    var validFrom: Date?
    var expiresAt: Date?
    for (field, value) in fields {
        switch field {
        case 10:
            tokenID = String(data: value, encoding: .utf8)
        case 20:
            validFrom = protoTimestamp(in: value)
        case 30:
            expiresAt = protoTimestamp(in: value)
        default:
            continue
        }
    }
    guard let tokenID, !tokenID.isEmpty else { return nil }
    return GrokRemainingResets.Token(tokenID: tokenID, validFrom: validFrom, expiresAt: expiresAt)
}

private func protoTimestamp(in message: Data) -> Date? {
    guard let fields = protoFields(in: message) else { return nil }
    for (field, value) in fields where field == 1 {
        guard let seconds = protoVarint(value) else { continue }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }
    return nil
}

/// Length-delimited (wire 2) and varint (wire 0) fields. Unknown wire types are
/// skipped when their size is known (64-bit / 32-bit).
private func protoFields(in data: Data) -> [(Int, Data)]? {
    var offset = 0
    var result: [(Int, Data)] = []
    while offset < data.count {
        guard let (tag, tagEnd) = readVarint(data, at: offset) else { return nil }
        offset = tagEnd
        let field = Int(tag >> 3)
        switch Int(tag & 0x7) {
        case 0:
            guard let (_, next) = readVarint(data, at: offset) else { return nil }
            result.append((field, data.subdata(in: tagEnd..<next)))
            offset = next
        case 1:
            guard offset + 8 <= data.count else { return nil }
            offset += 8
        case 2:
            guard let (length, lenEnd) = readVarint(data, at: offset),
                  lenEnd + Int(length) <= data.count else { return nil }
            result.append((field, data.subdata(in: lenEnd..<(lenEnd + Int(length)))))
            offset = lenEnd + Int(length)
        case 5:
            guard offset + 4 <= data.count else { return nil }
            offset += 4
        default:
            return nil
        }
    }
    return result
}

private func protoVarint(_ data: Data) -> UInt64? {
    readVarint(data, at: 0)?.value
}

private func readVarint(_ data: Data, at start: Int) -> (value: UInt64, end: Int)? {
    var value: UInt64 = 0
    var shift = 0
    var index = start
    while index < data.count {
        let byte = data[index]
        index += 1
        value |= UInt64(byte & 0x7F) << shift
        if byte < 0x80 { return (value, index) }
        shift += 7
        if shift > 63 { return nil }
    }
    return nil
}
