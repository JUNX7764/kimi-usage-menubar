import Foundation

/// Local heuristics for turning raw 7-day quota observations into cycles.
/// These are client-side judgement parameters, not Kimi server guarantees.
struct QuotaCyclePolicy {
    var resetJitter: TimeInterval = 120
    var meaningfulDrop: Double = 1            // percentage points, candidate signal only
    var confirmationMinDelay: TimeInterval = 10
    var confirmationMaxDelay: TimeInterval = 180
    var maximumContinuousGap: TimeInterval = 15 * 60
    var heartbeatInterval: TimeInterval = 5 * 60
}

/// One raw observation accepted from a real 7-day quota response.
struct QuotaObservation: Codable, Equatable {
    let requestStartedAt: Date
    let observedAt: Date
    let usedPercent: Double
    let resetAt: Date

    var isValid: Bool {
        requestStartedAt <= observedAt && usedPercent.isFinite
            && (0...100).contains(usedPercent)
            && resetAt.timeIntervalSince1970.isFinite
            && observedAt.timeIntervalSince1970.isFinite
            && requestStartedAt.timeIntervalSince1970.isFinite
    }
}

enum QuotaCycleEnd: String, Codable {
    case natural, windowChanged, gap
}

enum QuotaCycleStart: String, Codable {
    case inferred, observedTransition, afterGap
}

struct QuotaCycleRecord: Codable, Equatable, Identifiable {
    let id: UUID
    var startKind: QuotaCycleStart
    var inferredStartAt: Date?
    var firstObservedAt: Date
    var expectedResetAt: Date
    var lastObservedAt: Date
    var lastObservedUsedPercent: Double
    var boundaryLower: Date?
    var boundaryUpper: Date?
    var end: QuotaCycleEnd?
    var incomplete: Bool
    var evidence: [QuotaObservation]

    var remainingAtLastObservation: Double {
        max(0, min(100, 100 - lastObservedUsedPercent))
    }
    var wasObservedFull: Bool { lastObservedUsedPercent == 100 }
}

/// Pure state machine for 7-day quota cycle history.
struct QuotaCycleState: Codable, Equatable {
    static let schemaVersion = 1

    var schemaVersion: Int = QuotaCycleState.schemaVersion
    var closed: [QuotaCycleRecord] = []
    var current: QuotaCycleRecord?
    var lastObservation: QuotaObservation?
    var lastRequestStartedAt: Date?
    var pendingTransition: PendingQuotaTransition?
    var rejectedInvalidCount: Int = 0
    var rejectedOutOfOrderCount: Int = 0
    var rejectedAmbiguousCount: Int = 0
}

/// Candidate window transition awaiting independent confirmation. Task 1 only
/// reserves the shape; split/confirm/rollback logic arrives with Task 2.
struct PendingQuotaTransition: Codable, Equatable {
    var previousCycleID: UUID
    var firstNewWindowSample: QuotaObservation
    var reason: QuotaCycleEnd
    var awaitingConfirmation: Bool
}

struct QuotaCycleReducer {
    let policy: QuotaCyclePolicy

    init(policy: QuotaCyclePolicy = QuotaCyclePolicy()) {
        self.policy = policy
    }

    /// Fold one raw observation into the state. Invalid values, out-of-order
    /// requests and beyond-tolerance window drift are rejected rather than
    /// explained away; they never fabricate or mutate confirmed cycles.
    func ingest(_ sample: QuotaObservation, into state: inout QuotaCycleState) {
        guard sample.isValid else {
            state.rejectedInvalidCount += 1
            return
        }
        if let lastStarted = state.lastRequestStartedAt,
           sample.requestStartedAt <= lastStarted {
            state.rejectedOutOfOrderCount += 1
            return
        }
        state.lastRequestStartedAt = sample.requestStartedAt

        guard let current = state.current else {
            state.current = QuotaCycleReducer.openCycle(from: sample)
            state.lastObservation = sample
            return
        }

        let drift = sample.resetAt.timeIntervalSince(current.expectedResetAt)
        guard abs(drift) <= policy.resetJitter else {
            // Task 1 scope: window transitions are not split yet. Keep the
            // current cycle untouched and count the ambiguous sample; Task 2
            // turns this path into the candidate/confirm state machine.
            state.rejectedAmbiguousCount += 1
            state.lastObservation = sample
            return
        }

        var updated = current
        updated.lastObservedAt = sample.observedAt
        updated.lastObservedUsedPercent = sample.usedPercent
        updated.evidence.append(sample)
        state.current = updated
        state.lastObservation = sample
    }

    private static func openCycle(from sample: QuotaObservation) -> QuotaCycleRecord {
        QuotaCycleRecord(
            id: UUID(),
            startKind: .inferred,
            inferredStartAt: sample.resetAt.addingTimeInterval(-7 * 24 * 60 * 60),
            firstObservedAt: sample.observedAt,
            expectedResetAt: sample.resetAt,
            lastObservedAt: sample.observedAt,
            lastObservedUsedPercent: sample.usedPercent,
            boundaryLower: nil,
            boundaryUpper: nil,
            end: nil,
            incomplete: true,
            evidence: [sample])
    }
}
