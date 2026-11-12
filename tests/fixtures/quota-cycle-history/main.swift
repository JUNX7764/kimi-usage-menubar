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

// MARK: - Task 3 helpers (all I/O inside per-case temporary directories)

func makeTempRoot() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("quota-cycle-store-" + UUID().uuidString, isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func removeTempRoot(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

let atomicWriter: QuotaCycleStore.Writer = { data, url in
    try data.write(to: url, options: .atomic)
}

func posixMode(_ url: URL) -> UInt32? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
          let number = attrs[.posixPermissions] as? NSNumber else { return nil }
    return UInt32(truncating: number) & 0o7777
}

func loadFails(_ store: QuotaCycleStore, _ scopeKey: String) -> Bool {
    (try? store.load(scopeKey: scopeKey)) == nil
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

case "scopeRoundTrip":
    let root = makeTempRoot()
    defer { removeTempRoot(root) }
    let store = QuotaCycleStore(root: root, writer: atomicWriter)
    let keyA = "fake-kimi-code-key-alpha"
    let scopeA = try! store.scopeKey(apiKey: keyA)
    check(scopeA.count == 64, "scope key is a fixed 64-char hex string")
    check(scopeA.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
          "scope key is lowercase hex only")
    check(try! store.scopeKey(apiKey: keyA) == scopeA, "scope key is stable for the same root and key")
    var state = QuotaCycleState()
    let reducer = makeReducer()
    reducer.ingest(sample(0, 72), into: &state)
    reducer.ingest(sample(100, 2, 605800), into: &state)   // pending window-change candidate
    try! store.save(state, scopeKey: scopeA)
    // Restart: a brand-new store instance over the same root must restore
    // the exact state, including a still-unconfirmed candidate.
    let restarted = QuotaCycleStore(root: root, writer: atomicWriter)
    let restored = try! restarted.load(scopeKey: scopeA)
    check(restored == state, "round trip restores the exact state")
    check(restored.pendingTransition != nil, "pending candidate survives a restart")
    check(restored.closed.isEmpty, "restart must not fabricate closed cycles")
    check(restored.current?.lastObservedUsedPercent == 72,
          "candidate sample never overwrote the confirmed current percent")
    // A fresh root has its own random salt, so the same key lands elsewhere.
    let otherRoot = makeTempRoot()
    defer { removeTempRoot(otherRoot) }
    let otherStore = QuotaCycleStore(root: otherRoot, writer: atomicWriter)
    check(try! otherStore.scopeKey(apiKey: keyA) != scopeA,
          "random per-root salt derives a different scope for the same key")
    print("PASS: scopeRoundTrip")

case "scopeIsolation":
    let root = makeTempRoot()
    defer { removeTempRoot(root) }
    let store = QuotaCycleStore(root: root, writer: atomicWriter)
    let keyA = "fake-kimi-code-key-alpha"
    let keyB = "fake-kimi-code-key-beta"
    let scopeA = try! store.scopeKey(apiKey: keyA)
    let scopeB = try! store.scopeKey(apiKey: keyB)
    check(scopeA != scopeB, "different credentials must not share a partition")
    var state = QuotaCycleState()
    makeReducer().ingest(sample(0, 43), into: &state)
    try! store.save(state, scopeKey: scopeA)
    let loadedB = try! store.load(scopeKey: scopeB)
    check(loadedB == QuotaCycleState(), "another scope starts from an empty state")
    check(loadedB.current == nil, "no history leaks across credential scopes")
    let loadedA = try! store.load(scopeKey: scopeA)
    check(loadedA.current?.lastObservedUsedPercent == 43, "own scope sees its own history")
    // Credential material must never land in the history JSON.
    let file = root.appendingPathComponent(scopeA).appendingPathComponent("history-v1.json")
    let json = String(data: try! Data(contentsOf: file), encoding: .utf8)!
    check(!json.contains(keyA), "api key must not appear in the history JSON")
    check(!json.contains(keyB), "other api key must not appear either")
    let salt = try! Data(contentsOf: root.appendingPathComponent("scope-salt"))
    let saltHex = salt.map { String(format: "%02x", $0) }.joined()
    check(!json.contains(saltHex), "salt must not appear in the history JSON")
    check(json.contains("schemaVersion"), "history JSON carries the schema version")
    print("PASS: scopeIsolation")

case "scopePermissions":
    let root = makeTempRoot()
    defer { removeTempRoot(root) }
    let store = QuotaCycleStore(root: root, writer: atomicWriter)
    let scope = try! store.scopeKey(apiKey: "fake-kimi-code-key")
    check(posixMode(root) == 0o700, "history root is enforced to 0700")
    let saltURL = root.appendingPathComponent("scope-salt")
    check((try! Data(contentsOf: saltURL)).count == 32, "scope salt is exactly 32 random bytes")
    check(posixMode(saltURL) == 0o600, "scope salt file is 0600")
    let partition = root.appendingPathComponent(scope)
    try! store.save(QuotaCycleState(), scopeKey: scope)
    check(posixMode(partition) == 0o700, "credential partition directory is 0700")
    let file = partition.appendingPathComponent("history-v1.json")
    check(posixMode(file) == 0o600, "history file is enforced to 0600")
    // Only fixed-length hex scope keys are accepted; traversal is rejected.
    for bad in ["", "../evil", scope + "x", String(repeating: "z", count: 64),
                "..", scope.uppercased()] {
        check(loadFails(store, bad), "malformed scope key must be rejected: \(bad)")
    }
    print("PASS: scopePermissions")

case "corruptAndFuturePreserved":
    let root = makeTempRoot()
    defer { removeTempRoot(root) }
    let store = QuotaCycleStore(root: root, writer: atomicWriter)
    let scope = try! store.scopeKey(apiKey: "fake-kimi-code-key")
    var state = QuotaCycleState()
    let reducer = makeReducer()
    reducer.ingest(sample(0, 72), into: &state)
    reducer.ingest(sample(604900, 3, 1_209_600), into: &state)
    reducer.ingest(sample(604920, 4, 1_209_600), into: &state)
    try! store.save(state, scopeKey: scope)
    let file = root.appendingPathComponent(scope).appendingPathComponent("history-v1.json")
    let original = try! JSONSerialization.jsonObject(with: try! Data(contentsOf: file)) as! [String: Any]

    // Garbage bytes: load fails, file untouched.
    let garbage = Data("not json at all".utf8)
    try! garbage.write(to: file)
    check(loadFails(store, scope), "garbage file must fail to load")
    check(try! Data(contentsOf: file) == garbage, "corrupt file is left untouched")

    // A future schema version is reported, never downgraded or overwritten.
    var future = original
    future["schemaVersion"] = 2
    let futureData = try! JSONSerialization.data(withJSONObject: future, options: [.sortedKeys])
    try! futureData.write(to: file)
    do {
        _ = try store.load(scopeKey: scope)
        check(false, "future schema must not load")
    } catch QuotaCycleStoreError.unsupportedSchema(let found) {
        check(found == 2, "the future schema version is reported")
    } catch {
        check(false, "future schema must surface as unsupportedSchema, got \(error)")
    }
    check(try! Data(contentsOf: file) == futureData, "future-version file is left untouched")

    // A newer request paired with an older response (time regression) is
    // rejected at decode time instead of silently moving history backwards.
    var tampered = original
    var closed = tampered["closed"] as! [[String: Any]]
    var evidence = closed[0]["evidence"] as! [[String: Any]]
    evidence[0]["requestStartedAt"] = (evidence[0]["observedAt"] as! Double) + 5000
    closed[0]["evidence"] = evidence
    tampered["closed"] = closed
    let tamperedData = try! JSONSerialization.data(withJSONObject: tampered, options: [.sortedKeys])
    try! tamperedData.write(to: file)
    check(loadFails(store, scope), "request/response time regression must fail to load")
    check(try! Data(contentsOf: file) == tamperedData, "tampered file is left untouched")
    check(posixMode(file) == 0o600,
          "permission repair on load fixes the mode without touching bytes")

    // The untouched good state is still intact after all failed loads.
    try! JSONSerialization.data(withJSONObject: original, options: [.sortedKeys]).write(to: file)
    let restored = try! store.load(scopeKey: scope)
    check(restored.closed.count == 1, "the original good state still loads")
    print("PASS: corruptAndFuturePreserved")

case "writerFailureKeepsLastGood":
    let root = makeTempRoot()
    defer { removeTempRoot(root) }
    var writerCalls = 0
    var failWrites = false
    let countingWriter: QuotaCycleStore.Writer = { data, url in
        writerCalls += 1
        if failWrites {
            throw NSError(domain: "TestWriter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "injected write failure"])
        }
        try data.write(to: url, options: .atomic)
    }
    let store = QuotaCycleStore(root: root, writer: countingWriter)
    let scope = try! store.scopeKey(apiKey: "fake-kimi-code-key")
    var state = QuotaCycleState()
    makeReducer().ingest(sample(0, 43), into: &state)
    try! store.save(state, scopeKey: scope)
    let callsAfterFirstSave = writerCalls
    makeReducer().ingest(sample(600, 58), into: &state)
    failWrites = true
    do {
        try store.save(state, scopeKey: scope)
        check(false, "a failing writer must propagate the error")
    } catch {
        // expected: the caller learns the write failed
    }
    check(writerCalls == callsAfterFirstSave + 1, "the failed save invoked the writer exactly once")
    // The last successful disk state survives; the caller keeps observing in memory.
    let disk = try! QuotaCycleStore(root: root, writer: countingWriter).load(scopeKey: scope)
    check(disk.current?.lastObservedUsedPercent == 43,
          "a failed write must not clobber the last good disk state")
    check(state.current?.lastObservedUsedPercent == 58,
          "the caller keeps its in-memory observations after a write failure")
    print("PASS: writerFailureKeepsLastGood")

case "saveDedupAndHeartbeat":
    let scheduler = QuotaCycleSaveScheduler(heartbeatInterval: 300)
    var state = QuotaCycleState()
    let reducer = makeReducer()
    reducer.ingest(sample(0, 43), into: &state)
    check(scheduler.shouldSave(state: state, diskState: nil, now: t, lastSaveAt: nil),
          "the first observation always saves")
    let disk = state
    let lastSave = t
    check(!scheduler.shouldSave(state: state, diskState: disk,
                                now: t.addingTimeInterval(60), lastSaveAt: lastSave),
          "an unchanged state inside the heartbeat window is not rewritten")
    check(scheduler.shouldSave(state: state, diskState: disk,
                               now: t.addingTimeInterval(301), lastSaveAt: lastSave),
          "an unchanged state past the heartbeat interval is rewritten")
    // A duplicate replay is rejected by the reducer (counted, but no content
    // changes) and must not trigger a save.
    reducer.ingest(sample(0, 43), into: &state)   // exact replay: rejected as out-of-order
    check(state.rejectedOutOfOrderCount == 1, "a duplicate replay is counted as rejected")
    check(state.current?.evidence.count == 1, "a rejected duplicate adds no evidence")
    check(!scheduler.shouldSave(state: state, diskState: disk,
                                now: t.addingTimeInterval(120), lastSaveAt: lastSave),
          "dedup: a rejected duplicate must not trigger a rewrite")
    // Any accepted change (including a still-unconfirmed candidate) is
    // persisted immediately, never deferred to the heartbeat.
    reducer.ingest(sample(600, 41), into: &state)   // 2pp drop on the same reset
    check(state.pendingTransition != nil, "a meaningful drop opens an abnormal candidate")
    check(scheduler.shouldSave(state: state, diskState: disk,
                               now: t.addingTimeInterval(121), lastSaveAt: lastSave),
          "candidate transitions save immediately")
    // A heartbeat decision never mutates the state: no equal-value evidence
    // is appended and the candidate is never compressed away.
    let evidenceBefore = state.current?.evidence.count
    let pendingBefore = state.pendingTransition
    _ = scheduler.shouldSave(state: state, diskState: disk,
                             now: t.addingTimeInterval(4000), lastSaveAt: lastSave)
    check(state.current?.evidence.count == evidenceBefore,
          "a heartbeat decision never appends evidence")
    check(state.pendingTransition == pendingBefore, "a heartbeat never compresses a candidate away")
    check(state != disk, "the candidate still marks the state as changed")
    print("PASS: saveDedupAndHeartbeat")

case "equivalentSampleDedup":
    let scheduler = QuotaCycleSaveScheduler(heartbeatInterval: 300)
    var state = QuotaCycleState()
    let reducer = makeReducer()
    reducer.ingest(sample(0, 43), into: &state)
    let disk = state
    // The first observation was persisted shortly after it arrived; the
    // equivalent sample below lands 200s after that save.
    let lastSave = t.addingTimeInterval(400)
    // An independent request (new requestStartedAt) with an unchanged
    // percentage on the same window is a heartbeat-equivalent sample.
    reducer.ingest(sample(600, 43), into: &state)
    check(state.current?.evidence.count == 1, "an equivalent sample must not grow evidence")
    check(state.current?.lastObservedAt == t.addingTimeInterval(600),
          "the in-memory last-observed time may advance")
    check(state.lastObservation?.observedAt == t.addingTimeInterval(600),
          "the in-memory last-observation marker may advance")
    check(!scheduler.shouldSave(state: state, diskState: disk,
                                now: t.addingTimeInterval(600), lastSaveAt: lastSave),
          "equivalent samples must not write before the heartbeat")
    check(scheduler.shouldSave(state: state, diskState: disk,
                               now: t.addingTimeInterval(700), lastSaveAt: lastSave),
          "equivalent samples are written at the heartbeat at the earliest")
    // A real percentage change still grows evidence and saves immediately.
    reducer.ingest(sample(700, 44), into: &state)
    check(state.current?.evidence.count == 2, "a percentage change grows evidence again")
    check(scheduler.shouldSave(state: state, diskState: disk,
                               now: t.addingTimeInterval(700), lastSaveAt: lastSave),
          "a percentage change still saves immediately")
    let savedAfterPercent = state
    let savedAfterPercentAt = t.addingTimeInterval(700)
    // Candidate transitions also stay immediate.
    reducer.ingest(sample(800, 42), into: &state)   // 2pp drop on the same reset
    check(state.pendingTransition != nil, "a meaningful drop opens a candidate")
    check(scheduler.shouldSave(state: state, diskState: savedAfterPercent,
                               now: t.addingTimeInterval(701), lastSaveAt: savedAfterPercentAt),
          "candidate creation still saves immediately")
    let savedAfterCandidate = state
    // Rollbacks also stay immediate.
    reducer.ingest(sample(900, 44), into: &state)   // back to the old window value
    check(state.pendingTransition == nil, "returning to the old window rolls back the candidate")
    check(state.rollbackCount == 1, "rollback is counted")
    check(scheduler.shouldSave(state: state, diskState: savedAfterCandidate,
                               now: t.addingTimeInterval(702), lastSaveAt: t.addingTimeInterval(701)),
          "a rollback still saves immediately")
    // Natural rotations also persist immediately.
    var rotated = QuotaCycleState()
    let rotationReducer = makeReducer()
    rotationReducer.ingest(sample(0, 10), into: &rotated)
    rotationReducer.ingest(sample(604700, 20), into: &rotated)
    let rotationDisk = rotated
    rotationReducer.ingest(sample(604900, 1, 1_209_600), into: &rotated)
    rotationReducer.ingest(sample(604950, 2, 1_209_600), into: &rotated)
    check(rotated.closed.count == 1, "rotation closes the old cycle")
    check(rotated.closed[0].end == .natural, "crossed deadline is a natural rotation")
    check(scheduler.shouldSave(state: rotated, diskState: rotationDisk,
                               now: t.addingTimeInterval(604950), lastSaveAt: t),
          "a rotation still saves immediately")
    print("PASS: equivalentSampleDedup")

case "loadFixesFilePermissions":
    let root = makeTempRoot()
    defer { removeTempRoot(root) }
    let store = QuotaCycleStore(root: root, writer: atomicWriter)
    let scope = try! store.scopeKey(apiKey: "fake-kimi-code-key")
    var state = QuotaCycleState()
    makeReducer().ingest(sample(0, 43), into: &state)
    try! store.save(state, scopeKey: scope)
    let file = root.appendingPathComponent(scope).appendingPathComponent("history-v1.json")
    // Simulate a history file left with looser permissions by an older build.
    try! FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: file.path)
    check(posixMode(file) == 0o644, "fixture loosened the file mode")
    let bytesBefore = try! Data(contentsOf: file)
    let loaded = try! store.load(scopeKey: scope)
    check(loaded == state, "load still returns the stored state")
    check(posixMode(file) == 0o600, "load enforces 0600 on an existing history file")
    check(try! Data(contentsOf: file) == bytesBefore,
          "permission repair never rewrites file bytes")
    print("PASS: loadFixesFilePermissions")

default:
    fputs("FAIL: unknown case \(CommandLine.arguments[1])\n", stderr)
    exit(1)
}
