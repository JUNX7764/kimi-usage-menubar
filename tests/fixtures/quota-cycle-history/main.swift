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

// MARK: - Task 4 helpers (coordinator/browser; explicit semaphores, no sleeps)

func makeCoordinator(
    root: URL,
    writer: @escaping QuotaCycleStore.Writer,
    onDeliver: @escaping (QuotaCycleSnapshot) -> Void,
    now: @escaping () -> Date
) -> QuotaCycleCoordinator {
    QuotaCycleCoordinator(
        root: root, writer: writer, deliver: onDeliver, now: now)
}

final class SnapshotRecorder {
    private let lock = NSLock()
    private var storage: [QuotaCycleSnapshot] = []

    func append(_ snapshot: QuotaCycleSnapshot) {
        lock.lock(); storage.append(snapshot); lock.unlock()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }; return storage.count
    }

    var last: QuotaCycleSnapshot? {
        lock.lock(); defer { lock.unlock() }; return storage.last
    }
}

func awaitDelivery(_ sem: DispatchSemaphore, _ what: String) {
    if sem.wait(timeout: .now() + .seconds(5)) == .timedOut {
        check(false, "timed out waiting for coordinator delivery: \(what)")
    }
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

case "snapshotStableValues":
    var state = QuotaCycleState()
    let reducer = makeReducer()
    reducer.ingest(sample(0, 72), into: &state)
    reducer.ingest(sample(604700, 80), into: &state)
    reducer.ingest(sample(604900, 3, 1_209_600), into: &state)
    check(state.pendingTransition != nil, "fixture expects a pending candidate")
    let snapshot = QuotaCycleSnapshot(
        loaded: true, closed: state.closed, current: state.current,
        pendingTransition: state.pendingTransition, persistenceFailed: false)
    check(snapshot.loaded, "snapshot marks the scope as loaded")
    check(snapshot.closed.isEmpty && snapshot.current != nil,
          "snapshot carries current and closed records")
    check(snapshot.pendingTransition?.firstNewWindowSample.usedPercent == 3,
          "snapshot exposes the pending candidate sample")
    check(!snapshot.persistenceFailed, "snapshot starts without a failure notice")
    check(snapshot.recordCount == 1, "recordCount counts current and closed")
    // Value semantics: later state mutations must not leak into the snapshot.
    reducer.ingest(sample(604920, 4, 1_209_600), into: &state)
    check(state.closed.count == 1, "fixture setup: confirmation closes the old cycle")
    check(snapshot.closed.isEmpty && snapshot.recordCount == 1,
          "a snapshot is a stable value independent of later state changes")
    check(snapshot.pendingTransition?.firstNewWindowSample.usedPercent == 3,
          "later confirmation must not mutate the earlier snapshot")
    let same = QuotaCycleSnapshot(
        loaded: true, closed: [], current: snapshot.current,
        pendingTransition: snapshot.pendingTransition, persistenceFailed: false)
    check(snapshot == same, "snapshots compare by value")
    print("PASS: snapshotStableValues")

case "browserPagingBounds":
    var browser = QuotaCycleBrowser()
    check(browser.visibleRange(total: 0) == 0..<0, "0 records show an empty page")
    check(browser.visibleRange(total: 1) == 0..<1, "1 record fills a short page")
    check(browser.visibleRange(total: 5) == 0..<5, "5 records do not pad to 6")
    check(browser.visibleRange(total: 6) == 0..<6, "6 records fill exactly one page")
    check(browser.visibleRange(total: 7) == 1..<7, "7 records overflow to the newest page")
    check(browser.visibleRange(total: 12) == 6..<12, "12 records keep the newest 6")
    check(browser.visibleRange(total: 13) == 7..<13, "13 records overflow again")
    check(browser.visibleRange(total: 25) == 19..<25, "25 records default to the newest 6")
    browser.showOlderPage()
    check(browser.visibleRange(total: 25) == 13..<19, "one older page moves back 6")
    check(browser.visibleRange(total: 13) == 1..<7, "the same anchor works on 13 records")
    browser.showOlderPage()
    check(browser.visibleRange(total: 13) == 0..<1,
          "the formula's oldest page shows the remaining record")
    browser.showOlderPage()
    browser.showOlderPage()
    check(browser.visibleRange(total: 13) == 0..<1,
          "pages clamp at the oldest records, never past the end")
    browser.showNewerPage()
    browser.showNewerPage()
    browser.showNewerPage()
    check(browser.visibleRange(total: 13) == 1..<7, "newer page moves toward the newest")
    browser.showNewerPage()
    check(browser.visibleRange(total: 13) == 7..<13,
          "newer paging clamps at the newest page, never below zero")
    check(browser.windowSize == 12, "the first browsing window is 12 records")
    browser.loadEarlier()
    check(browser.windowSize == 24, "loadEarlier extends the window by 12")
    browser.loadEarlier()
    check(browser.windowSize == 36, "loadEarlier keeps extending by 12")
    browser.reset()
    check(browser.olderPage == 0 && browser.selectedCycleID == nil,
          "reset clears the page anchor and the selection")
    check(browser.windowSize == 12, "reset restores the initial window")
    print("PASS: browserPagingBounds")

case "browserWindowedBrowsing":
    // 首批浏览最近 12 条，「更早记录」每次再扩展 12；页码基于可浏览条数 clamp，
    // 映射回全量索引后最旧一页恰好覆盖窗口起点（窗口是页大小的整数倍）。
    check(QuotaCycleBrowser.browsableCount(total: 0, windowSize: 12) == 0, "0 records browse empty")
    check(QuotaCycleBrowser.browsableCount(total: 13, windowSize: 12) == 12,
          "13 records browse only the first 12")
    check(QuotaCycleBrowser.hasMoreBeyondWindow(total: 13, windowSize: 12),
          "13 records with a 12 window have one record beyond")
    check(!QuotaCycleBrowser.hasMoreBeyondWindow(total: 12, windowSize: 12),
          "a full first window has nothing beyond")
    check(QuotaCycleBrowser.windowedRange(total: 13, windowSize: 12, pageOffset: 0) == 7..<13,
          "newest page shows the last 6 of 13")
    check(QuotaCycleBrowser.windowedRange(total: 13, windowSize: 12, pageOffset: 1) == 1..<7,
          "the older page stays inside the 12-record window")
    check(QuotaCycleBrowser.windowedRange(total: 13, windowSize: 12, pageOffset: 99) == 1..<7,
          "page offset clamps at the oldest loaded page")
    check(QuotaCycleBrowser.windowedRange(total: 25, windowSize: 12, pageOffset: 0) == 19..<25,
          "the windowed newest page never exposes records beyond the window")
    check(QuotaCycleBrowser.windowedRange(total: 25, windowSize: 24, pageOffset: 2) == 7..<13,
          "an extended window reaches further back")
    check(QuotaCycleBrowser.windowedRange(total: 4, windowSize: 12, pageOffset: 0) == 0..<4,
          "a short history keeps its real records without padding")
    // reveal：键盘逐组/跨页的稳定 ID 锚点。
    let revealIDs = (0..<25).map { UUID(uuidString: String(format: "%08d-0000-0000-0000-000000000000", $0))! }
    var revealBrowser = QuotaCycleBrowser()
    revealBrowser.reveal(revealIDs[3], chronologicalIDs: Array(revealIDs[0..<13]))
    check(revealBrowser.selectedCycleID == revealIDs[3], "reveal selects the target id")
    check(revealBrowser.olderPage == 1, "reveal anchors the page on the selection")
    check(revealBrowser.visibleRange(total: 13) == 1..<7,
          "reveal keeps the selection visible within the window")
    // 目标在当前窗口之外：仍记录选择，但页锚不动（调用方先 loadEarlier 扩展窗口）。
    revealBrowser.reveal(revealIDs[0], chronologicalIDs: revealIDs)
    check(revealBrowser.selectedCycleID == revealIDs[0],
          "an out-of-window reveal still records the selection")
    check(revealBrowser.olderPage == 1,
          "an out-of-window reveal must not move the page anchor")
    // 扩展窗口后 reveal 直达窗口内最旧记录所在页（24 窗口从 ids[1] 起）。
    revealBrowser.loadEarlier()   // 12 -> 24
    revealBrowser.reveal(revealIDs[1], chronologicalIDs: revealIDs)
    check(revealBrowser.olderPage == 3, "a 24-window reveal reaches the oldest loaded page of 25")
    let browsable25 = QuotaCycleBrowser.browsableCount(total: 25, windowSize: revealBrowser.windowSize)
    check(revealBrowser.visibleRange(total: browsable25) == 0..<6,
          "the oldest page shows the first window batch")
    // 再扩展一批（36 ≥ 25）后窗口覆盖全部记录，reveal 到真正的最旧一条。
    revealBrowser.loadEarlier()   // 24 -> 36
    revealBrowser.reveal(revealIDs[0], chronologicalIDs: revealIDs)
    check(revealBrowser.olderPage == 4, "a full-window reveal reaches the oldest record of 25")
    check(revealBrowser.visibleRange(total: 25) == 0..<1,
          "the oldest page shows the single remaining record")
    print("PASS: browserWindowedBrowsing")

case "browserKeepsPageOnNewRecords":
    var ids = (0..<25).map { UUID(uuidString: String(format: "%08d-0000-0000-0000-000000000000", $0))! }
    var browser = QuotaCycleBrowser()
    browser.select(ids[13])
    browser.showOlderPage()
    check(browser.visibleRange(total: ids.count).contains(13),
          "selected record is visible on the older page")
    // A new record arrives while the user browses history.
    ids.append(UUID(uuidString: "00000026-0000-0000-0000-000000000000")!)
    browser.noteRecordsChanged(chronologicalIDs: ids)
    check(browser.olderPage != 0, "new records must not jump back to the newest page")
    check(browser.visibleRange(total: ids.count).contains(13),
          "the selection stays visible after the record list changed")
    // A browser without a selection stays on the newest page.
    var fresh = QuotaCycleBrowser()
    fresh.noteRecordsChanged(chronologicalIDs: ids)
    check(fresh.olderPage == 0, "a fresh browser without selection stays newest")
    check(fresh.visibleRange(total: ids.count) == 20..<26,
          "the newest page still shows the latest records")
    // A selection on the newest page stays put when records arrive.
    var newest = QuotaCycleBrowser()
    newest.select(ids[25])
    newest.noteRecordsChanged(chronologicalIDs: ids)
    check(newest.olderPage == 0, "newest-page selection never jumps older")
    check(newest.visibleRange(total: ids.count).contains(25),
          "the newest record itself stays visible")
    // Credential scope switch is the only thing that resets browsing.
    browser.reset()
    check(browser.selectedCycleID == nil && browser.olderPage == 0,
          "scope switch resets the browser")
    print("PASS: browserKeepsPageOnNewRecords")

case "coordinatorActivatesAndPersists":
    let root = makeTempRoot()
    defer { removeTempRoot(root) }
    let recorder = SnapshotRecorder()
    let sem = DispatchSemaphore(value: 0)
    var writerCalls = 0
    let countingWriter: QuotaCycleStore.Writer = { data, url in
        writerCalls += 1
        try data.write(to: url, options: .atomic)
    }
    var nowValue = t
    let coordinator = makeCoordinator(root: root, writer: countingWriter,
        onDeliver: { snap in recorder.append(snap); sem.signal() },
        now: { nowValue })
    coordinator.activate(apiKey: "fake-key-A", generation: 1)
    awaitDelivery(sem, "activate")
    check(recorder.last?.loaded == true, "activation delivers a loaded snapshot")
    check(recorder.last?.current == nil, "a fresh scope starts empty")
    coordinator.observe(sample(0, 43), apiKey: "fake-key-A", generation: 1)
    awaitDelivery(sem, "first observation")
    check(recorder.last?.current?.lastObservedUsedPercent == 43,
          "observation reaches the UI snapshot")
    check(!recorder.last!.persistenceFailed, "a healthy scope has no failure notice")
    nowValue = t.addingTimeInterval(600)
    coordinator.observe(sample(600, 58), apiKey: "fake-key-A", generation: 1)
    awaitDelivery(sem, "second observation")
    check(recorder.last?.current?.lastObservedUsedPercent == 58,
          "serial reduce updates the delivered snapshot")
    // load → reduce → persist: a brand-new store sees the same state on disk.
    let store = QuotaCycleStore(root: root, writer: atomicWriter)
    let scope = try! store.scopeKey(apiKey: "fake-key-A")
    let disk = try! store.load(scopeKey: scope)
    check(disk.current?.lastObservedUsedPercent == 58,
          "serial load-reduce-persist reaches the scope partition")
    check(writerCalls >= 2, "each accepted change persisted through the injected writer")
    print("PASS: coordinatorActivatesAndPersists")

case "coordinatorScopeSwitchIsolatesUI":
    let root = makeTempRoot()
    defer { removeTempRoot(root) }
    let recorder = SnapshotRecorder()
    let sem = DispatchSemaphore(value: 0)
    let coordinator = makeCoordinator(root: root, writer: atomicWriter,
        onDeliver: { snap in recorder.append(snap); sem.signal() },
        now: { t })
    // Pre-seed scope A so a late load would show 43% if it ever won the UI.
    let seedStore = QuotaCycleStore(root: root, writer: atomicWriter)
    let scopeA = try! seedStore.scopeKey(apiKey: "fake-key-A")
    var seeded = QuotaCycleState()
    makeReducer().ingest(sample(0, 43), into: &seeded)
    try! seedStore.save(seeded, scopeKey: scopeA)
    coordinator.activate(apiKey: "fake-key-A", generation: 1)
    awaitDelivery(sem, "activate A")
    check(recorder.last?.current?.lastObservedUsedPercent == 43,
          "scope A loads its seeded history")
    // Immediate switch: the late activation of B must be the final UI state.
    coordinator.activate(apiKey: "fake-key-B", generation: 2)
    awaitDelivery(sem, "activate B")
    check(recorder.last?.current == nil && recorder.last?.loaded == true,
          "the late load for the new scope wins the UI")
    let countAfterSwitch = recorder.count
    // A late observation from the old scope: it may persist to its own
    // partition, but it must not be delivered as UI.
    // An independent request (fresh requestStartedAt) from the old scope.
    coordinator.observe(sample(600, 77), apiKey: "fake-key-A", generation: 1)
    // FIFO ordering: this B observation's delivery proves the stale A write
    // already completed without delivering.
    coordinator.observe(sample(0, 11), apiKey: "fake-key-B", generation: 2)
    awaitDelivery(sem, "B observation after stale A write")
    check(recorder.count == countAfterSwitch + 1,
          "old-scope observation must not deliver UI updates")
    check(recorder.last?.current?.lastObservedUsedPercent == 11,
          "the new scope's UI shows only its own data")
    // The old scope still wrote its own partition.
    let diskA = try! seedStore.load(scopeKey: scopeA)
    check(diskA.current?.lastObservedUsedPercent == 77,
          "the late old-scope observation persisted to its own partition")
    let scopeB = try! seedStore.scopeKey(apiKey: "fake-key-B")
    let diskB = try! seedStore.load(scopeKey: scopeB)
    check(diskB.current?.lastObservedUsedPercent == 11,
          "the new scope keeps its own history")
    check(scopeA != scopeB, "the two scopes use different partitions")
    print("PASS: coordinatorScopeSwitchIsolatesUI")

case "coordinatorWriteFailureNotice":
    let root = makeTempRoot()
    defer { removeTempRoot(root) }
    let recorder = SnapshotRecorder()
    let sem = DispatchSemaphore(value: 0)
    var failWrites = false
    let flakyWriter: QuotaCycleStore.Writer = { data, url in
        if failWrites {
            throw NSError(domain: "TestWriter", code: 1)
        }
        try data.write(to: url, options: .atomic)
    }
    var nowValue = t
    let coordinator = makeCoordinator(root: root, writer: flakyWriter,
        onDeliver: { snap in recorder.append(snap); sem.signal() },
        now: { nowValue })
    coordinator.activate(apiKey: "fake-key-A", generation: 1)
    awaitDelivery(sem, "activate")
    failWrites = true
    coordinator.observe(sample(0, 43), apiKey: "fake-key-A", generation: 1)
    awaitDelivery(sem, "failing save")
    check(recorder.last?.persistenceFailed == true,
          "a failed save surfaces the 「历史未保存」 notice in the snapshot")
    check(recorder.last?.current?.lastObservedUsedPercent == 43,
          "in-memory observation survives a write failure")
    // In-memory observation continues even while writes fail.
    nowValue = t.addingTimeInterval(600)
    coordinator.observe(sample(600, 58), apiKey: "fake-key-A", generation: 1)
    awaitDelivery(sem, "observation during write failure")
    check(recorder.last?.persistenceFailed == true,
          "the notice persists while writes keep failing")
    check(recorder.last?.current?.lastObservedUsedPercent == 58,
          "the reducer keeps accepting observations during write failure")
    // The last successful disk state is not clobbered.
    failWrites = false
    nowValue = t.addingTimeInterval(700)
    coordinator.observe(sample(700, 59), apiKey: "fake-key-A", generation: 1)
    awaitDelivery(sem, "recovered save")
    check(recorder.last?.persistenceFailed == false,
          "the first successful save clears the notice")
    let store = QuotaCycleStore(root: root, writer: atomicWriter)
    let scope = try! store.scopeKey(apiKey: "fake-key-A")
    let disk = try! store.load(scopeKey: scope)
    check(disk.current?.lastObservedUsedPercent == 59,
          "the recovered save persists the latest in-memory state")
    print("PASS: coordinatorWriteFailureNotice")

case "coordinatorHeartbeatNotDegraded":
    let root = makeTempRoot()
    defer { removeTempRoot(root) }
    let recorder = SnapshotRecorder()
    let sem = DispatchSemaphore(value: 0)
    var writerCalls = 0
    let countingWriter: QuotaCycleStore.Writer = { data, url in
        writerCalls += 1
        try data.write(to: url, options: .atomic)
    }
    var nowValue = t
    let coordinator = QuotaCycleCoordinator(
        root: root, writer: countingWriter,
        deliver: { snap in recorder.append(snap); sem.signal() },
        scheduler: QuotaCycleSaveScheduler(heartbeatInterval: 300),
        now: { nowValue })
    coordinator.activate(apiKey: "fake-key-A", generation: 1)
    awaitDelivery(sem, "activate")
    coordinator.observe(sample(0, 43), apiKey: "fake-key-A", generation: 1)
    awaitDelivery(sem, "first observation")
    check(writerCalls == 1, "the first observation saves exactly once")
    // Equivalent 10-second refresh samples must not write every time.
    for step in 1...5 {
        nowValue = t.addingTimeInterval(Double(step) * 10)
        coordinator.observe(sample(Double(step) * 10, 43),
                            apiKey: "fake-key-A", generation: 1)
        awaitDelivery(sem, "equivalent sample \(step)")
        check(recorder.last?.current?.lastObservedUsedPercent == 43,
              "equivalent sample \(step) still reaches the UI")
    }
    check(writerCalls == 1,
          "equivalent samples never degrade into per-refresh disk writes")
    check(recorder.last?.current?.evidence.count == 1,
          "equivalent samples stay deduplicated in the model")
    // Past the heartbeat the unchanged state is written once more.
    nowValue = t.addingTimeInterval(400)
    coordinator.observe(sample(400, 43), apiKey: "fake-key-A", generation: 1)
    awaitDelivery(sem, "heartbeat sample")
    check(writerCalls == 2, "the heartbeat writes the unchanged state once")
    print("PASS: coordinatorHeartbeatNotDegraded")

case "coordinatorRejectsStaleGeneration":
    let root = makeTempRoot()
    defer { removeTempRoot(root) }
    let recorder = SnapshotRecorder()
    let sem = DispatchSemaphore(value: 0)
    var writerCalls = 0
    let countingWriter: QuotaCycleStore.Writer = { data, url in
        writerCalls += 1
        try data.write(to: url, options: .atomic)
    }
    let coordinator = makeCoordinator(root: root, writer: countingWriter,
        onDeliver: { snap in recorder.append(snap); sem.signal() },
        now: { t })
    coordinator.activate(apiKey: "fake-key-A", generation: 1)
    awaitDelivery(sem, "activate generation 1")
    let countAfterActivate = recorder.count
    // A sample claiming a different generation of the same key is stale:
    // fully rejected — no reduce, no write, no delivery.
    coordinator.observe(sample(0, 91), apiKey: "fake-key-A", generation: 2)
    // FIFO: this current-generation observation's delivery proves the stale
    // sample was already processed (and rejected) without side effects.
    coordinator.observe(sample(0, 12), apiKey: "fake-key-A", generation: 1)
    awaitDelivery(sem, "current-generation observation")
    check(recorder.count == countAfterActivate + 1,
          "a stale-generation sample must not produce a UI delivery")
    check(recorder.last?.current?.lastObservedUsedPercent == 12,
          "the current generation keeps exclusive control of the UI")
    check(writerCalls == 1,
          "the stale-generation sample must not cause any disk write")
    // Direct disk evidence: only the current-generation sample is present.
    let store = QuotaCycleStore(root: root, writer: atomicWriter)
    let scope = try! store.scopeKey(apiKey: "fake-key-A")
    let disk = try! store.load(scopeKey: scope)
    check(disk.current?.lastObservedUsedPercent == 12,
          "only the current generation's observation reaches the partition")
    check(disk.current?.evidence.count == 1 && disk.closed.isEmpty,
          "the stale sample left no reduce artifacts in the state")
    check(disk.anomalousObservations.isEmpty,
          "the stale sample is not kept even as abnormal evidence")
    print("PASS: coordinatorRejectsStaleGeneration")

case "coordinatorRejectsStaleGenerationAfterRoundTrip":
    let root = makeTempRoot()
    defer { removeTempRoot(root) }
    let recorder = SnapshotRecorder()
    let sem = DispatchSemaphore(value: 0)
    var writerCalls = 0
    let countingWriter: QuotaCycleStore.Writer = { data, url in
        writerCalls += 1
        try data.write(to: url, options: .atomic)
    }
    let coordinator = makeCoordinator(root: root, writer: countingWriter,
        onDeliver: { snap in recorder.append(snap); sem.signal() },
        now: { t })
    coordinator.activate(apiKey: "fake-key-A", generation: 1)
    awaitDelivery(sem, "activate A generation 1")
    coordinator.observe(sample(0, 43), apiKey: "fake-key-A", generation: 1)
    awaitDelivery(sem, "A generation 1 observation")
    check(writerCalls == 1, "the first observation persists")
    // A → B → A: key A is re-activated under a newer generation.
    coordinator.activate(apiKey: "fake-key-B", generation: 2)
    awaitDelivery(sem, "activate B")
    coordinator.activate(apiKey: "fake-key-A", generation: 3)
    awaitDelivery(sem, "re-activate A generation 3")
    check(recorder.last?.current?.lastObservedUsedPercent == 43,
          "re-activation restores A's own persisted history")
    let callsAfterReactivate = writerCalls
    let countAfterReactivate = recorder.count
    let store = QuotaCycleStore(root: root, writer: atomicWriter)
    let scopeA = try! store.scopeKey(apiKey: "fake-key-A")
    let bytesBefore = try! Data(contentsOf:
        root.appendingPathComponent(scopeA).appendingPathComponent("history-v1.json"))
    // A late request from the superseded generation 1 round arrives now.
    coordinator.observe(sample(600, 91), apiKey: "fake-key-A", generation: 1)
    // FIFO: the generation-3 observation's delivery proves the stale sample
    // was processed and rejected without touching disk or UI.
    coordinator.observe(sample(700, 44), apiKey: "fake-key-A", generation: 3)
    awaitDelivery(sem, "generation 3 observation")
    check(recorder.count == countAfterReactivate + 1,
          "the stale generation-1 sample must not deliver UI updates")
    check(writerCalls == callsAfterReactivate + 1,
          "exactly one write: only the generation-3 observation persists")
    let bytesAfter = try! Data(contentsOf:
        root.appendingPathComponent(scopeA).appendingPathComponent("history-v1.json"))
    check(bytesAfter != bytesBefore,
          "the generation-3 observation rewrote the partition once")
    let disk = try! store.load(scopeKey: scopeA)
    check(disk.current?.lastObservedUsedPercent == 44,
          "the re-activated history continues from its own disk state")
    check(disk.current?.evidence.map(\.usedPercent) == [43, 44],
          "the stale 91%% sample left no trace in the persisted evidence")
    check(disk.closed.isEmpty && disk.anomalousObservations.isEmpty,
          "no fabricated cycles or evidence from the stale sample")
    print("PASS: coordinatorRejectsStaleGenerationAfterRoundTrip")

case "observedTimeRegressionRejected":
    var state = QuotaCycleState()
    let reducer = makeReducer()
    reducer.ingest(sample(600, 50), into: &state)
    let id = state.current?.id
    let regressed = QuotaObservation(
        requestStartedAt: t.addingTimeInterval(599.5),
        observedAt: t.addingTimeInterval(599.6),
        usedPercent: 91,
        resetAt: t.addingTimeInterval(604800))
    reducer.ingest(regressed, into: &state)
    check(state.current?.id == id, "time regression must keep the confirmed cycle")
    check(state.current?.lastObservedUsedPercent == 50,
          "time regression must not overwrite the current percentage")
    check(state.rejectedOutOfOrderCount == 1, "time regression is rejected")
    // Rejection must not advance lastRequestStartedAt and poison a later valid request.
    reducer.ingest(sample(900, 60), into: &state)
    check(state.current?.lastObservedUsedPercent == 60,
          "valid later observation still applies after time-regression rejection")
    print("PASS: observedTimeRegressionRejected")

default:
    fputs("FAIL: unknown case \(CommandLine.arguments[1])\n", stderr)
    exit(1)
}
