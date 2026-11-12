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

    /// Build a history sample from one quota request round's **own** 7-day
    /// response. Only a response that itself carries a valid ratio and reset
    /// (and no error) yields a sample: a failed round, a missing field or a
    /// merged old value never becomes an observation, so no fabricated or
    /// stale percentages can enter the history.
    static func accepted(
        requestStartedAt: Date,
        observedAt: Date,
        usedRatio: Double?,
        reset: Date?,
        error: String?
    ) -> QuotaObservation? {
        guard error == nil, let usedRatio, usedRatio.isFinite,
              (0...1).contains(usedRatio), let reset else { return nil }
        let sample = QuotaObservation(
            requestStartedAt: requestStartedAt, observedAt: observedAt,
            usedPercent: usedRatio * 100, resetAt: reset)
        return sample.isValid ? sample : nil
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

// MARK: - UI-facing snapshot

/// Stable, UI-ready value type for one credential scope's quota cycle
/// history. The view layer reads only snapshots; it never touches the store,
/// the coordinator queue or mutable state. Snapshots are plain values, so a
/// later state change can never retroactively alter what the UI is showing.
struct QuotaCycleSnapshot: Equatable {
    /// True once the scope's history has been read from disk (even when the
    /// history is empty). False while no scope is active or a read failed,
    /// when the UI shows a neutral placeholder instead of stale data.
    var loaded: Bool
    var closed: [QuotaCycleRecord]
    var current: QuotaCycleRecord?
    var pendingTransition: PendingQuotaTransition?
    /// Credential-round generation this snapshot belongs to. Production
    /// snapshots always carry it so a late main-thread delivery from a
    /// superseded round can be dropped before touching the UI; `inactive`
    /// and preview fixtures use `nil`. Never carries apiKey/scopeKey.
    var generation: Int? = nil
    /// True when the scope's last load or save failed. The UI shows
    /// 「历史未保存」 without discarding the in-memory observations.
    var persistenceFailed: Bool

    /// Snapshot delivered before any credential scope is active.
    static let inactive = QuotaCycleSnapshot(
        loaded: false, closed: [], current: nil,
        pendingTransition: nil, persistenceFailed: false)

    /// Fixed in-memory preview fixture (twelve closed cycles + the current
    /// one, thirteen rounds in total so paging geometry can be checked).
    /// It is built from a constant epoch, never touches disk, credentials or
    /// the real clock, and preview paths inject it instead of ever
    /// constructing a coordinator or a real history store.
    static let previewFixture: QuotaCycleSnapshot = makePreviewFixture(
        closed: [(100, .natural), (58, .natural), (72, .windowChanged), (40, .gap),
                 (93, .natural), (66, .natural), (88, .windowChanged), (44, .natural),
                 (30, .gap), (100, .natural), (62, .windowChanged), (85, .natural)],
        currentUsed: 36, pending: false)
    static let previewOneFixture: QuotaCycleSnapshot = makePreviewFixture(
        closed: [], currentUsed: 36, pending: false)
    static let previewSixFixture: QuotaCycleSnapshot = makePreviewFixture(
        closed: [(81, .natural), (72, .windowChanged), (40, .gap), (93, .natural), (66, .natural)],
        currentUsed: 36, pending: false)
    static let previewLongFixture: QuotaCycleSnapshot = makePreviewFixture(
        closed: Array(repeating: (72, .natural), count: 24),
        currentUsed: 36, pending: false)
    /// 短历史（3 个已结束 + 当前，共 4 轮 < 6 轮）：验证不足一轮屏时卡片保持固定高度。
    static let previewShortFixture: QuotaCycleSnapshot = makePreviewFixture(
        closed: [(81, .natural), (72, .windowChanged), (40, .gap)],
        currentUsed: 36, pending: false)
    static let previewCrossYearFixture: QuotaCycleSnapshot = makePreviewFixture(
        closed: [(81, .natural), (72, .windowChanged)], currentUsed: 36, pending: false,
        base: Date(timeIntervalSince1970: 1_767_225_600)) // 2026-01-01 00:00 UTC
    static let previewLoadFailedFixture = QuotaCycleSnapshot(
        loaded: false, closed: [], current: nil,
        pendingTransition: nil, persistenceFailed: true)
    /// 当前轮次带未确认窗口变化候选：详情显示「窗口变化待确认」，不产生新历史柱。
    static let previewPendingFixture: QuotaCycleSnapshot = makePreviewFixture(
        closed: [(81, .natural), (72, .windowChanged)],
        currentUsed: 36, pending: true)
    /// 已加载但零记录：空态占位文案，不渲染图表、不伪造历史。
    static let previewEmptyFixture = QuotaCycleSnapshot(
        loaded: true, closed: [], current: nil,
        pendingTransition: nil, persistenceFailed: false)

    private static func makePreviewFixture(
        closed usedEnds: [(used: Double, end: QuotaCycleEnd)],
        currentUsed: Double?,
        pending: Bool,
        base: Date = Date(timeIntervalSince1970: 1_763_000_000)
    ) -> QuotaCycleSnapshot {
        let day: TimeInterval = 24 * 60 * 60
        func evidence(_ requestOffset: Double, _ used: Double,
                      _ resetOffset: Double) -> QuotaObservation {
            QuotaObservation(
                requestStartedAt: base.addingTimeInterval(requestOffset),
                observedAt: base.addingTimeInterval(requestOffset + 60),
                usedPercent: used,
                resetAt: base.addingTimeInterval(resetOffset))
        }
        var closed: [QuotaCycleRecord] = []
        for (index, entry) in usedEnds.enumerated() {
            // 由旧到新：最早一轮在 -count 周，最新一轮在 -1 周。
            let cycleBack = index - usedEnds.count
            let reset = base.addingTimeInterval(Double(cycleBack) * 7 * day)
            let boundaryOffset = Double(cycleBack + 1) * 7 * day
                + (entry.end == .gap ? 3600 : 240)
            let first = evidence(reset.timeIntervalSince(base) - 6 * day,
                                 entry.used, reset.timeIntervalSince(base))
            let last = evidence(boundaryOffset - 120, entry.used,
                                reset.timeIntervalSince(base))
            closed.append(QuotaCycleRecord(
                id: UUID(),
                startKind: .inferred,
                inferredStartAt: reset.addingTimeInterval(-7 * day),
                firstObservedAt: first.observedAt,
                expectedResetAt: reset,
                lastObservedAt: last.observedAt,
                lastObservedUsedPercent: entry.used,
                boundaryLower: last.observedAt,
                boundaryUpper: base.addingTimeInterval(boundaryOffset),
                end: entry.end,
                incomplete: true,
                evidence: [first, last]))
        }
        var current: QuotaCycleRecord?
        var pendingTransition: PendingQuotaTransition?
        if let currentUsed {
            let currentReset = base.addingTimeInterval(7 * day)
            current = QuotaCycleRecord(
                id: UUID(),
                startKind: .inferred,
                inferredStartAt: currentReset.addingTimeInterval(-7 * day),
                firstObservedAt: evidence(-6 * day, currentUsed, 7 * day).observedAt,
                expectedResetAt: currentReset,
                lastObservedAt: evidence(-3600, currentUsed, 7 * day).observedAt,
                lastObservedUsedPercent: currentUsed,
                boundaryLower: nil,
                boundaryUpper: nil,
                end: nil,
                incomplete: true,
                evidence: [evidence(-3600, currentUsed, 7 * day)])
            if pending, let current {
                pendingTransition = PendingQuotaTransition(
                    previousCycleID: current.id,
                    firstNewWindowSample: evidence(-1200, 3, 14 * day),
                    reason: .windowChanged,
                    awaitingConfirmation: true,
                    isProportionFix: false)
            }
        }
        return QuotaCycleSnapshot(
            loaded: true, closed: closed, current: current,
            pendingTransition: pendingTransition, persistenceFailed: false)
    }

    var recordCount: Int { closed.count + (current == nil ? 0 : 1) }
}

// MARK: - Browsing model

/// Pure paging and selection model for the cycle history card.
///
/// Pages are anchored on the newest end of a chronological (oldest-first)
/// record list and clamp to the available records; the browser never holds
/// raw indices that a new record could silently invalidate. The selection is
/// a stable cycle ID, so refresh and rebuild can restore the exact same
/// viewing position.
struct QuotaCycleBrowser: Equatable {
    let pageSize: Int
    let initialWindow: Int
    private(set) var windowSize: Int
    private(set) var olderPage: Int
    var selectedCycleID: UUID?

    init(pageSize: Int = 6, initialWindow: Int = 12) {
        self.pageSize = max(1, pageSize)
        self.initialWindow = max(self.pageSize, initialWindow)
        self.windowSize = self.initialWindow
        self.olderPage = 0
        self.selectedCycleID = nil
    }

    /// Indices of the records visible right now. Page 0 is always the newest
    /// `pageSize` records; each older page moves one page toward the oldest.
    func visibleRange(total: Int) -> Range<Int> {
        let safeTotal = max(0, total)
        let safeSize = max(1, pageSize)
        let maxPage = max(0, (safeTotal - 1) / safeSize)
        let page = min(max(0, olderPage), maxPage)
        let upper = max(0, safeTotal - page * safeSize)
        return max(0, upper - safeSize)..<upper
    }

    mutating func showOlderPage() { olderPage += 1 }

    mutating func showNewerPage() { olderPage = max(0, olderPage - 1) }

    /// 「更早记录」: extend the browsable window by one initial batch. There
    /// is no storage cap; the window only grows when the user asks.
    mutating func loadEarlier() { windowSize += initialWindow }

    /// The only reset trigger: switching the credential scope clears the
    /// page anchor, the selection and the browsing window.
    mutating func reset() {
        olderPage = 0
        selectedCycleID = nil
        windowSize = max(pageSize, initialWindow)
    }

    // MARK: - 窗口化浏览（首批最近 initialWindow 条，「更早记录」每次再扩展一批）
    //
    // 图表永远不一次性展示全部历史：可浏览条数 = min(总条数, 浏览窗口)，页码基于
    // 可浏览条数 clamp；窗口是页大小的整数倍，映射回全量索引后最旧一页恰好覆盖
    // 窗口起点。扩展只由用户主动触发（「更早记录」按钮或方向键到达最旧已载页）。

    /// 当前可浏览条数（浏览窗口内）。
    static func browsableCount(total: Int, windowSize: Int) -> Int {
        min(max(0, total), max(1, windowSize))
    }

    /// 窗口之外是否还有未载入的更早记录（决定「更早记录」入口是否可用）。
    static func hasMoreBeyondWindow(total: Int, windowSize: Int) -> Bool {
        total > max(1, windowSize)
    }

    /// 某一屏在全量（旧→新）索引中的范围。页码先按可浏览条数 clamp，
    /// 再映射回全量索引；窗口为页大小整数倍时最旧页不会越过窗口起点。
    static func windowedRange(total: Int, windowSize: Int,
                              pageOffset: Int, pageSize: Int = 6) -> Range<Int> {
        let browsable = browsableCount(total: total, windowSize: windowSize)
        guard browsable > 0 else { return 0..<0 }
        let safeSize = max(1, pageSize)
        let maxPage = max(0, (browsable - 1) / safeSize)
        let page = min(max(0, pageOffset), maxPage)
        let upper = max(0, total - page * safeSize)
        return max(0, upper - safeSize)..<upper
    }

    mutating func select(_ id: UUID?) { selectedCycleID = id }

    /// 把固定选择移动到指定轮次，并把页锚点跟过去（键盘逐组/跨页用）。
    /// 只锚定当前浏览窗口内的 ID：窗口之外的更早 ID 由调用方先 `loadEarlier()`
    /// 扩展窗口，再 reveal；不在窗口内时不改页锚（渲染端按可浏览条数 clamp）。
    mutating func reveal(_ id: UUID, chronologicalIDs: [UUID]) {
        selectedCycleID = id
        let windowed = Array(chronologicalIDs.suffix(max(pageSize, windowSize)))
        guard let index = windowed.firstIndex(of: id) else { return }
        let total = windowed.count
        olderPage = max(0, (total - 1 - index) / pageSize)
    }

    /// The record list changed (e.g. a cycle closed while the user browses
    /// history). Pages never jump back to the newest page on their own —
    /// only a credential scope switch does that. When a selection exists the
    /// page anchor follows it so the selection stays visible; otherwise the
    /// current page anchor is preserved as-is.
    mutating func noteRecordsChanged(chronologicalIDs: [UUID]) {
        guard let selected = selectedCycleID,
              let index = chronologicalIDs.firstIndex(of: selected) else { return }
        let total = chronologicalIDs.count
        let safeSize = max(1, pageSize)
        let pageOfSelected = (total - 1 - index) / safeSize
        if pageOfSelected != olderPage {
            olderPage = pageOfSelected
        }
    }
}
