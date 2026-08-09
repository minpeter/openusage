import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum DevinLinuxError: Error, LocalizedError, Equatable, Sendable {
    case notLoggedIn
    case invalidCredentials
    case invalidResponse
    case quotaUnavailable
    case requestFailed(Int)
    case connectionFailed
    case localDataTooLarge

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn: "Run devin auth login or sign in to Devin and try again."
        case .invalidCredentials: "Devin credentials could not be read."
        case .invalidResponse, .quotaUnavailable: "Devin quota data unavailable. Try again later."
        case .requestFailed(let status): "Devin quota request failed (HTTP \(status)). Try again later."
        case .connectionFailed: "Devin quota request failed. Check your connection."
        case .localDataTooLarge: "Devin local data exceeds the 512 KiB read limit."
        }
    }
}

public struct DevinLinuxProvider: Sendable {
    public static let links = [ProviderLink(label: "Dashboard", url: "https://app.devin.ai/settings/plans")]
    public static let widgetDescriptors = [
        WidgetDescriptor(id: "devin.daily", title: "Daily", metricLabel: "Daily quota"),
        WidgetDescriptor(id: "devin.weekly", title: "Weekly", metricLabel: "Weekly quota"),
        WidgetDescriptor(id: "devin.extra", title: "Extra Balance", metricLabel: "Extra usage balance"),
    ]

    private let credentials: DevinLinuxCredentialStore
    private let client: DevinLinuxClient

    public init(
        credentials: DevinLinuxCredentialStore = DevinLinuxCredentialStore(),
        client: DevinLinuxClient = DevinLinuxClient()
    ) {
        self.credentials = credentials
        self.client = client
    }

    public func refresh(now: Date = Date()) async throws -> ProviderUsageSnapshot {
        let candidates = try credentials.allCandidates()
        var sawAuthFailure = false
        var lastError: Error = DevinLinuxError.quotaUnavailable
        for credential in candidates {
            do {
                let response = try await client.userStatus(credential: credential)
                if response.statusCode == 401 || response.statusCode == 403 {
                    sawAuthFailure = true
                    continue
                }
                guard (200..<300).contains(response.statusCode) else {
                    lastError = DevinLinuxError.requestFailed(response.statusCode)
                    continue
                }
                return try DevinLinuxMapper.mapUserStatus(data: response.data, credential: credential, now: now)
            } catch let error as DevinLinuxError {
                lastError = error
            } catch {
                lastError = DevinLinuxError.connectionFailed
            }
        }
        if sawAuthFailure { throw DevinLinuxError.notLoggedIn }
        throw lastError
    }
}
