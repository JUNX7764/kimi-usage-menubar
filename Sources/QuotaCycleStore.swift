import Foundation
import CryptoKit

/// Failures here disable quota history only; they never block the existing
/// quota display. Derivation, load and save problems all surface as throws.
enum QuotaCycleStoreError: Error, Equatable {
    /// Scope keys must be the fixed-length hex produced by `scopeKey(apiKey:)`.
    case invalidScopeKey
    /// The per-root salt exists but is not the expected 32 random bytes.
    case invalidSalt
    /// Decoded or in-memory state failed structural validation.
    case corruptState(String)
    /// The file was written by a newer build; never downgrade or overwrite it.
    case unsupportedSchema(found: Int)
    /// A required permission could not be enforced.
    case permissionDenied(path: String)
}

/// Credential-scoped, versioned persistence for the 7-day quota cycle state.
///
/// Kimi has no reliable server-side stable user ID and the account endpoint is
/// a slow 5-minute poll, so the partition key is derived from the Kimi Code
/// API Key that the 7-day quota request itself used. A per-root random salt
/// keeps the hash unsalted-guess-resistant without ever storing the raw key:
/// `SHA256("kimi-quota-cycle-v1\0" + salt + UTF8(apiKey))` as fixed hex.
/// Rotating the API key starts a fresh partition — temporarily losing old
/// history is a deliberate security trade-off, never cross-account leakage.
final class QuotaCycleStore {
    typealias Writer = (Data, URL) throws -> Void

    static let saltFileName = "scope-salt"
    static let historyFileName = "history-v1.json"
    static let scopeKeyLength = 64
    static let saltLength = 32
    static let supportedSchemaVersion = QuotaCycleState.schemaVersion

    private let root: URL
    private let writer: Writer
    private let fileManager = FileManager()

    init(root: URL, writer: @escaping Writer) {
        self.root = root
        self.writer = writer
    }

    // MARK: - Credential scope derivation

    /// Derive the hex partition key for one API key, creating the per-root
    /// random salt on first use. The raw key and the unsalted hash are never
    /// persisted.
    func scopeKey(apiKey: String) throws -> String {
        try enforceDirectory(root, mode: 0o700)
        let saltURL = root.appendingPathComponent(Self.saltFileName)
        let salt: Data
        if fileManager.fileExists(atPath: saltURL.path) {
            salt = try Data(contentsOf: saltURL)
            guard salt.count == Self.saltLength else {
                throw QuotaCycleStoreError.invalidSalt
            }
        } else {
            var rng = SystemRandomNumberGenerator()
            salt = Data((0..<Self.saltLength).map { _ in
                UInt8.random(in: .min ... .max, using: &rng)
            })
            guard fileManager.createFile(
                atPath: saltURL.path, contents: salt,
                attributes: [.posixPermissions: NSNumber(value: 0o600)]
            ) else {
                throw QuotaCycleStoreError.permissionDenied(path: saltURL.path)
            }
            try enforceMode(saltURL, mode: 0o600)
        }

        var hasher = SHA256()
        hasher.update(data: Data("kimi-quota-cycle-v1\0".utf8))
        hasher.update(data: salt)
        hasher.update(data: Data(apiKey.utf8))
        let key = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        // Self-check: the derived value always satisfies the load/save gate.
        try validate(scopeKey: key)
        return key
    }

    // MARK: - Versioned load

    /// Load the state for one scope. A missing file is an empty state;
    /// corrupt or future-schema data throws and the file is left untouched.
    func load(scopeKey: String) throws -> QuotaCycleState {
        try validate(scopeKey: scopeKey)
        try enforceDirectory(root, mode: 0o700)
        let file = partitionURL(scopeKey: scopeKey)
            .appendingPathComponent(Self.historyFileName)
        guard fileManager.fileExists(atPath: file.path) else {
            return QuotaCycleState()
        }
        let data = try Data(contentsOf: file)
        let state: QuotaCycleState
        do {
            state = try JSONDecoder().decode(QuotaCycleState.self, from: data)
        } catch {
            throw QuotaCycleStoreError.corruptState("decode failed: \(error)")
        }
        try validateDecoded(state)
        return state
    }

    // MARK: - Atomic save through the injected writer

    /// Serialize and persist one state. The writer owns the atomic-replace
    /// strategy (production uses `AtomicJSONFile.replace(data, at:, mode: 0o600)`);
    /// directory and file modes are enforced here regardless. A thrown writer
    /// error propagates so the caller keeps its in-memory state and the last
    /// successful disk state stays intact.
    func save(_ state: QuotaCycleState, scopeKey: String) throws {
        try validate(scopeKey: scopeKey)
        try validateDecoded(state)
        let partition = partitionURL(scopeKey: scopeKey)
        try enforceDirectory(partition, mode: 0o700)
        let file = partition.appendingPathComponent(Self.historyFileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try writer(data, file)
        try enforceMode(file, mode: 0o600)
    }

    // MARK: - Validation

    private func validate(scopeKey: String) throws {
        guard scopeKey.count == Self.scopeKeyLength,
              scopeKey.range(
                of: "^[0-9a-f]{\(Self.scopeKeyLength)}$",
                options: .regularExpression) != nil
        else {
            throw QuotaCycleStoreError.invalidScopeKey
        }
    }

    /// Decode-time integrity gate: finite values, UUID uniqueness, temporal
    /// order. In particular every observation must keep
    /// `requestStartedAt <= observedAt` and evidence must be non-decreasing in
    /// both request and observation time, so a newer request paired with an
    /// older response can never move history backwards.
    private func validateDecoded(_ state: QuotaCycleState) throws {
        guard state.schemaVersion <= Self.supportedSchemaVersion else {
            throw QuotaCycleStoreError.unsupportedSchema(found: state.schemaVersion)
        }
        guard state.schemaVersion == Self.supportedSchemaVersion else {
            throw QuotaCycleStoreError.corruptState(
                "unexpected schemaVersion \(state.schemaVersion)")
        }

        var seenIDs = Set<UUID>()
        for record in state.closed {
            try validateRecord(record)
            guard seenIDs.insert(record.id).inserted else {
                throw QuotaCycleStoreError.corruptState("duplicate cycle id \(record.id)")
            }
        }
        if let current = state.current {
            try validateRecord(current)
            guard seenIDs.insert(current.id).inserted else {
                throw QuotaCycleStoreError.corruptState("duplicate cycle id \(current.id)")
            }
        }
        if let last = state.lastObservation, !last.isValid {
            throw QuotaCycleStoreError.corruptState("last observation is invalid")
        }
        if let pending = state.pendingTransition {
            guard pending.firstNewWindowSample.isValid else {
                throw QuotaCycleStoreError.corruptState("pending sample is invalid")
            }
            guard state.current?.id == pending.previousCycleID else {
                throw QuotaCycleStoreError.corruptState(
                    "pending transition references a missing cycle")
            }
        }

        var accepted = state.closed.flatMap(\.evidence)
        if let current = state.current { accepted.append(contentsOf: current.evidence) }
        if let pending = state.pendingTransition {
            accepted.append(pending.firstNewWindowSample)
        }
        if let lastStarted = state.lastRequestStartedAt,
           let newestAccepted = accepted.map(\.requestStartedAt).max(),
           newestAccepted > lastStarted {
            throw QuotaCycleStoreError.corruptState(
                "accepted evidence is newer than lastRequestStartedAt")
        }
    }

    private func validateRecord(_ record: QuotaCycleRecord) throws {
        guard record.firstObservedAt <= record.lastObservedAt else {
            throw QuotaCycleStoreError.corruptState("record observed times inverted")
        }
        guard record.expectedResetAt.timeIntervalSince1970.isFinite else {
            throw QuotaCycleStoreError.corruptState("record reset is not finite")
        }
        guard record.lastObservedUsedPercent.isFinite,
              (0...100).contains(record.lastObservedUsedPercent) else {
            throw QuotaCycleStoreError.corruptState("record percent is not finite/in range")
        }
        if let lower = record.boundaryLower, let upper = record.boundaryUpper,
           lower > upper {
            throw QuotaCycleStoreError.corruptState("record boundary inverted")
        }
        guard !record.evidence.isEmpty else {
            throw QuotaCycleStoreError.corruptState("record has no evidence")
        }
        for (index, observation) in record.evidence.enumerated() {
            guard observation.isValid else {
                throw QuotaCycleStoreError.corruptState("record evidence is invalid")
            }
            if index > 0 {
                let previous = record.evidence[index - 1]
                guard observation.requestStartedAt >= previous.requestStartedAt,
                      observation.observedAt >= previous.observedAt else {
                    throw QuotaCycleStoreError.corruptState(
                        "record evidence is not monotonic")
                }
            }
        }
    }

    // MARK: - Permission enforcement

    private func partitionURL(scopeKey: String) -> URL {
        root.appendingPathComponent(scopeKey, isDirectory: true)
    }

    private func enforceDirectory(_ url: URL, mode: UInt32) throws {
        if fileManager.fileExists(atPath: url.path) {
            try enforceMode(url, mode: mode)
        } else {
            try fileManager.createDirectory(
                at: url, withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: mode)])
            try enforceMode(url, mode: mode)
        }
    }

    /// Explicitly verify-and-fix permissions instead of trusting creation
    /// attributes or the writer's defaults.
    private func enforceMode(_ url: URL, mode: UInt32) throws {
        let key = FileAttributeKey.posixPermissions
        if posixMode(of: url) != mode {
            try fileManager.setAttributes(
                [key: NSNumber(value: mode)], ofItemAtPath: url.path)
        }
        guard posixMode(of: url) == mode else {
            throw QuotaCycleStoreError.permissionDenied(path: url.path)
        }
    }

    private func posixMode(of url: URL) -> UInt32? {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let number = attrs[.posixPermissions] as? NSNumber else { return nil }
        return UInt32(truncating: number) & 0o7777
    }
}

/// Pure save-frequency policy: persist on first save, on any accepted state
/// change (including pending candidates), or at most on the five-minute
/// heartbeat for a long-unchanged session. Decisions never mutate the state,
/// so a heartbeat rewrite never appends equal-value evidence and never
/// compresses a pending transition away. Time is injected for tests.
struct QuotaCycleSaveScheduler {
    var heartbeatInterval: TimeInterval

    init(heartbeatInterval: TimeInterval = 5 * 60) {
        self.heartbeatInterval = heartbeatInterval
    }

    /// Diagnostic-only counters never justify a write; only real content
    /// changes (percentages, cycles, candidates, evidence) do.
    func shouldSave(
        state: QuotaCycleState,
        diskState: QuotaCycleState?,
        now: Date,
        lastSaveAt: Date?
    ) -> Bool {
        if diskState == nil { return true }
        if hasMeaningfulChange(from: diskState, to: state) { return true }
        guard let lastSaveAt else { return true }
        return now.timeIntervalSince(lastSaveAt) >= heartbeatInterval
    }

    private func hasMeaningfulChange(
        from diskState: QuotaCycleState?, to state: QuotaCycleState
    ) -> Bool {
        guard let diskState else { return true }
        func normalized(_ input: QuotaCycleState) -> QuotaCycleState {
            var copy = input
            copy.rejectedInvalidCount = 0
            copy.rejectedOutOfOrderCount = 0
            copy.rejectedAmbiguousCount = 0
            copy.rollbackCount = 0
            copy.expiredCandidateCount = 0
            return copy
        }
        return normalized(diskState) != normalized(state)
    }
}
