import Foundation
import OpenUsageLinuxCore

enum APIKeyOperationResult: Equatable, Sendable {
    case status(String)
    case stored
    case cleared
    case failed(String)
    case stale
}

actor APIKeyOperationCoordinator {
    private let manager: LinuxAPIKeyManager
    private var latestRevision: [ManagedAPIKeyProvider: UInt64] = [:]

    init(manager: LinuxAPIKeyManager = LinuxAPIKeyManager()) {
        self.manager = manager
    }

    func status(
        for provider: ManagedAPIKeyProvider,
        revision: UInt64
    ) -> APIKeyOperationResult {
        guard accept(revision, for: provider) else { return .stale }
        do {
            return .status(
                try manager.hasStoredKey(for: provider)
                    ? "Stored"
                    : "Not Stored"
            )
        } catch {
            return .status("Secret Service Unavailable")
        }
    }

    func store(
        _ value: String,
        for provider: ManagedAPIKeyProvider,
        revision: UInt64
    ) -> APIKeyOperationResult {
        guard accept(revision, for: provider) else { return .stale }
        do {
            try manager.store(value, for: provider)
            return .stored
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func clear(
        _ provider: ManagedAPIKeyProvider,
        revision: UInt64
    ) -> APIKeyOperationResult {
        guard accept(revision, for: provider) else { return .stale }
        do {
            try manager.clear(provider)
            return .cleared
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func accept(
        _ revision: UInt64,
        for provider: ManagedAPIKeyProvider
    ) -> Bool {
        guard revision >= (latestRevision[provider] ?? 0) else {
            return false
        }
        latestRevision[provider] = revision
        return true
    }
}
