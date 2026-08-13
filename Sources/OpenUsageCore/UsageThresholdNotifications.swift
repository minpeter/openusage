import Foundation

public enum UsageNotificationMilestone: String, CaseIterable, Hashable, Sendable {
    case almostOut
    case cuttingItClose
    case willRunOut

    public var title: String {
        switch self {
        case .almostOut: "Almost Out"
        case .cuttingItClose: "Cutting It Close"
        case .willRunOut: "Will Run Out"
        }
    }

    public var body: String {
        switch self {
        case .almostOut: "Under 10% usage remaining for this window."
        case .cuttingItClose: "Projected to finish close to your limit."
        case .willRunOut: "Projected to finish before the limit resets."
        }
    }
}

public enum UsageNotificationPaceBucket: Int, Codable, Sendable {
    case untracked = -1
    case healthy = 0
    case close = 1
    case runningOut = 2
}

public struct UsageNotificationState: Equatable, Sendable {
    public var resetsAt: Date?
    public var firedMilestones: Set<UsageNotificationMilestone>
    public var previousBucket: UsageNotificationPaceBucket
    public var wasUnderTenPercent: Bool
    public var primed: Bool

    public init(
        resetsAt: Date? = nil,
        firedMilestones: Set<UsageNotificationMilestone> = [],
        previousBucket: UsageNotificationPaceBucket = .untracked,
        wasUnderTenPercent: Bool = false,
        primed: Bool = false
    ) {
        self.resetsAt = resetsAt
        self.firedMilestones = firedMilestones
        self.previousBucket = previousBucket
        self.wasUnderTenPercent = wasUnderTenPercent
        self.primed = primed
    }

    public func markingDelivered(
        _ milestones: [UsageNotificationMilestone]
    ) -> UsageNotificationState {
        var copy = self
        copy.firedMilestones.formUnion(milestones)
        return copy
    }
}

public struct UsageNotificationToggles: Equatable, Sendable {
    public var almostOut: Bool
    public var cuttingItClose: Bool
    public var willRunOut: Bool

    public init(
        almostOut: Bool,
        cuttingItClose: Bool,
        willRunOut: Bool
    ) {
        self.almostOut = almostOut
        self.cuttingItClose = cuttingItClose
        self.willRunOut = willRunOut
    }

    public static let allEnabled = UsageNotificationToggles(
        almostOut: true,
        cuttingItClose: true,
        willRunOut: true
    )

    public func isEnabled(_ milestone: UsageNotificationMilestone) -> Bool {
        switch milestone {
        case .almostOut: almostOut
        case .cuttingItClose: cuttingItClose
        case .willRunOut: willRunOut
        }
    }
}

public enum UsageThresholdNotificationPolicy {
    public struct Transition: Equatable, Sendable {
        public let milestones: [UsageNotificationMilestone]
        public let state: UsageNotificationState

        public init(
            milestones: [UsageNotificationMilestone],
            state: UsageNotificationState
        ) {
            self.milestones = milestones
            self.state = state
        }
    }

    public static func transitions(
        bucket: UsageNotificationPaceBucket,
        remainingFraction: Double,
        resetsAt: Date?,
        previous: UsageNotificationState,
        toggles: UsageNotificationToggles
    ) -> Transition {
        var next = previous
        if resetWindowAdvanced(resetsAt: resetsAt, previousReset: previous.resetsAt) {
            next.firedMilestones = []
            next.wasUnderTenPercent = false
            next.previousBucket = .untracked
        }
        next.resetsAt = resetsAt ?? previous.resetsAt

        let remaining = UsageThresholdMath.normalizedRemaining(remainingFraction)
        if !next.primed {
            next.primed = true
            next.previousBucket = bucket
            next.wasUnderTenPercent = UsageThresholdMath.isAlmostOut(remaining)
            next.firedMilestones = []
            return .init(milestones: [], state: next)
        }

        var milestones: [UsageNotificationMilestone] = []
        if bucket != .untracked {
            let previousSeverity = next.previousBucket.rawValue
            let currentSeverity = bucket.rawValue
            var paceCandidate = false
            if bucket == .close, previousSeverity < UsageNotificationPaceBucket.close.rawValue {
                paceCandidate = appendIfEnabled(
                    .cuttingItClose,
                    milestones: &milestones,
                    state: next,
                    toggles: toggles
                ) || paceCandidate
            }
            if currentSeverity >= UsageNotificationPaceBucket.runningOut.rawValue,
               previousSeverity < UsageNotificationPaceBucket.runningOut.rawValue
            {
                paceCandidate = appendIfEnabled(
                    .willRunOut,
                    milestones: &milestones,
                    state: next,
                    toggles: toggles
                ) || paceCandidate
            }
            if currentSeverity < previousSeverity {
                if currentSeverity <= UsageNotificationPaceBucket.healthy.rawValue {
                    next.firedMilestones.remove(.cuttingItClose)
                }
                if currentSeverity <= UsageNotificationPaceBucket.close.rawValue {
                    next.firedMilestones.remove(.willRunOut)
                }
            }
            if currentSeverity <= previousSeverity || paceCandidate {
                next.previousBucket = bucket
            }
        }

        let underNow = remaining < 0.1
        let crossedUnder = underNow && !next.wasUnderTenPercent
        var underCandidate = false
        if crossedUnder {
            underCandidate = appendIfEnabled(
                .almostOut,
                milestones: &milestones,
                state: next,
                toggles: toggles
            )
        }
        if !underNow {
            next.firedMilestones.remove(.almostOut)
        }
        if !crossedUnder || underCandidate {
            next.wasUnderTenPercent = underNow
        }
        return .init(milestones: milestones, state: next)
    }

    public static func bucket(
        metric: UsageMetric,
        now: Date = Date()
    ) -> UsageNotificationPaceBucket {
        guard metric.kind == .progress,
              metric.used.isFinite,
              let limit = metric.limit,
              limit.isFinite,
              limit > 0,
              let resetsAt = metric.resetsAt,
              let periodMilliseconds = metric.periodDurationMilliseconds,
              periodMilliseconds > 0
        else {
            return .untracked
        }
        let period = TimeInterval(periodMilliseconds) / 1_000
        let elapsed = now.timeIntervalSince(resetsAt.addingTimeInterval(-period))
        guard period.isFinite,
              elapsed.isFinite,
              elapsed > 0,
              elapsed < period
        else {
            return .untracked
        }
        let projectedFraction = max(metric.used, 0) / limit / (elapsed / period)
        if projectedFraction <= 0.9 {
            return .healthy
        }
        if projectedFraction <= 1 {
            return .close
        }
        return .runningOut
    }

    public static func remainingFraction(metric: UsageMetric) -> Double {
        guard metric.used.isFinite,
              let limit = metric.limit,
              limit.isFinite,
              limit > 0
        else {
            return 1
        }
        return 1 - min(max(metric.used / limit, 0), 1)
    }

    public static let resetWindowJitterTolerance: TimeInterval = 1

    public static func resetWindowAdvanced(
        resetsAt: Date?,
        previousReset: Date?
    ) -> Bool {
        guard let resetsAt else { return false }
        guard let previousReset else { return true }
        return resetsAt.timeIntervalSince(previousReset) > resetWindowJitterTolerance
    }

    private static func appendIfEnabled(
        _ milestone: UsageNotificationMilestone,
        milestones: inout [UsageNotificationMilestone],
        state: UsageNotificationState,
        toggles: UsageNotificationToggles
    ) -> Bool {
        guard toggles.isEnabled(milestone),
              !state.firedMilestones.contains(milestone)
        else {
            return false
        }
        milestones.append(milestone)
        return true
    }
}

public struct UsageThresholdNotificationKey: Hashable, Sendable {
    public let providerID: String
    public let instanceID: String
    public let metricKind: String
    public let metricLabel: String

    public init(
        providerID: String,
        instanceID: String,
        metricKind: String,
        metricLabel: String
    ) {
        self.providerID = providerID
        self.instanceID = instanceID
        self.metricKind = metricKind
        self.metricLabel = metricLabel
    }
}

public struct UsageThresholdNotificationEvent: Equatable, Hashable, Sendable {
    public let key: UsageThresholdNotificationKey
    public let milestone: UsageNotificationMilestone
    public let providerName: String
    public let accountLabel: String?
    public let metricLabel: String

    public init(
        key: UsageThresholdNotificationKey,
        milestone: UsageNotificationMilestone,
        providerName: String,
        accountLabel: String?,
        metricLabel: String
    ) {
        self.key = key
        self.milestone = milestone
        self.providerName = providerName
        self.accountLabel = accountLabel
        self.metricLabel = metricLabel
    }

    public var subtitle: String {
        [providerName, accountLabel, metricLabel]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

public actor UsageThresholdNotificationCoordinator {
    private var states: [UsageThresholdNotificationKey: UsageNotificationState] = [:]
    private var pending: [
        UsageThresholdNotificationKey: [UsageNotificationMilestone]
    ] = [:]

    public init() {}

    public func events(
        snapshots: [ProviderUsageSnapshot],
        toggles: UsageNotificationToggles,
        now: Date = Date()
    ) -> [UsageThresholdNotificationEvent] {
        var events: [UsageThresholdNotificationEvent] = []
        for snapshot in snapshots {
            for metric in snapshot.metrics where metric.kind == .progress && metric.limit != nil {
                let key = UsageThresholdNotificationKey(
                    providerID: snapshot.providerID,
                    instanceID: snapshot.instanceID,
                    metricKind: metric.kind.rawValue,
                    metricLabel: metric.label
                )
                var previous = states[key] ?? .init()
                var metricPending = pending[key] ?? []
                pruneDisabledPending(
                    &metricPending,
                    state: &previous,
                    toggles: toggles
                )
                if UsageThresholdNotificationPolicy.resetWindowAdvanced(
                    resetsAt: metric.resetsAt,
                    previousReset: previous.resetsAt
                ) {
                    pending.removeValue(forKey: key)
                    metricPending = []
                }

                let bucket = UsageThresholdNotificationPolicy.bucket(metric: metric, now: now)
                let remaining = UsageThresholdNotificationPolicy.remainingFraction(metric: metric)
                let transition = UsageThresholdNotificationPolicy.transitions(
                    bucket: bucket,
                    remainingFraction: remaining,
                    resetsAt: metric.resetsAt,
                    previous: previous,
                    toggles: toggles
                )
                states[key] = transition.state

                prunePending(
                    &metricPending,
                    bucket: bucket,
                    remainingFraction: remaining
                )
                for milestone in transition.milestones where !metricPending.contains(milestone) {
                    metricPending.append(milestone)
                }
                if metricPending.isEmpty {
                    pending.removeValue(forKey: key)
                } else {
                    pending[key] = metricPending
                }

                events.append(contentsOf: metricPending.map { milestone in
                    UsageThresholdNotificationEvent(
                        key: key,
                        milestone: milestone,
                        providerName: snapshot.displayName,
                        accountLabel: snapshot.accountLabel,
                        metricLabel: metric.label
                    )
                })
            }
        }
        return events
    }

    public func markDelivered(_ event: UsageThresholdNotificationEvent) {
        guard var metricPending = pending[event.key],
              metricPending.contains(event.milestone)
        else {
            return
        }
        metricPending.removeAll { $0 == event.milestone }
        if metricPending.isEmpty {
            pending.removeValue(forKey: event.key)
        } else {
            pending[event.key] = metricPending
        }
        states[event.key] = (states[event.key] ?? .init())
            .markingDelivered([event.milestone])
    }

    private func prunePending(
        _ pending: inout [UsageNotificationMilestone],
        bucket: UsageNotificationPaceBucket,
        remainingFraction: Double
    ) {
        if remainingFraction >= 0.1 {
            pending.removeAll { $0 == .almostOut }
        }
        switch bucket {
        case .untracked, .healthy:
            pending.removeAll { $0 == .cuttingItClose || $0 == .willRunOut }
        case .close:
            pending.removeAll { $0 == .willRunOut }
        case .runningOut:
            pending.removeAll { $0 == .cuttingItClose }
        }
    }

    private func pruneDisabledPending(
        _ pending: inout [UsageNotificationMilestone],
        state: inout UsageNotificationState,
        toggles: UsageNotificationToggles
    ) {
        if !toggles.almostOut, pending.contains(.almostOut) {
            pending.removeAll { $0 == .almostOut }
            state.wasUnderTenPercent = false
        }
        if !toggles.cuttingItClose, pending.contains(.cuttingItClose) {
            pending.removeAll { $0 == .cuttingItClose }
            if state.previousBucket == .close {
                state.previousBucket = .healthy
            }
        }
        if !toggles.willRunOut, pending.contains(.willRunOut) {
            pending.removeAll { $0 == .willRunOut }
            if state.previousBucket == .runningOut {
                state.previousBucket = .close
            }
        }
    }
}
