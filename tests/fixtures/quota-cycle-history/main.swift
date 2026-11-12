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
    // Raw decrease inside one window must not be masked by max(used).
    reducer.ingest(sample(900, 41), into: &state)
    check(state.current?.lastObservedUsedPercent == 41, "raw decrease must be preserved, not clamped")
    check(state.current?.remainingAtLastObservation == 59, "remaining follows decreased percent")
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
    reducer.ingest(sample(600, 10, 604900), into: &state)   // +100s <= 120s jitter
    check(state.current?.id == id, "100s drift stays same cycle")
    reducer.ingest(sample(900, 10, 604930), into: &state)   // +130s > 120s
    check(state.current?.id == id, "beyond-tolerance drift must not silently merge into current")
    check(state.current?.expectedResetAt == t.addingTimeInterval(604800),
          "beyond-tolerance drift must not overwrite expected reset")
    check(state.current?.lastObservedUsedPercent == 10,
          "ambiguous drift keeps percent from the last in-window sample")
    check(state.closed.isEmpty, "no fabricated closed cycle in task 1")
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

default:
    fputs("FAIL: unknown case \(CommandLine.arguments[1])\n", stderr)
    exit(1)
}
