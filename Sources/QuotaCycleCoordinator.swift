import Foundation

/// Serial load → reduce → persist coordinator for the 7-day quota cycle
/// history.
///
/// One private utility queue serializes every store access, so a scope
/// activation, an observation and a save can never interleave. Each UI
/// delivery is built only from the currently active `(scopeKey, generation)`
/// context; a late load or a late observation from a superseded credential
/// scope may still persist to its own partition but is never delivered, so
/// it can never overwrite the new scope's UI.
///
/// Persistence reuses `QuotaCycleSaveScheduler`, so equivalent samples are
/// deduplicated in memory and only the five-minute heartbeat (or a real
/// state change) rewrites disk — the 10-second refresh poll never degrades
/// into per-poll writes.
final class QuotaCycleCoordinator {
    private let store: QuotaCycleStore
    private let scheduler: QuotaCycleSaveScheduler
    private let deliver: (QuotaCycleSnapshot) -> Void
    private let now: () -> Date
    private let queue = DispatchQueue(label: "KimiUsage.QuotaCycleCoordinator")
    private let reducer = QuotaCycleReducer()

    /// Everything the coordinator knows about one activated credential
    /// scope. Mutable parts are only touched on `queue`.
    private struct ScopeContext {
        var apiKey: String
        var scopeKey: String
        var generation: Int
        var state: QuotaCycleState
        /// The last state known to be on disk; `nil` before the first
        /// successful save of this activation.
        var diskState: QuotaCycleState?
        var lastSaveAt: Date?
        /// The scope's history file could not be read (corrupt or future
        /// schema). Writes stay suppressed so the original file is never
        /// auto-overwritten; in-memory observation continues.
        var loadFailed: Bool
        /// 「历史未保存」 notice for the UI; set on load/write failure and
        /// cleared by the next successful save.
        var persistenceFailed: Bool
    }

    private var active: ScopeContext?
    /// In-memory contexts of superseded scopes. A late observation for an
    /// old scope keeps updating (and persisting) that scope's own partition
    /// from here, without touching the active scope or the UI.
    private var staleScopes: [String: ScopeContext] = [:]
    /// apiKey → scopeKey, memory only. Raw keys never reach the store or UI.
    private var scopeKeyCache: [String: String] = [:]

    init(root: URL,
         writer: @escaping QuotaCycleStore.Writer,
         deliver: @escaping (QuotaCycleSnapshot) -> Void,
         scheduler: QuotaCycleSaveScheduler = QuotaCycleSaveScheduler(),
         now: @escaping () -> Date = Date.init) {
        self.store = QuotaCycleStore(root: root, writer: writer)
        self.scheduler = scheduler
        self.deliver = deliver
        self.now = now
    }

    /// Switch to a credential scope: derive its partition key, load the
    /// persisted history and deliver the first snapshot. Activations are
    /// serialized on the queue, so a superseded scope's late load can never
    /// be delivered after the newer activation's snapshot.
    func activate(apiKey: String, generation: Int) {
        queue.async {
            self.activateOnQueue(apiKey: apiKey, generation: generation)
        }
    }

    /// Fold one accepted 7-day observation into its credential scope and
    /// persist at the dedup/heartbeat cadence. Observations whose
    /// `(apiKey, generation)` does not match the active scope still reach
    /// their own partition but are never delivered to the UI.
    func observe(_ sample: QuotaObservation, apiKey: String, generation: Int) {
        queue.async {
            self.observeOnQueue(sample, apiKey: apiKey, generation: generation)
        }
    }

    // MARK: - Queue-private

    private func activateOnQueue(apiKey: String, generation: Int) {
        if let current = active,
           current.apiKey != apiKey || current.generation != generation {
            staleScopes[current.apiKey] = current
        }

        let scopeKey: String
        do {
            scopeKey = try cachedScopeKey(apiKey: apiKey)
        } catch {
            // Derivation failure disables history only; the existing quota
            // display keeps working and the UI gets a neutral snapshot.
            active = nil
            deliver(QuotaCycleSnapshot(
                loaded: false, closed: [], current: nil,
                pendingTransition: nil, persistenceFailed: true))
            return
        }

        var loaded = QuotaCycleState()
        var loadFailed = false
        do {
            loaded = try store.load(scopeKey: scopeKey)
        } catch {
            loadFailed = true
        }
        let context = ScopeContext(
            apiKey: apiKey, scopeKey: scopeKey, generation: generation,
            state: loaded, diskState: loadFailed ? nil : loaded,
            // A successful load counts as the persistence baseline, so an
            // unchanged history is not rewritten until the heartbeat.
            lastSaveAt: loadFailed ? nil : now(),
            loadFailed: loadFailed,
            persistenceFailed: loadFailed)
        active = context
        if loadFailed {
            // Never show another scope's data; the UI renders a neutral
            // 「读取历史」 state with the failure notice.
            deliver(QuotaCycleSnapshot(
                loaded: false, closed: [], current: nil,
                pendingTransition: nil, persistenceFailed: true))
        } else {
            deliver(snapshot(of: context))
        }
    }

    private func observeOnQueue(
        _ sample: QuotaObservation, apiKey: String, generation: Int
    ) {
        guard active != nil else { return }
        guard let scopeKey = try? cachedScopeKey(apiKey: apiKey) else { return }

        if let current = active,
           current.apiKey == apiKey && current.generation == generation {
            var context = current
            reducer.ingest(sample, into: &context.state)
            persistIfNeeded(&context)
            active = context
            deliver(snapshot(of: context))
            return
        }

        // Superseded scope: keep its own partition up to date, never UI.
        var context = staleScopes[apiKey]
            ?? loadStaleContext(apiKey: apiKey, scopeKey: scopeKey,
                                generation: generation)
        reducer.ingest(sample, into: &context.state)
        persistIfNeeded(&context)
        staleScopes[apiKey] = context
    }

    private func loadStaleContext(
        apiKey: String, scopeKey: String, generation: Int
    ) -> ScopeContext {
        var loaded = QuotaCycleState()
        var loadFailed = false
        if let onDisk = try? store.load(scopeKey: scopeKey) {
            loaded = onDisk
        } else {
            loadFailed = true
        }
        return ScopeContext(
            apiKey: apiKey, scopeKey: scopeKey, generation: generation,
            state: loaded, diskState: loadFailed ? nil : loaded,
            lastSaveAt: loadFailed ? nil : now(),
            loadFailed: loadFailed,
            persistenceFailed: loadFailed)
    }

    /// Persist through the injected writer only when the save scheduler says
    /// the state is new enough (first save, real change, or heartbeat). A
    /// failure keeps the last good disk state, keeps observing in memory and
    /// raises the snapshot's 「历史未保存」 notice; the next successful save
    /// clears it.
    private func persistIfNeeded(_ context: inout ScopeContext) {
        guard !context.loadFailed else { return }
        let currentTime = now()
        guard scheduler.shouldSave(
            state: context.state, diskState: context.diskState,
            now: currentTime, lastSaveAt: context.lastSaveAt
        ) else { return }
        do {
            try store.save(context.state, scopeKey: context.scopeKey)
            context.diskState = context.state
            context.lastSaveAt = currentTime
            context.persistenceFailed = false
        } catch {
            context.persistenceFailed = true
        }
    }

    private func snapshot(of context: ScopeContext) -> QuotaCycleSnapshot {
        QuotaCycleSnapshot(
            loaded: true,
            closed: context.state.closed,
            current: context.state.current,
            pendingTransition: context.state.pendingTransition,
            persistenceFailed: context.persistenceFailed)
    }

    private func cachedScopeKey(apiKey: String) throws -> String {
        if let cached = scopeKeyCache[apiKey] { return cached }
        let key = try store.scopeKey(apiKey: apiKey)
        scopeKeyCache[apiKey] = key
        return key
    }
}
