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
    /// Candidate samples that were rolled back or superseded. They are kept as
    /// abnormal evidence but never attributed to a confirmed cycle.
    var anomalousObservations: [QuotaObservation] = []
    var rejectedInvalidCount: Int = 0
    var rejectedOutOfOrderCount: Int = 0
    var rejectedAmbiguousCount: Int = 0
    var rollbackCount: Int = 0
    var expiredCandidateCount: Int = 0
}

/// Candidate transition awaiting an independent confirmation request.
struct PendingQuotaTransition: Codable, Equatable {
    var previousCycleID: UUID
    var firstNewWindowSample: QuotaObservation
    var reason: QuotaCycleEnd
    var awaitingConfirmation: Bool
    /// True when the candidate came from a same-reset proportion drop
    /// (「额度回修」). Such a candidate can only resolve by rollback or by
    /// being superseded by a real window change; it never confirms on its own.
    var isProportionFix: Bool
}

struct QuotaCycleReducer {
    let policy: QuotaCyclePolicy

    init(policy: QuotaCyclePolicy = QuotaCyclePolicy()) {
        self.policy = policy
    }

    /// Fold one raw observation into the state, following the §2.4 decision
    /// table. Invalid values, out-of-order requests and backward resets are
    /// rejected; ambiguous changes stay candidates until an independent
    /// request confirms or rolls them back. Nothing is silently explained as
    /// natural expiry.
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
        if abs(drift) <= policy.resetJitter {
            ingestSameWindow(sample, into: &state)
            return
        }

        // The window moved. A backward reset is never explained as expiry.
        guard drift > 0 else {
            state.rejectedAmbiguousCount += 1
            return
        }

        // A long silence before the window change is an observation gap; the
        // old segment closes immediately and the new one starts unknown.
        let silence = sample.observedAt.timeIntervalSince(current.lastObservedAt)
        if silence > policy.maximumContinuousGap {
            closeCurrentAsGap(with: sample, into: &state)
            return
        }

        if let pending = state.pendingTransition {
            let candidateDrift = sample.resetAt
                .timeIntervalSince(pending.firstNewWindowSample.resetAt)
            if abs(candidateDrift) <= policy.resetJitter {
                let delay = sample.observedAt
                    .timeIntervalSince(pending.firstNewWindowSample.observedAt)
                if delay >= policy.confirmationMinDelay
                    && delay <= policy.confirmationMaxDelay {
                    confirm(pending, with: sample, into: &state)
                } else if delay > policy.confirmationMaxDelay {
                    // Confirmation window elapsed: keep the transition pending
                    // under a fresh anchor so a later independent request can
                    // still confirm the same new window.
                    state.expiredCandidateCount += 1
                    state.pendingTransition = makeWindowCandidate(
                        from: sample, current: current, reason: pending.reason)
                    state.lastObservation = sample
                } else {
                    // Too fast to be an independent request; replays never
                    // count as the second confirmation sample.
                    state.rejectedAmbiguousCount += 1
                }
                return
            }
            if pending.isProportionFix {
                // A real window change supersedes a proportion-fix candidate.
                state.anomalousObservations.append(pending.firstNewWindowSample)
                state.pendingTransition = makeWindowCandidate(
                    from: sample, current: current, reason: nil)
                state.lastObservation = sample
                return
            }
            state.rejectedAmbiguousCount += 1
            return
        }

        state.pendingTransition = makeWindowCandidate(
            from: sample, current: current, reason: nil)
        state.lastObservation = sample
    }

    // MARK: - Paths

    /// Same-reset sample. A meaningful proportion drop (>= meaningfulDrop)
    /// with an unchanged reset stays an abnormal candidate instead of
    /// silently overwriting the confirmed current cycle.
    private func ingestSameWindow(
        _ sample: QuotaObservation, into state: inout QuotaCycleState
    ) {
        if let pending = state.pendingTransition {
            // Back to the old window: roll the candidate back, keep the
            // abnormal evidence, leave no fabricated closed cycle behind.
            state.anomalousObservations.append(pending.firstNewWindowSample)
            state.rollbackCount += 1
            state.pendingTransition = nil
        }
        guard var current = state.current else { return }
        let drop = current.lastObservedUsedPercent - sample.usedPercent
        if drop >= policy.meaningfulDrop {
            state.pendingTransition = PendingQuotaTransition(
                previousCycleID: current.id,
                firstNewWindowSample: sample,
                reason: .windowChanged,
                awaitingConfirmation: true,
                isProportionFix: true)
            state.lastObservation = sample
            return
        }
        if drop == 0 {
            // Equivalent sample (same window, same percentage): advance the
            // in-memory last-observed markers but do not grow evidence, so a
            // 10-second refresh poll never churns the persisted history.
            current.lastObservedAt = sample.observedAt
            state.current = current
            state.lastObservation = sample
            return
        }
        current.lastObservedAt = sample.observedAt
        current.lastObservedUsedPercent = sample.usedPercent
        current.evidence.append(sample)
        state.current = current
        state.lastObservation = sample
    }

    /// A forward window change within the continuous-observation budget
    /// becomes a candidate. `reason == nil` derives it: samples taken at or
    /// after the old deadline are natural rotations, earlier ones are
    /// window changes with unknown cause.
    private func makeWindowCandidate(
        from sample: QuotaObservation,
        current: QuotaCycleRecord,
        reason: QuotaCycleEnd?
    ) -> PendingQuotaTransition {
        let resolved = reason
            ?? (sample.observedAt >= current.expectedResetAt
                ? QuotaCycleEnd.natural : QuotaCycleEnd.windowChanged)
        return PendingQuotaTransition(
            previousCycleID: current.id,
            firstNewWindowSample: sample,
            reason: resolved,
            awaitingConfirmation: true,
            isProportionFix: false)
    }

    /// Second independent request on the same new window: seal the old
    /// segment before the first new-window request, open the new cycle from
    /// the observed transition. Old percentages are never overwritten.
    private func confirm(
        _ pending: PendingQuotaTransition,
        with sample: QuotaObservation,
        into state: inout QuotaCycleState
    ) {
        guard var sealed = state.current,
              sealed.id == pending.previousCycleID else {
            state.rejectedAmbiguousCount += 1
            return
        }
        sealed.boundaryLower = sealed.lastObservedAt
        sealed.boundaryUpper = pending.firstNewWindowSample.requestStartedAt
        sealed.end = pending.reason
        state.closed.append(sealed)

        var next = QuotaCycleReducer.openCycle(
            from: pending.firstNewWindowSample, startKind: .observedTransition)
        next.evidence.append(sample)
        next.lastObservedAt = sample.observedAt
        next.lastObservedUsedPercent = sample.usedPercent
        state.current = next
        state.pendingTransition = nil
        state.lastObservation = sample
    }

    /// Window changed after a long silence: close the old segment as a gap
    /// and start a fresh cycle whose beginning is explicitly unknown.
    private func closeCurrentAsGap(
        with sample: QuotaObservation, into state: inout QuotaCycleState
    ) {
        if let pending = state.pendingTransition {
            state.anomalousObservations.append(pending.firstNewWindowSample)
            state.pendingTransition = nil
        }
        guard var sealed = state.current else { return }
        sealed.boundaryLower = sealed.lastObservedAt
        sealed.boundaryUpper = sample.requestStartedAt
        sealed.end = .gap
        state.closed.append(sealed)
        state.current = QuotaCycleReducer.openCycle(
            from: sample, startKind: .afterGap)
        state.lastObservation = sample
    }

    private static func openCycle(
        from sample: QuotaObservation,
        startKind: QuotaCycleStart = .inferred
    ) -> QuotaCycleRecord {
        QuotaCycleRecord(
            id: UUID(),
            startKind: startKind,
            inferredStartAt: startKind == .afterGap
                ? nil : sample.resetAt.addingTimeInterval(-7 * 24 * 60 * 60),
            firstObservedAt: sample.observedAt,
            expectedResetAt: sample.resetAt,
            lastObservedAt: sample.observedAt,
            lastObservedUsedPercent: sample.usedPercent,
            boundaryLower: nil,
            boundaryUpper: nil,
            end: nil,
            incomplete: startKind != .observedTransition,
            evidence: [sample])
    }
}
