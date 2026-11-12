import Foundation

func check(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

let t = Date(timeIntervalSince1970: 1_800_000_000)

func sample(_ seconds: Double, _ used: Double, _ reset: Double = 604800) -> QuotaObservation {
    QuotaObservation(requestStartedAt: t.addingTimeInterval(seconds - 1),
        observedAt: t.addingTimeInterval(seconds), usedPercent: used,
        resetAt: t.addingTimeInterval(reset))
}

func makeReducer() -> QuotaCycleReducer {
    QuotaCycleReducer(policy: QuotaCyclePolicy())
}

switch CommandLine.arguments[1] {

case "firstObservation":
    var state = QuotaCycleState()
    let reducer = makeReducer()
    reducer.ingest(sample(0, 43), into: &state)
    check(state.current != nil, "first sample must create current")
    check(state.current?.lastObservedUsedPercent == 43, "used percentage must survive")
    check(state.current?.remainingAtLastObservation == 57, "remaining is percentage")
    check(state.current?.startKind == .inferred, "first start is inferred")
    check(state.closed.isEmpty, "must not fabricate old cycles")
    print("PASS: firstObservation")

case "sameWindowGrowth":
    var state = QuotaCycleState()
    let reducer = makeReducer()
    reducer.ingest(sample(0, 43), into: &state)
    reducer.ingest(sample(600, 58), into: &state)
    check(state.current?.lastObservedUsedPercent == 58, "growth updates last observed percent")
    check(state.current?.lastObservedAt == t.addingTimeInterval(600), "growth updates last observed time")
    check(state.current?.remainingAtLastObservation == 42, "remaining follows raw percent")
    check(state.closed.isEmpty, "same window must not close a cycle")
    check(state.current?.evidence.count == 2, "each accepted same-window sample is evidence")
    // A meaningful raw decrease (>= 1pp) with an unchanged reset becomes an
    // abnormal candidate instead of silently overwriting the confirmed cycle.
    reducer.ingest(sample(900, 41), into: &state)
    check(state.current?.lastObservedUsedPercent == 58, "candidate sample must not pollute confirmed current")
    check(state.pendingTransition != nil, "meaningful decrease creates an abnormal candidate")
    check(state.pendingTransition?.isProportionFix == true, "unchanged reset means proportion-fix candidate")
    check(state.current?.evidence.count == 2, "candidate sample must not grow current evidence")
    // Recovery to the old window value rolls the candidate back; a sub-meaningful
    // decrease then updates current normally.
    reducer.ingest(sample(1200, 57.5), into: &state)
    check(state.pendingTransition == nil, "recovered old-window sample rolls back the candidate")
    check(state.current?.lastObservedUsedPercent == 57.5, "sub-meaningful decrease updates current")
    check(state.current?.evidence.count == 3, "recovered sample is evidence again")
    check(state.anomalousObservations.count == 1, "rolled-back candidate evidence is preserved")
    check(state.anomalousObservations[0].usedPercent == 41, "anomalous evidence keeps the dropped sample")
    check(state.closed.isEmpty, "candidate flow must not fabricate closed cycles")
    print("PASS: sameWindowGrowth")

case "exactDuplicate":
    var state = QuotaCycleState()
    let reducer = makeReducer()
    reducer.ingest(sample(0, 43), into: &state)
    let id = state.current?.id
    reducer.ingest(sample(0, 43), into: &state)
    check(state.current?.id == id, "duplicate request must keep cycle id")
    check(state.closed.isEmpty, "duplicate must not close a cycle")
    check(state.current?.evidence.count == 1, "duplicate replay must not grow evidence")
    print("PASS: exactDuplicate")

case "resetDriftWithinTolerance":
    var state = QuotaCycleState()
    let reducer = makeReducer()
    reducer.ingest(sample(0, 43), into: &state)
    let id = state.current?.id
    reducer.ingest(sample(600, 50, 604830), into: &state)   // +30s
    check(state.current?.id == id, "30s drift keeps cycle id")
    check(state.current?.expectedResetAt == t.addingTimeInterval(604800),
          "drift keeps original expected reset")
    reducer.ingest(sample(900, 55, 604680), into: &state)   // -120s
    check(state.current?.id == id, "120s drift keeps cycle id")
    check(state.current?.expectedResetAt == t.addingTimeInterval(604800),
          "boundary jitter keeps original expected reset")
    check(state.current?.lastObservedUsedPercent == 55, "jittered sample still updates percent")
    check(state.closed.isEmpty, "jitter must not close a cycle")
    print("PASS: resetDriftWithinTolerance")

case "resetDriftBeyondTolerance":
    var state = QuotaCycleState()
    let reducer = makeReducer()
    reducer.ingest(sample(0, 43), into: &state)
    let id = state.current?.id
    reducer.ingest(sample(600, 50, 604830), into: &state)   // +30s <= 120s jitter
    check(state.current?.id == id, "100s drift stays same cycle")
    check(state.current?.lastObservedUsedPercent == 50, "in-window growth still applies")
    reducer.ingest(sample(900, 50, 604930), into: &state)   // +130s > 120s
    check(state.current?.id == id, "beyond-tolerance drift must not silently merge into current")
    check(state.current?.expectedResetAt == t.addingTimeInterval(604800),
          "beyond-tolerance drift must not overwrite expected reset")
    check(state.current?.lastObservedUsedPercent == 50,
          "ambiguous drift keeps percent from the last in-window sample")
    check(state.pendingTransition != nil, "beyond-tolerance forward drift becomes a candidate")
    check(state.pendingTransition?.isProportionFix == false, "window drift is not a proportion fix")
    check(state.closed.isEmpty, "candidate must not close a cycle before confirmation")
    print("PASS: resetDriftBeyondTolerance")

case "nonFiniteRejected":
    var state = QuotaCycleState()
    let reducer = makeReducer()
    reducer.ingest(sample(0, .nan), into: &state)
    check(state.current == nil, "NaN must not create a cycle")
    reducer.ingest(sample(1, .infinity), into: &state)
    check(state.current == nil, "infinity must not create a cycle")
    check(state.closed.isEmpty, "invalid samples close nothing")
    print("PASS: nonFiniteRejected")

case "outOfRangeRejected":
    var state = QuotaCycleState()
    let reducer = makeReducer()
    reducer.ingest(sample(0, -1), into: &state)
    check(state.current == nil, "negative percent must not create a cycle")
    reducer.ingest(sample(1, 101), into: &state)
    check(state.current == nil, "percent above 100 must not create a cycle")
    reducer.ingest(sample(2, 100), into: &state)
    check(state.current?.lastObservedUsedPercent == 100, "exactly 100 is valid")
    check(state.current?.wasObservedFull == true, "only raw 100 counts as observed full")
    reducer.ingest(sample(3, 99.6), into: &state)
    check(state.current?.lastObservedUsedPercent == 99.6, "99.6 is stored raw")
    check(state.current?.wasObservedFull == false, "rounded 99.6 is not observed full")
    print("PASS: outOfRangeRejected")

case "outOfOrderRejected":
    var state = QuotaCycleState()
    let reducer = makeReducer()
    reducer.ingest(sample(600, 50), into: &state)
    let id = state.current?.id
    let evidenceCount = state.current?.evidence.count
    reducer.ingest(sample(0, 43), into: &state)   // earlier requestStartedAt than last accepted
    check(state.current?.id == id, "out-of-order sample must not replace current")
    check(state.current?.lastObservedUsedPercent == 50, "out-of-order sample must not overwrite percent")
    check(state.current?.evidence.count == evidenceCount, "out-of-order sample must not grow evidence")
    check(state.closed.isEmpty, "out-of-order sample closes nothing")
    // An out-of-order sample must also not poison later in-order ingestion.
    reducer.ingest(sample(900, 60), into: &state)
    check(state.current?.lastObservedUsedPercent == 60, "in-order sample still applies after rejection")
    print("PASS: outOfOrderRejected")

case "windowChangedCandidateConfirms":
    var state = QuotaCycleState()
    let reducer = makeReducer()
    reducer.ingest(sample(0, 72), into: &state)
    reducer.ingest(sample(100, 2, 605800), into: &state)
    check(state.closed.isEmpty && state.pendingTransition != nil,
          "new window needs independent confirmation")
    check(state.current?.lastObservedUsedPercent == 72,
          "candidate sample must not pollute confirmed current")
    reducer.ingest(sample(120, 3, 605800), into: &state)
    check(state.closed.count == 1, "stable new window splits once")
    check(state.closed[0].end == .windowChanged, "reason remains unknown")
    check(state.closed[0].lastObservedUsedPercent == 72,
          "do not overwrite old use with new-window value")
    check(state.current?.lastObservedUsedPercent == 3, "new current uses new window")
    check(state.current?.startKind == .observedTransition, "confirmed transition has observed start")
    check(state.current?.incomplete == false, "observed transition start is complete")
    check(state.current?.expectedResetAt == t.addingTimeInterval(605800),
          "new current tracks the new reset")
    check(state.current?.evidence.count == 2, "new current keeps both new-window samples")
    check(state.closed[0].boundaryLower == t.addingTimeInterval(0),
          "boundary starts at the last in-window observation")
    check(state.closed[0].boundaryUpper == t.addingTimeInterval(99),
          "boundary ends before the first new-window request started")
    check(state.pendingTransition == nil, "confirmation clears the candidate")
    print("PASS: windowChangedCandidateConfirms")

case "windowChangedCandidateRollsBack":
    var state = QuotaCycleState()
    let reducer = makeReducer()
    reducer.ingest(sample(0, 72), into: &state)
    reducer.ingest(sample(100, 2, 605800), into: &state)
    reducer.ingest(sample(120, 80), into: &state)   // back to the old window
    check(state.pendingTransition == nil, "returning to the old window rolls back the candidate")
    check(state.closed.isEmpty, "rollback leaves no fabricated closed cycle")
    check(state.current?.lastObservedUsedPercent == 80, "recovered in-window sample updates current")
    check(state.current?.evidence.count == 2, "recovered sample joins current evidence")
    check(state.anomalousObservations.count == 1, "abnormal evidence is preserved on rollback")
    check(state.rollbackCount == 1, "rollback is counted")
    print("PASS: windowChangedCandidateRollsBack")

case "windowChangedCandidateExpires":
    var state = QuotaCycleState()
    let reducer = makeReducer()
    reducer.ingest(sample(0, 72), into: &state)
    reducer.ingest(sample(100, 2, 605800), into: &state)
    reducer.ingest(sample(300, 3, 605800), into: &state)   // 200s later > 180s
    check(state.closed.isEmpty, "late sample must not confirm the candidate")
    check(state.pendingTransition != nil, "expired candidate stays pending via a fresh anchor")
    check(state.expiredCandidateCount == 1, "expiry is counted")
    check(state.pendingTransition?.firstNewWindowSample.observedAt == t.addingTimeInterval(300),
          "late sample re-anchors the candidate")
    reducer.ingest(sample(320, 4, 605800), into: &state)
    check(state.closed.count == 1, "re-anchored candidate confirms with an independent request")
    check(state.closed[0].end == .windowChanged, "re-anchored split still has unknown reason")
    check(state.closed[0].lastObservedUsedPercent == 72, "old segment keeps its last in-window use")
    check(state.current?.lastObservedUsedPercent == 4, "new current uses the re-anchored window")
    print("PASS: windowChangedCandidateExpires")

case "replayDoesNotConfirm":
    var state = QuotaCycleState()
    let reducer = makeReducer()
    reducer.ingest(sample(0, 72), into: &state)
    reducer.ingest(sample(100, 2, 605800), into: &state)
    reducer.ingest(sample(100, 2, 605800), into: &state)   // identical replay
    check(state.rejectedOutOfOrderCount == 1, "identical replay is rejected as out-of-order")
    check(state.closed.isEmpty && state.pendingTransition != nil,
          "replay must not confirm the candidate")
    reducer.ingest(sample(105, 2, 605800), into: &state)   // only 5s after the candidate
    check(state.closed.isEmpty && state.pendingTransition != nil,
          "a too-fast sample is not an independent confirmation")
    check(state.rejectedAmbiguousCount == 1, "too-fast confirmation attempt is counted ambiguous")
    print("PASS: replayDoesNotConfirm")

case "naturalRotationZeroToZero":
    var state = QuotaCycleState()
    let reducer = makeReducer()
    reducer.ingest(sample(0, 0), into: &state)
    reducer.ingest(sample(604700, 0), into: &state)
    reducer.ingest(sample(604900, 0, 1_209_600), into: &state)   // crossed the old deadline
    check(state.pendingTransition != nil, "natural rotation also waits for confirmation")
    check(state.pendingTransition?.reason == .natural, "crossed deadline means natural rotation")
    check(state.closed.isEmpty, "unconfirmed natural rotation closes nothing")
    reducer.ingest(sample(604920, 0, 1_209_600), into: &state)
    check(state.closed.count == 1, "second new-window sample confirms natural rotation")
    check(state.closed[0].end == .natural, "natural expiry keeps its own end kind")
    check(state.closed[0].lastObservedUsedPercent == 0, "0->0 still seals the old segment")
    check(state.current?.lastObservedUsedPercent == 0, "new current starts from zero")
    check(state.current?.startKind == .observedTransition, "natural rotation start is observed")
    check(state.current?.expectedResetAt == t.addingTimeInterval(1_209_600),
          "new current tracks the rotated reset")
    print("PASS: naturalRotationZeroToZero")

case "fullCycleNatural":
    var state = QuotaCycleState()
    let reducer = makeReducer()
    reducer.ingest(sample(0, 100), into: &state)
    reducer.ingest(sample(604700, 100), into: &state)
    reducer.ingest(sample(604900, 4, 1_209_600), into: &state)
    reducer.ingest(sample(604920, 5, 1_209_600), into: &state)
    check(state.closed.count == 1, "one natural rotation closes one cycle")
    check(state.closed[0].end == .natural, "expired cycle ends naturally")
    check(state.closed[0].wasObservedFull == true, "raw 100 before rotation counts as observed full")
    check(state.closed[0].remainingAtLastObservation == 0, "full cycle has no remaining percent")
    check(state.current?.lastObservedUsedPercent == 5, "new current uses the fresh window value")
    print("PASS: fullCycleNatural")

case "resetMovedBackwardRejected":
    var state = QuotaCycleState()
    let reducer = makeReducer()
    reducer.ingest(sample(0, 50), into: &state)
    reducer.ingest(sample(600, 50, 604000), into: &state)   // reset moved back 800s
    check(state.rejectedAmbiguousCount == 1, "backward reset is counted ambiguous")
    check(state.current?.expectedResetAt == t.addingTimeInterval(604800),
          "backward reset must not move the expected reset")
    check(state.current?.lastObservedUsedPercent == 50, "backward reset must not touch percent")
    check(state.closed.isEmpty, "backward reset closes nothing")
    check(state.pendingTransition == nil, "backward reset never becomes a candidate")
    reducer.ingest(sample(700, 60), into: &state)
    check(state.current?.lastObservedUsedPercent == 60,
          "in-window growth still applies after a backward rejection")
    print("PASS: resetMovedBackwardRejected")

case "forwardResetMoveWithoutDrop":
    var state = QuotaCycleState()
    let reducer = makeReducer()
    reducer.ingest(sample(0, 43), into: &state)
    reducer.ingest(sample(100, 43, 605800), into: &state)   // reset moved, percent unchanged
    check(state.pendingTransition != nil, "reset-only change is a pending time-change candidate")
    check(state.pendingTransition?.reason == .windowChanged,
          "pre-deadline reset move stays reason-unknown")
    check(state.closed.isEmpty, "time-change candidate closes nothing before confirmation")
    check(state.current?.lastObservedUsedPercent == 43, "candidate must not pollute confirmed current")
    check(state.current?.expectedResetAt == t.addingTimeInterval(604800),
          "candidate must not move the expected reset")
    print("PASS: forwardResetMoveWithoutDrop")

case "proportionFixCandidate":
    var state = QuotaCycleState()
    let reducer = makeReducer()
    reducer.ingest(sample(0, 72), into: &state)
    reducer.ingest(sample(100, 70), into: &state)   // same reset, 2pp drop
    check(state.pendingTransition != nil, "meaningful proportion drop creates a candidate")
    check(state.pendingTransition?.isProportionFix == true, "same-reset drop is a proportion fix")
    check(state.current?.lastObservedUsedPercent == 72, "proportion fix must not overwrite current")
    check(state.current?.evidence.count == 1, "proportion-fix sample stays out of current evidence")
    check(state.closed.isEmpty, "proportion fix closes nothing")
    reducer.ingest(sample(200, 74), into: &state)   // recovered above the old value
    check(state.pendingTransition == nil, "recovery rolls back the proportion-fix candidate")
    check(state.current?.lastObservedUsedPercent == 74, "recovered sample updates current")
    check(state.current?.evidence.count == 2, "recovered sample is evidence")
    check(state.anomalousObservations.count == 1, "proportion-fix evidence is preserved")
    check(state.closed.isEmpty, "proportion fix never fabricates a closed cycle")
    print("PASS: proportionFixCandidate")

case "gapAcrossThreeWeeks":
    var state = QuotaCycleState()
    let reducer = makeReducer()
    reducer.ingest(sample(0, 50), into: &state)
    reducer.ingest(sample(2_000_000, 30, 2_419_200), into: &state)   // ~23 days of silence
    check(state.closed.count == 1, "a long silence closes exactly one old segment")
    check(state.closed[0].end == .gap, "unobserved window change is a gap")
    check(state.closed[0].lastObservedUsedPercent == 50, "gap segment keeps its last seen use")
    check(state.closed[0].boundaryLower == t.addingTimeInterval(0),
          "gap boundary starts at the last observation")
    check(state.closed[0].boundaryUpper == t.addingTimeInterval(1_999_999),
          "gap boundary ends before the first new-window request started")
    check(state.current?.startKind == .afterGap, "post-gap cycle starts after a gap")
    check(state.current?.incomplete == true, "post-gap cycle start is unknown")
    check(state.current?.inferredStartAt == nil, "post-gap cycle must not invent a start time")
    check(state.current?.lastObservedUsedPercent == 30, "post-gap cycle keeps the first new value")
    check(state.current?.expectedResetAt == t.addingTimeInterval(2_419_200),
          "post-gap cycle tracks the new reset")
    check(state.pendingTransition == nil, "gap closes immediately without a candidate")
    print("PASS: gapAcrossThreeWeeks")

case "firstObservationMidCycle":
    var state = QuotaCycleState()
    let reducer = makeReducer()
    reducer.ingest(sample(0, 72), into: &state)   // first-ever sample is already mid-cycle
    check(state.current?.startKind == .inferred, "first-ever start is inferred")
    check(state.current?.incomplete == true, "first-ever observation mid-cycle is incomplete")
    check(state.current?.inferredStartAt == t,
          "inferred start is reset minus seven days")
    check(state.current?.lastObservedUsedPercent == 72, "mid-cycle percent is stored raw")
    check(state.current?.remainingAtLastObservation == 28, "remaining follows raw percent")
    check(state.current?.wasObservedFull == false, "72% is not observed full")
    print("PASS: firstObservationMidCycle")

default:
    fputs("FAIL: unknown case \(CommandLine.arguments[1])\n", stderr)
    exit(1)
}
