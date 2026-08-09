import Foundation

public struct LinuxUsageAPIState: Sendable {
    public var knownProviderIDs: Set<String>
    public var snapshots: [ProviderUsageSnapshot]
    public var generatedAt: Date

    public init(
        knownProviderIDs: Set<String>,
        snapshots: [ProviderUsageSnapshot],
        generatedAt: Date = Date()
    ) {
        self.knownProviderIDs = Set(knownProviderIDs.map { $0.lowercased() })
        self.snapshots = snapshots
        self.generatedAt = generatedAt
    }

    func matchingSnapshots(_ token: String) -> [ProviderUsageSnapshot]? {
        let token = token.lowercased()
        let knownInstances = Set(snapshots.map { $0.instanceID.lowercased() })
        let knownFamilies = knownProviderIDs.union(snapshots.map { $0.providerID.lowercased() })
        guard knownInstances.contains(token) || knownFamilies.contains(token) else { return nil }
        return snapshots.filter {
            $0.instanceID.lowercased() == token || $0.providerID.lowercased() == token
        }
    }
}

public struct LinuxUsageAPIResponse: Equatable, Sendable {
    public let status: Int
    public let body: Data?

    public init(status: Int, body: Data?) {
        self.status = status
        self.body = body
    }
}

/// Pure routing and serialization shared by the CLI and loopback transport.
public enum LinuxUsageAPI {
    public static let maximumResponseBytes = SnapshotCache.maximumBytes
    public static let cacheLifetime: TimeInterval = 300

    public static func respond(method: String, path: String, state: LinuxUsageAPIState) -> LinuxUsageAPIResponse {
        if method == "OPTIONS" { return LinuxUsageAPIResponse(status: 204, body: nil) }
        let pathOnly = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
        let segments = pathOnly.split(separator: "/").map(String.init)

        let response: LinuxUsageAPIResponse
        switch (segments.count, segments.first, segments.dropFirst().first) {
        case (2, "v1", "usage"):
            guard method == "GET" else { return error(405, "method_not_allowed") }
            response = encoded(state.snapshots.map(UsageWireSnapshot.init))
        case (3, "v1", "usage"):
            guard method == "GET" else { return error(405, "method_not_allowed") }
            guard let snapshots = state.matchingSnapshots(segments[2]) else {
                return error(404, "provider_not_found")
            }
            response = encoded(snapshots.map(UsageWireSnapshot.init))
        case (2, "v1", "limits"):
            guard method == "GET" else { return error(405, "method_not_allowed") }
            response = limits(state.snapshots, state: state)
        case (3, "v1", "limits"):
            guard method == "GET" else { return error(405, "method_not_allowed") }
            guard let snapshots = state.matchingSnapshots(segments[2]) else {
                return error(404, "provider_not_found")
            }
            response = limits(snapshots, state: state)
        default:
            return error(404, "not_found")
        }
        return response
    }

    public static let busyResponse = error(503, "server_busy")

    private static func encoded(_ value: some Encodable) -> LinuxUsageAPIResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value), data.count <= maximumResponseBytes else {
            return error(503, "response_too_large")
        }
        return LinuxUsageAPIResponse(status: 200, body: data)
    }

    private static func error(_ status: Int, _ code: String) -> LinuxUsageAPIResponse {
        LinuxUsageAPIResponse(status: status, body: Data(#"{"error":"\#(code)"}"#.utf8))
    }

    private static func limits(_ snapshots: [ProviderUsageSnapshot], state: LinuxUsageAPIState) -> LinuxUsageAPIResponse {
        var providers: [String: LimitsWireProvider] = [:]
        for snapshot in snapshots where snapshot.errorMessage == nil {
            providers[snapshot.instanceID] = LimitsWireProvider(snapshot: snapshot, generatedAt: state.generatedAt)
        }
        let errors = snapshots.compactMap { snapshot in
            snapshot.errorMessage.map { LimitsWireError(providerID: snapshot.instanceID, message: $0) }
        }
        return encoded(LimitsWireEnvelope(
            schema: "openusage.limits.v1",
            generatedAt: iso8601(state.generatedAt),
            providers: providers,
            errors: errors
        ))
    }
}

func iso8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}
