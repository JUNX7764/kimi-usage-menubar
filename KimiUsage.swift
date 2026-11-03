import Cocoa
import Foundation
import SQLite3
import CoreFoundation
import Darwin

enum UsageNumber {
    static func finite(_ value: Any?) -> Double? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let number = Double(trimmed), number.isFinite else { return nil }
            return number
        }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    static func unitRatio(_ value: Any?) -> Double? {
        guard let number = finite(value), (0...1).contains(number) else { return nil }
        return number
    }
}

enum AtomicJSONFile {
    static func replace(_ data: Data, at path: String, mode: Int16? = nil) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let existingMode = (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)
            .map { Int16(truncating: $0) }
        let requested = mode ?? existingMode ?? 0o600
        let safeMode = requested & 0o600 == 0 ? 0o600 : requested & 0o600
        let temp = directory + "/." + (path as NSString).lastPathComponent + "." + UUID().uuidString + ".tmp"
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var fdOpen = true
        var shouldRemove = true
        defer {
            if fdOpen { _ = close(fd) }
            if shouldRemove { _ = unlink(temp) }
        }
        var offset = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < data.count {
                let count = write(fd, base.advanced(by: offset), data.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                guard count > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
                offset += count
            }
        }
        guard fchmod(fd, mode_t(safeMode)) == 0, fsync(fd) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard close(fd) == 0 else {
            fdOpen = false
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        fdOpen = false
        guard rename(temp, path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        shouldRemove = false
    }
}

/// One refresh at a time. A timer request during a refresh is dropped; manual requests coalesce
/// into at most one full follow-up round.
final class RefreshGate {
    private let lock = NSLock()
    private var active = false
    private var queuedManual = false

    func begin(manual: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !active else { if manual { queuedManual = true }; return false }
        active = true
        return true
    }

    /// Returns true when the caller must immediately run the queued manual round.
    func finish() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if queuedManual { queuedManual = false; return true }
        active = false
        return false
    }
}

enum RefreshSchedule {
    static func shouldRunSlow(manual: Bool, lastAttempt: Date?, now: Date) -> Bool {
        manual || lastAttempt.map { now.timeIntervalSince($0) >= 300 } ?? true
    }
}

enum DataFreshness {
    static func updated(_ previous: Date?, succeeded: Bool, at: Date) -> Date? {
        succeeded ? at : previous
    }

    static func isStale(lastSuccess: Date?, hasData: Bool, now: Date, after: TimeInterval) -> Bool {
        guard hasData else { return false }
        guard let lastSuccess = lastSuccess else { return true }
        return now.timeIntervalSince(lastSuccess) > after
    }
}

// MARK: - 凭证读取（与 Kimi 桌面端共用本地配置）

struct Credentials {
    var codeApiKey: String?   // credentials.kimiCode.apiKey
    var webToken: String?     // credentials.kimiWeb.accessToken
}

enum CredStore {
    static let configPath = NSHomeDirectory()
        + "/Library/Application Support/kimi-desktop/daimon-share/daimon/config.json"

    static func load() -> Credentials {
        guard let data = FileManager.default.contents(atPath: configPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cred = obj["credentials"] as? [String: Any] else {
            return Credentials(codeApiKey: nil, webToken: nil)
        }
        let code = cred["kimiCode"] as? [String: Any]
        let web = cred["kimiWeb"] as? [String: Any]
        return Credentials(codeApiKey: code?["apiKey"] as? String,
                           webToken: web?["accessToken"] as? String)
    }

    struct WebTokens {
        var access: String
        var refresh: String
    }

    static func webTokens(at path: String) -> WebTokens? {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let credentials = obj["credentials"] as? [String: Any],
              let web = credentials["kimiWeb"] as? [String: Any],
              let access = web["accessToken"] as? String, !access.isEmpty,
              let refresh = web["refreshToken"] as? String, !refresh.isEmpty else { return nil }
        return WebTokens(access: access, refresh: refresh)
    }

    /// Merge only rotated Kimi web credentials into the latest document. If the official client
    /// changed either auth field during the request, keep its values and return the fresh access token.
    static func mergeWebTokens(at path: String, expected: WebTokens,
                               access: String, refresh: String?, now: Date = Date()) throws -> (access: String, wrote: Bool) {
        guard let data = FileManager.default.contents(atPath: path),
              var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var credentials = obj["credentials"] as? [String: Any],
              var web = credentials["kimiWeb"] as? [String: Any],
              let latestAccess = web["accessToken"] as? String,
              let latestRefresh = web["refreshToken"] as? String else {
            throw NSError(domain: "KimiUsage.CredStore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "credential document missing required Kimi web fields"])
        }
        guard latestAccess == expected.access, latestRefresh == expected.refresh else {
            return (latestAccess, false)
        }
        web["accessToken"] = access
        if let refresh = refresh, !refresh.isEmpty { web["refreshToken"] = refresh }
        web["updatedAt"] = ISO8601DateFormatter().string(from: now)
        credentials["kimiWeb"] = web
        obj["credentials"] = credentials
        let updated = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try AtomicJSONFile.replace(updated, at: path)
        return (access, true)
    }
}

// MARK: - 用量数据模型

struct TokenStat {
    var input: Double = 0    // 含缓存读取/创建的输入
    var output: Double = 0
    var total: Double { input + output }
    var isEmpty: Bool { input == 0 && output == 0 }
}

struct UsageData {
    var fiveHourUsed: Double?      // 0..1
    var fiveHourReset: Date?
    var sevenDayUsed: Double?      // 0..1
    var sevenDayReset: Date?
    var monthUsed: Double?         // 0..1
    var monthReset: Date?
    var tokensToday: TokenStat?
    var tokens7d: TokenStat?
    var tokens30d: TokenStat?
    var cliTokensToday: TokenStat?
    var cliTokens7d: TokenStat?
    var cliTokens30d: TokenStat?
    var fiveHourError: String?
    var sevenDayError: String?
    var monthError: String?
    var workTokensError: String?   // Work 会话目录已安装但不可读（保留旧值、不推进成功时间）
    var cliTokensError: String?    // API 客户端来源全部不可读（同上）
    var updatedAt: Date = Date()
}

enum ScanStateFile {
    static func encoded<T: Encodable>(_ state: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(state)
    }

    /// Content-stable cache persistence: unchanged bytes are not rewritten.
    @discardableResult
    static func writeIfChanged(_ data: Data, to path: String) throws -> Bool {
        if let old = FileManager.default.contents(atPath: path), old == data { return false }
        try AtomicJSONFile.replace(data, at: path)
        return true
    }
}

// MARK: - 本地会话 token 统计（增量扫描 daimon wire.jsonl）
//
// 能耗优化（2026-09-15）：旧实现每 60s 全量读全部 jsonl（当时约 891 个文件 / 583MB），
// 单次扫描 ~17s CPU，常驻每天烧掉数小时 CPU。现改为增量扫描：
// 每个文件记录字节偏移 + 按日（本地时区 yyyy-MM-dd）聚合的 input/output，
// 持久化到 ~/Library/Application Support/KimiUsage/scan-state.json；
// 每次刷新未变化的文件只做一次 stat，有追加才读增量字节，
// 今日/近7天/近30天窗口由按日聚合即时求和（与旧逻辑等值）。

enum TokenAggregator {
    static let sessionsRoot = NSHomeDirectory()
        + "/Library/Application Support/kimi-desktop/daimon-share/daimon/runtime/kimi-code/home/sessions"
    // API 客户端会话目录：独立 Kimi Code CLI + Proma / Claude Code（Claude SDK 可混接多家 API）
    // 注意：Proma 会话日志位置两度迁移：sdk-config/projects →（≈2026-07）sdk-config/sessions →（≈2026-08-26）agent-sessions
    //（2026-10-09 实测：sdk-config/sessions 与 agent-sessions 是同一批会话的并行双写——
    //  近 40 天所有 Kimi 会话 workspace 两侧全有，简单会话数值完全一致、重会话 sdk 侧
    //  多记子请求/续写调用；两者都扫会双算，近 40 天多记 226.8M。只取 agent-sessions，
    //  与 Token Monitor 的 proma 来源同款口径；sdk 侧 08-26 前独有历史在 30 天窗口外）
    static let apiSessionsRoots = [
        NSHomeDirectory() + "/.kimi-code/sessions",
        NSHomeDirectory() + "/.proma/sdk-config/projects",
        NSHomeDirectory() + "/.proma/agent-sessions",
        NSHomeDirectory() + "/.claude/projects"
    ]

    // 按文件增量扫描状态：offset 为已消费字节数，days 为按日聚合 [input, output]
    struct FileScanState: Codable {
        var offset: UInt64 = 0
        var days: [String: [Double]] = [:]
    }
    struct ScanState: Codable {
        var work: [String: FileScanState] = [:]   // Kimi Work 本地会话
        var cli: [String: FileScanState] = [:]    // API 客户端（仅 Kimi 模型）
        var hermes: HermesState?                  // hermes（sqlite 快照差分）
    }
    /// hermes session_model_usage 是 (session,model,...) 级累计行：rows 存上次快照，
    /// 每次刷新做差，delta 按行的 last_seen 归入当日 days
    struct HermesState: Codable {
        var rows: [String: [Double]] = [:]   // rowKey -> [累计input, 累计output]
        var days: [String: [Double]] = [:]   // dayKey -> [input, output]
    }

    // v2：proma 源去掉 sdk-config/sessions 双写目录（口径变更）后弃用 v1 缓存强制重建
    static let statePath = NSHomeDirectory()
        + "/Library/Application Support/KimiUsage/scan-state-v2.json"
    private static var state: ScanState?
    private static let lock = NSLock()

    // 只关心近 30 天窗口，日聚合保留 31 天余量
    private static let retainSeconds: TimeInterval = 31 * 86400

    static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"   // 本地时区，与旧逻辑 Calendar.current 一致
        return f
    }()

    /// Claude SDK 客户端可经 ccswitch 接多家 API，按 model 字段甄别 Kimi；
    /// 无 model 字段的行默认计入（kimi-code 自有格式部分行无 model，且该客户端只接 Kimi）
    static func isKimiModel(_ model: String?) -> Bool {
        guard let m = model?.lowercased(), !m.isEmpty else { return true }
        if m.contains("kimi") || m.contains("moonshot") { return true }
        return m.hasPrefix("k") && m.count > 1 && m[m.index(after: m.startIndex)].isNumber
    }

    private static func loadState() -> ScanState {
        if let s = state { return s }
        if let data = FileManager.default.contents(atPath: statePath),
           let s = try? JSONDecoder().decode(ScanState.self, from: data) {
            state = s
            return s
        }
        let s = ScanState()
        state = s
        return s
    }

    private static func saveState(_ s: ScanState) {
        do { try ScanStateFile.writeIfChanged(ScanStateFile.encoded(s), to: statePath) }
        catch { NSLog("[KimiUsage] scan cache save failed: %@", error.localizedDescription) }
    }

    /// 双路统计 + 失败面：work/cli 各自的错误（已安装来源全部不可读时非 nil）
    struct BothStats {
        var work: (TokenStat, TokenStat, TokenStat)
        var cli: (TokenStat, TokenStat, TokenStat)
        var workError: String?
        var cliError: String?
    }

    /// Kimi Work 本地会话统计
    static func aggregateBoth() -> (work: (TokenStat, TokenStat, TokenStat), cli: (TokenStat, TokenStat, TokenStat)) {
        let d = aggregateBothDetailed()
        return (d.work, d.cli)
    }

    static func aggregateBothDetailed() -> BothStats {
        lock.lock(); defer { lock.unlock() }
        var st = loadState()
        let workScan = scan(roots: [sessionsRoot], kimiOnly: false, into: &st.work)
        let cliScan = scan(roots: apiSessionsRoots, kimiOnly: true, into: &st.cli)
        var hermesOK: Bool?   // nil = 未安装（state.db 不存在），不算失败
        if FileManager.default.fileExists(atPath: hermesDBPath) {
            hermesOK = scanHermes(into: &st)
        }
        state = st
        saveState(st)
        return BothStats(
            work: buckets(st.work), cli: buckets(st.cli, extraDays: st.hermes?.days),
            workError: sourceError(installed: workScan.installed, enumerated: workScan.enumerated, hermesOK: nil),
            cliError: sourceError(installed: cliScan.installed, enumerated: cliScan.enumerated, hermesOK: hermesOK))
    }

    /// 失败面判定：有已安装来源（目录存在 / hermes 库存在）但无一可读 → 错误；
    /// 全部未安装（路径不存在）返回 nil——没装对应工具时该来源自然为 0，不算失败；
    /// 部分来源可读仍按成功（增量状态保留旧贡献，下轮自愈）
    static func sourceError(installed: Int, enumerated: Int, hermesOK: Bool?) -> String? {
        let anySource = installed > 0 || hermesOK != nil
        let anySuccess = enumerated > 0 || hermesOK == true
        return (anySource && !anySuccess) ? "会话目录 / hermes state.db 均不可读" : nil
    }

    /// 窗口起算日：含今天共 7 / 30 个日历日（2026-11-03 起；此前为 8 / 31 天）
    static func windowCutoffs(now: Date) -> (d7: String, d30: String) {
        (dayFmt.string(from: now.addingTimeInterval(-6 * 86400)),
         dayFmt.string(from: now.addingTimeInterval(-29 * 86400)))
    }

    /// 兼容既有调用；主刷新使用 aggregateBoth 合并扫描和缓存写入。
    static func aggregate() -> (TokenStat, TokenStat, TokenStat) { aggregateBoth().work }

    /// API 客户端（CLI / Proma / Claude Code / hermes）中的 Kimi 用量统计
    static func aggregateCLI() -> (TokenStat, TokenStat, TokenStat) {
        aggregateBoth().cli
    }

    /// 全解析符号链接的绝对路径（realpath(3)）；路径不存在时原样返回。
    /// 枚举器产出的 url.path 是 realpath 形式（如 /var → /private/var；URL 的
    /// resolvingSymlinksInPath 不解析根级链接），前缀清理必须同口径才能匹配上
    private static func realPath(_ p: String) -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(p, &buf) != nil else { return p }
        return String(cString: buf)
    }

    /// 增量扫描 roots 下的 jsonl：未变化文件只 stat，追加文件只读新增字节；
    /// 已被删除的文件从状态中剔除（旧全量逻辑下删除即不再计入，保持一致）。
    /// 返回 (已安装 root 数, 成功枚举 root 数)：目录不存在 = 未安装，不计入失败面
    private static func scan(roots: [String], kimiOnly: Bool,
                             into files: inout [String: FileScanState]) -> (installed: Int, enumerated: Int) {
        let now = Date()
        let cutoff = now.addingTimeInterval(-retainSeconds)
        let cutoffKey = dayFmt.string(from: cutoff)
        var seen = Set<String>()
        var enumedRoots: [String] = []
        var installed = 0

        for root in roots {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir) else { continue }
            installed += 1
            // 不是目录（异常）或枚举失败都算该 root 不可读；未枚举成功不入 enumedRoots
            guard isDir.boolValue, let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles])
            else { continue }
            enumedRoots.append(realPath(root))

            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let path = url.path
                seen.insert(path)
                guard let vals = try? url.resourceValues(
                        forKeys: [.fileSizeKey, .contentModificationDateKey]),
                      let size = vals.fileSize
                else { continue }
                let sizeU = UInt64(size)
                var st = files[path] ?? FileScanState()
                // 文件只增不改：大小未变直接跳过（绝大多数文件走这里）
                if st.offset == sizeU { files[path] = st; continue }
                // 首次见到且 31 天未修改：不可能贡献近 30 天数据，记录大小后跳过
                if st.offset == 0, st.days.isEmpty,
                   let mtime = vals.contentModificationDate, mtime < cutoff {
                    st.offset = sizeU; files[path] = st; continue
                }
                // 截断/轮换：该文件的旧聚合已不可信，清零重扫
                if sizeU < st.offset { st = FileScanState() }

                guard let fh = try? FileHandle(forReadingFrom: url) else { continue }
                fh.seek(toFileOffset: st.offset)
                let data = fh.readDataToEndOfFile()
                try? fh.close()
                // 只消费到最后一个完整换行：正在被写入的残缺行留给下次
                guard let lastNL = data.lastIndex(of: UInt8(ascii: "\n")) else { continue }
                let consumed = st.offset + UInt64(lastNL + 1)
                if let text = String(data: data[..<lastNL], encoding: .utf8) {
                    parseLines(text, kimiOnly: kimiOnly, cutoffKey: cutoffKey, into: &st)
                }
                st.offset = consumed
                st.days = st.days.filter { $0.key >= cutoffKey }
                files[path] = st
            }
        }

        // 枚举成功的 root 里已不存在的文件：从状态剔除，停止计入窗口
        // （枚举失败的 root 不动，避免目录临时不可用时误清状态；
        //  先快照再删——迭代中变更字典可能跳过条目）
        let vanished = files.keys.filter { path in
            !seen.contains(path) && enumedRoots.contains(where: { path.hasPrefix($0 + "/") })
        }
        for path in vanished {
            files.removeValue(forKey: path)
        }
        return (installed, enumedRoots.count)
    }

    // hermes 用量库（sqlite，只读打开，绝不写入）
    private static let hermesDBPath = NSHomeDirectory() + "/.hermes/state.db"

    /// hermes 的 Kimi 用量：只读查询 billing_base_url 指向 kimi.com / moonshot 的累计行
    /// （全表仅千余行、命中百余行，每次刷新一次查询开销可忽略，不新增定时器）；
    /// 与持久化的上次快照做差，delta 按 last_seen 归日。首次运行会把存量行的累计值
    /// 归入各自 last_seen 当天，相当于自动回填近 30 天窗口。
    /// 返回是否成功读取（库文件不存在由调用方先行排除，不算失败）。
    private static func scanHermes(into st: inout ScanState) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(hermesDBPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
        else { return false }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT session_id, model, billing_provider, billing_base_url, billing_mode, task,
                   input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, last_seen
            FROM session_model_usage
            WHERE billing_base_url LIKE '%kimi.com%' OR billing_base_url LIKE '%moonshot%'
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }

        let cutoffKey = dayFmt.string(from: Date().addingTimeInterval(-retainSeconds))
        var hs = st.hermes ?? HermesState()
        var alive = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            func col(_ i: Int32) -> String {
                sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? ""
            }
            let key = (0...5).map { col(Int32($0)) }.joined(separator: "|")
            alive.insert(key)
            // 与文件来源口径一致：input 含 cache read/write
            let cumIn = Double(sqlite3_column_int64(stmt, 6))
                + Double(sqlite3_column_int64(stmt, 8))
                + Double(sqlite3_column_int64(stmt, 9))
            let cumOut = Double(sqlite3_column_int64(stmt, 7))
            let lastSeen = sqlite3_column_double(stmt, 10)
            let old = hs.rows[key] ?? [0, 0]
            var dIn = cumIn - old[0], dOut = cumOut - old[1]
            if dIn < 0 || dOut < 0 { dIn = max(dIn, 0); dOut = max(dOut, 0) }  // 计数被重置：rebase，不倒扣
            hs.rows[key] = [cumIn, cumOut]
            guard dIn > 0 || dOut > 0, lastSeen > 0 else { continue }
            let dayKey = dayFmt.string(from: Date(timeIntervalSince1970: lastSeen))
            if dayKey >= cutoffKey {
                var day = hs.days[dayKey] ?? [0, 0]
                day[0] += dIn; day[1] += dOut
                hs.days[dayKey] = day
            }
        }
        // 会话被 hermes 删除（ON DELETE CASCADE）的行：移出快照，停止计入
        hs.rows = hs.rows.filter { alive.contains($0.key) }
        hs.days = hs.days.filter { $0.key >= cutoffKey }
        st.hermes = hs
        return true
    }

    /// 解析一批完整行，把 usage 按日累加进 st.days（解析逻辑与旧全量版一致）
    private static func parseLines(_ text: String, kimiOnly: Bool,
                                   cutoffKey: String, into st: inout FileScanState) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true)
        where line.contains("\"usage\"") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            // Proma result 行的 modelUsage / 顶层 usage 是全会话累计汇总，
            // 逐条 assistant 行（message.usage）已含每次调用，跳过汇总行避免双算
            if obj["modelUsage"] != nil { continue }
            // 时间：kimi 系为 time(ms epoch)；Claude SDK 为 timestamp(ISO8601)；Proma 会话为 _createdAt(ms)
            let t: Date
            if let ms = obj["time"] as? Double {
                t = Date(timeIntervalSince1970: ms / 1000)
            } else if let ts = ISO.parse(obj["timestamp"] as? String) {
                t = ts
            } else if let ms = obj["_createdAt"] as? Double {
                t = Date(timeIntervalSince1970: ms / 1000)
            } else { continue }
            // usage 位置：event.usage（Kimi Work）/ 顶层（kimi-code CLI）/ message.usage（Claude SDK）
            let usage = (obj["event"] as? [String: Any])?["usage"] as? [String: Any]
                ?? obj["usage"] as? [String: Any]
                ?? (obj["message"] as? [String: Any])?["usage"] as? [String: Any]
            guard let usage = usage else { continue }
            // 混接客户端只统计 Kimi 模型的行
            if kimiOnly {
                let model = (obj["message"] as? [String: Any])?["model"] as? String
                    ?? obj["model"] as? String
                guard isKimiModel(model) else { continue }
            }
            // 字段：kimi 系 inputOther/inputCache*/output；Claude 系 *_tokens；Proma SDK 系 input/output/cacheRead/cacheWrite
            var input: Double = 0
            for k in ["inputOther", "inputCacheRead", "inputCacheCreation",
                      "input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens",
                      "input", "cacheRead", "cacheWrite"] {
                if let v = usage[k] as? Double { input += v }
                else if let v = usage[k] as? Int { input += Double(v) }
            }
            var output: Double = 0
            for k in ["output", "output_tokens"] {
                if let v = usage[k] as? Double { output += v }
                else if let v = usage[k] as? Int { output += Double(v) }
            }

            let dayKey = dayFmt.string(from: t)
            if dayKey >= cutoffKey {
                var day = st.days[dayKey] ?? [0, 0]
                day[0] += input
                day[1] += output
                st.days[dayKey] = day
            }
        }
    }

    /// 按日聚合 → 今日/近7天/近30天三个窗口；extraDays 用于合并非文件来源（hermes）
    private static func buckets(_ files: [String: FileScanState],
                                extraDays: [String: [Double]]? = nil)
        -> (TokenStat, TokenStat, TokenStat) {
        let now = Date()
        let todayKey = dayFmt.string(from: now)
        let (d7Key, d30Key) = windowCutoffs(now: now)
        var today = TokenStat(), week = TokenStat(), month = TokenStat()
        var allDays: [String: [Double]] = [:]
        for (_, st) in files {
            for (day, v) in st.days {
                var a = allDays[day] ?? [0, 0]
                a[0] += v[0]; a[1] += v[1]
                allDays[day] = a
            }
        }
        if let extra = extraDays {
            for (day, v) in extra {
                var a = allDays[day] ?? [0, 0]
                a[0] += v[0]; a[1] += v[1]
                allDays[day] = a
            }
        }
        for (day, v) in allDays where day >= d30Key {
            month.input += v[0]; month.output += v[1]
            if day >= d7Key { week.input += v[0]; week.output += v[1] }
            if day >= todayKey { today.input += v[0]; today.output += v[1] }
        }
        return (today, week, month)
    }
}

/// Token 窗口明细的树形行：今日/近 7 天/近 30 天各一行，├ 分支 └ 收尾、两空格缩进
/// （与 GlmUsage 的模型明细、CodexUsage 的窗口明细同款呈现）；无数据显示「暂无记录」
enum TokenWindowLines {
    static func render(_ rows: [(label: String, stat: TokenStat?)]) -> [String] {
        rows.enumerated().map { index, row in
            let branch = index < rows.count - 1 ? "├" : "└"
            guard let s = row.stat, !s.isEmpty else { return "  \(branch) \(row.label)：暂无记录" }
            return "  \(branch) \(row.label)：入 \(Fmt.tokens(s.input)) · 出 \(Fmt.tokens(s.output)) · 计 \(Fmt.tokens(s.total))"
        }
    }
}

enum ISO {
    // formatter 创建有开销，复用静态实例（旧实现每次调用新建，全量扫描时是热点）
    private static let frac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static func parse(_ s: String?) -> Date? {
        guard let s = s else { return nil }
        return frac.date(from: s) ?? plain.date(from: s)
    }
}

// MARK: - 网络请求

enum Fetcher {

    /// 用 refreshToken 自刷新 web token（GET /api/auth/token/refresh，Bearer 带 refreshToken）。
    /// 服务端每次会轮换 refresh_token，必须把新 token 对写回 config.json，否则刷新链会断。
    /// 成功返回新 accessToken（寿命 ~30 天），失败返回 nil。
    static func refreshWebToken(completion: @escaping (String?) -> Void) {
        let path = CredStore.configPath
        // Re-read immediately before the request because the official desktop client may rotate tokens.
        guard let expected = CredStore.webTokens(at: path) else { completion(nil); return }
        guard let url = URL(string: "https://www.kimi.com/api/auth/token/refresh") else {
            completion(nil); return
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "GET"
        req.setValue("Bearer \(expected.refresh)", forHTTPHeaderField: "Authorization")
        req.setValue("mac", forHTTPHeaderField: "x-msh-platform")
        req.setValue("3.1.2", forHTTPHeaderField: "x-msh-version")
        req.setValue("KimiUsage-Menubar/1.0", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            guard err == nil, let data = data,
                  let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let at = body["access_token"] as? String, !at.isEmpty else {
                completion(nil); return
            }
            do {
                let write = try CredStore.mergeWebTokens(at: path, expected: expected,
                    access: at, refresh: body["refresh_token"] as? String)
                if write.wrote { NSLog("[KimiUsage] web token self-refresh saved") }
                else { NSLog("[KimiUsage] web token changed by Kimi client during refresh; kept latest credentials") }
                completion(write.access)
            } catch {
                NSLog("[KimiUsage] web token refresh write failed: %@", error.localizedDescription)
                completion(nil)
            }
        }.resume()
    }

    /// 5 小时 + 7 天窗口：kimi-code 用量接口
    static func parseCodeUsagePayload(_ obj: [String: Any]) -> UsageData {
        var result = UsageData()
        if let usage = obj["usage"] as? [String: Any],
           let limit = UsageNumber.finite(usage["limit"]), limit > 0,
           let remaining = UsageNumber.finite(usage["remaining"]), remaining >= 0,
           remaining <= limit {
            result.sevenDayUsed = (limit - remaining) / limit
            result.sevenDayReset = ISO.parse(usage["resetTime"] as? String)
        } else {
            result.sevenDayError = "missing or invalid 7D usage limit/remaining"
        }

        var sawFiveHour = false
        if let limits = obj["limits"] as? [[String: Any]] {
            for entry in limits {
                guard let window = entry["window"] as? [String: Any],
                      let detail = entry["detail"] as? [String: Any] else { continue }
                let dur = window["duration"] as? Int ?? 0
                let unit = window["timeUnit"] as? String ?? ""
                let isFiveHour = (unit == "TIME_UNIT_MINUTE" && dur == 300)
                    || (unit == "TIME_UNIT_HOUR" && dur == 5)
                guard isFiveHour else { continue }
                sawFiveHour = true
                guard let limit = UsageNumber.finite(detail["limit"]), limit > 0 else { continue }
                let ratio: Double?
                if detail["used"] != nil {
                    if let used = UsageNumber.finite(detail["used"]), used >= 0, used <= limit {
                        ratio = used / limit
                    } else { ratio = nil }
                } else if let remaining = UsageNumber.finite(detail["remaining"]),
                          remaining >= 0, remaining <= limit {
                    ratio = (limit - remaining) / limit
                } else { ratio = nil }
                guard let validRatio = ratio else { continue }
                result.fiveHourUsed = validRatio
                result.fiveHourReset = ISO.parse(detail["resetTime"] as? String)
                break
            }
        }
        if result.fiveHourUsed == nil {
            result.fiveHourError = sawFiveHour ? "invalid 5H usage limit/used/remaining" : "missing 5H window"
        }
        return result
    }

    static func fetchCodeUsage(apiKey: String, completion: @escaping (UsageData) -> Void) {
        var result = UsageData()
        guard let url = URL(string: "https://api.kimi.com/coding/v1/usages") else {
            result.fiveHourError = "bad url"; result.sevenDayError = "bad url"
            completion(result); return
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("KimiUsage-Menubar/1.0", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { completion(result) }
            guard err == nil, let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let reason = err?.localizedDescription ?? "bad response"
                result.fiveHourError = reason
                result.sevenDayError = reason
                return
            }
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                result.fiveHourError = "HTTP \(http.statusCode)"
                result.sevenDayError = "HTTP \(http.statusCode)"
                return
            }
            result = parseCodeUsagePayload(obj)
        }.resume()
    }

    /// 本月总额度：Kimi 订阅接口（OMNI 余额）
    static func parseMonthUsagePayload(_ obj: [String: Any]) -> UsageData {
        var result = UsageData()
        if let balances = obj["balances"] as? [[String: Any]],
           let balance = balances.first(where: { ($0["feature"] as? String) == "FEATURE_OMNI" }) {
            result.monthUsed = UsageNumber.unitRatio(balance["amountUsedRatio"])
            result.monthReset = ISO.parse(balance["expireTime"] as? String)
            if result.monthUsed == nil { result.monthError = "invalid amountUsedRatio" }
        } else {
            result.monthError = "no omni balance"
        }
        return result
    }

    static func fetchMonthUsage(webToken: String, completion: @escaping (UsageData) -> Void) {
        var result = UsageData()
        let urlStr = "https://www.kimi.com/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscription"
        guard let url = URL(string: urlStr) else { result.monthError = "bad url"; completion(result); return }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.httpBody = "{}".data(using: .utf8)
        req.setValue("Bearer \(webToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("mac", forHTTPHeaderField: "x-msh-platform")
        req.setValue("3.1.2", forHTTPHeaderField: "x-msh-version")
        req.setValue("KimiUsage-Menubar/1.0", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { completion(result) }
            guard err == nil, let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                result.monthError = err?.localizedDescription ?? "bad response"
                return
            }
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                result.monthError = "HTTP \(http.statusCode)"
                return
            }
            result = parseMonthUsagePayload(obj)
        }.resume()
    }
}

// MARK: - 菜单栏堆叠两行文字渲染

enum StackImage {
    static func make(line1: String, line2: String) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9.0, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        let s1 = NSAttributedString(string: line1, attributes: attrs)
        let s2 = NSAttributedString(string: line2, attributes: attrs)
        let w = max(s1.size().width, s2.size().width) + 2
        let h: CGFloat = 21
        let img = NSImage(size: NSSize(width: ceil(w), height: h))
        img.lockFocus()
        s1.draw(at: NSPoint(x: 1, y: 10.5))
        s2.draw(at: NSPoint(x: 1, y: 0.5))
        img.unlockFocus()
        img.isTemplate = true   // 自动适配深色/浅色菜单栏
        return img
    }
}

// MARK: - 格式化

enum Fmt {
    static func pct(_ v: Double?) -> String {
        guard let v = v else { return "--" }
        let p = v * 100
        if p > 0 && p < 1 { return "<1%" }
        return String(format: "%.0f%%", p)
    }
    static func pctLong(_ v: Double?) -> String {
        guard let v = v else { return "暂无数据" }
        return String(format: "%.2f%%", v * 100)
    }
    // 展示用 formatter 静态缓存：菜单每轮重建要调多次，新建 DateFormatter 开销大
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f
    }()
    private static let dayTimeFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()
    static func time(_ d: Date?) -> String {
        guard let d = d else { return "" }
        return timeFmt.string(from: d)
    }
    // 最后成功时间的占位口径：无记录用 "--"（time() 对 nil 返回空串，不适合过期提示行）
    static func lastOK(_ d: Date?) -> String {
        guard let d = d else { return "--" }
        return time(d)
    }
    // 自诊断 JSON 用；仅主线程调用，static 单次构造避免每次刷新重复分配
    static let iso8601 = ISO8601DateFormatter()
    static func dayTime(_ d: Date?) -> String {
        guard let d = d else { return "" }
        return dayTimeFmt.string(from: d)
    }
    // token 数量缩写：999 / 12.3K / 1.23M / 1.23B
    static func tokens(_ v: Double) -> String {
        if v >= 1_000_000_000 { return String(format: "%.2fB", v / 1_000_000_000) }
        if v >= 1_000_000 { return String(format: "%.2fM", v / 1_000_000) }
        if v >= 10_000 { return String(format: "%.1fK", v / 1_000) }
        if v >= 1_000 { return String(format: "%.2fK", v / 1_000) }
        return String(format: "%.0f", v)
    }
}

// MARK: - 版本与更新检查（成熟项目惯例，Sparkle 生态同款语义：只认 GitHub Release，
// 不认 main 分支 commit——日常 push 与用户无关，发布了更高版本才提示。
// build.sh 打包时写 Info.plist 自定义键；就地更新脚本随包内置，见 Resources/update.sh）

/// 构建版本：build.sh 打包时写入产物 Info.plist 自定义键（CUBuildVersion，git describe），
/// 运行时读 Bundle。仓库模板没有该键 → 非 build.sh 产物（直接 swiftc 的裸二进制）为 unknown，
/// 此时更新检查自然禁用、菜单显示「版本 unknown」。不生成第二个 .swift：多文件编译下
/// 只有 main.swift 允许 top-level 代码，本文件的命令行入口依赖 top-level。
enum BuildInfo {
    static let version = (Bundle.main.infoDictionary?["CUBuildVersion"] as? String) ?? "unknown"
}

/// 更新判定的纯逻辑：Release 版本号比较（--self-test 覆盖）。
/// 提示的唯一触发条件是「GitHub 发布了更高版本的 Release」；commit hash 回答的是
/// 「分支动没动」，不代表存在可安装的新版本。
enum UpdateCheck {
    static let apiURL = URL(string: "https://api.github.com/repos/JUNX7764/kimi-usage-menubar/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/JUNX7764/kimi-usage-menubar/releases")!
    /// GitHub 匿名限额 60 次/小时/IP，30 分钟一查仅 2 次/小时；ETag/304 条件请求不耗配额
    static let interval: TimeInterval = 30 * 60

    /// 版本号归一化：v1.0.1 / v1.0.1-3-gabc / v1.0.1-dirty → [1, 0, 1]；
    /// 破折号后缀（预发布/dirty/git describe 尾巴）丢弃，任一段非数字视为无法比较
    static func normalized(_ v: String) -> [Int]? {
        var core = v.trimmingCharacters(in: .whitespaces).lowercased()
        guard !core.isEmpty else { return nil }
        if core.hasPrefix("v") { core.removeFirst() }
        if let dash = core.firstIndex(of: "-") { core = String(core[..<dash]) }
        guard !core.isEmpty else { return nil }
        var parts: [Int] = []
        for seg in core.split(separator: ".") {
            guard let n = Int(seg), n >= 0 else { return nil }
            parts.append(n)
        }
        return parts.isEmpty ? nil : parts
    }

    /// 已装版本是否低于远端 Release 版本。任一侧无法解析（unknown / 裸二进制 / 非法 tag）
    /// = 不提示；逐段数值比较（1.10 > 1.9），短侧补 0（1.2 == 1.2.0）
    static func isOutdated(local: String, remote: String) -> Bool {
        guard var l = normalized(local), var r = normalized(remote) else { return false }
        if l.count < r.count { l.append(contentsOf: repeatElement(0, count: r.count - l.count)) }
        if r.count < l.count { r.append(contentsOf: repeatElement(0, count: l.count - r.count)) }
        for i in 0..<l.count where l[i] != r[i] {
            return l[i] < r[i]
        }
        return false
    }
}

/// 更新检查状态：低频匿名请求 GitHub，失败静默保留旧结论（不打扰主刷新，也不弹任何东西）。
/// 状态只在主线程读写（回调统一 dispatch 回主线程），无需加锁。
final class UpdateChecker {
    static let shared = UpdateChecker()
    private(set) var available = false
    private var etag: String?
    private var lastCheck: Date?
    private var inFlight = false
    private var waiters: [() -> Void] = []
    private(set) var lastError = false

    /// force=false 时按 interval 节流；completion 固定主线程回调
    func check(force: Bool = false, completion: @escaping () -> Void = {}) {
        if inFlight { waiters.append(completion); return }
        if !force, let last = lastCheck, Date().timeIntervalSince(last) < UpdateCheck.interval {
            completion()
            return
        }
        inFlight = true
        var req = URLRequest(url: UpdateCheck.apiURL, timeoutInterval: 15)
        req.cachePolicy = .reloadIgnoringLocalCacheData   // ETag/304 语义自己管，不用 URLCache
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("KimiUsage/1.0 (menubar; update check)", forHTTPHeaderField: "User-Agent")
        if let etag = etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.inFlight = false
                self.lastCheck = Date()
                let http = resp as? HTTPURLResponse
                self.lastError = !(http?.statusCode == 304 || (err == nil && http?.statusCode == 200 && data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["tag_name"] is String))
                if http?.statusCode == 304 {
                    // 内容未变：结论保持
                } else if err == nil, let data = data, http?.statusCode == 200,
                          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                          let tag = obj["tag_name"] as? String {
                    self.available = UpdateCheck.isOutdated(local: BuildInfo.version, remote: tag)
                    if let e = http?.value(forHTTPHeaderField: "ETag"), !e.isEmpty { self.etag = e }
                }
                completion()
                let pending = self.waiters
                self.waiters.removeAll()
                pending.forEach { $0() }
            }
        }.resume()
    }
}

enum RemainingColorTier: Equatable {
    case green, normal, orange, red

    init(remaining: Int?) {
        guard let remaining = remaining else { self = .normal; return }
        switch remaining {
        case 80...: self = .green
        case 40..<80: self = .normal
        case 20..<40: self = .orange
        default: self = .red
        }
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255,
                alpha: 1)
    }

    func color(for appearance: NSAppearance) -> NSColor {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        switch self {
        case .green: return Self.rgb(dark ? 0x96CDA7 : 0x3E8660)
        case .normal: return .labelColor
        case .orange: return Self.rgb(dark ? 0xE5A37D : 0xB46539)
        case .red: return Self.rgb(dark ? 0xF08B94 : 0xC8404A)
        }
    }
}


// MARK: - 自定义下拉面板（typed model + 原生 AppKit 组件）

struct UsagePanelModel {
    enum NoticeLevel {
        case info, warning, error
    }
    struct Notice {
        var text: String
        var level: NoticeLevel
    }
    struct Quota {
        var title: String
        var resetText: String
        var remaining: Int?
        var notices: [Notice]
    }
    struct ResetRow {
        var name: String
        var expires: String
        var warning: Bool
    }
    struct ResetSection {
        var count: Int?
        var emptyText: String?
        var rows: [ResetRow]
        var notices: [Notice]
    }
    struct TiboRow {
        var text: String
        var item: NSMenuItem?
    }
    struct TiboSection {
        var rows: [TiboRow]
        var notices: [Notice]
    }
    struct TokenBucket {
        var summaryLabel: String
        var detailLabel: String
        var total: String
        var input: String
        var output: String
    }
    struct TokenSection {
        var title: String
        var accent: PanelAccent
        var buckets: [TokenBucket]
        var notices: [Notice]
    }

    var updateItem: NSMenuItem?
    var title: String
    var email: String?
    var quotas: [Quota]
    var resetCards: ResetSection?
    var tibo: TiboSection?
    var codexTokens: TokenSection
    var externalTokens: TokenSection?
    var notices: [Notice]
    var lastAttempt: String
    var version: String
    var refreshItem: NSMenuItem
    var loginItem: NSMenuItem
    var quitItem: NSMenuItem
}

enum PanelAccent {
    case codex, external

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255,
                alpha: 1)
    }

    var color: NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            switch self {
            case .codex: return Self.rgb(dark ? 0x85B5ED : 0x204B80)
            case .external: return Self.rgb(dark ? 0x86BDE8 : 0x2B6F9E)
            }
        }
    }

    var symbol: String {
        switch self {
        case .codex: return "square.stack.3d.up.fill"
        case .external: return "square.stack.3d.up"
        }
    }
}

private enum PanelUI {
    static func stack(orientation: NSUserInterfaceLayoutOrientation = .vertical,
                      alignment: NSLayoutConstraint.Attribute = .width,
                      spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = orientation
        stack.alignment = alignment
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    static func addFullWidth(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    static func pin(_ view: NSView, to container: NSView) {
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    static func label(_ text: String, size: CGFloat = 12,
                      weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor,
                      wrapping: Bool = true,
                      monospacedDigits: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = monospacedDigits
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.maximumNumberOfLines = wrapping ? 0 : 1
        label.cell?.lineBreakMode = wrapping ? .byWordWrapping : .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    static func symbol(_ name: String, size: CGFloat = 16,
                       color: NSColor = .secondaryLabelColor) -> NSImageView {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        let view = NSImageView(image: image ?? NSImage())
        view.contentTintColor = color
        view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }

    static func spacer() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return view
    }

    static func separator() -> NSBox {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    static func notices(_ notices: [UsagePanelModel.Notice]) -> [NSView] {
        notices.map { notice in
            let color: NSColor
            switch notice.level {
            case .info: color = .secondaryLabelColor
            case .warning: color = PanelAccent.codex.color
            case .error: color = .systemRed
            }
            return label(notice.text, size: 11, color: color)
        }
    }
}

final class PanelSolidBackgroundView: NSView {
    var opacity: CGFloat = 0.9 { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(opacity).cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class PanelActionButton: NSButton {
    enum Style {
        case plain, prominent, checkbox
    }

    var menuItem: NSMenuItem?
    var style: Style = .plain { didSet { needsDisplay = true } }
    private var hovered = false { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            switch style {
            case .prominent:
                let color = NSColor(srgbRed: 0.06, green: 0.16, blue: 0.32, alpha: 1)
                layer?.backgroundColor = color.withAlphaComponent(hovered ? 0.78 : 1).cgColor
            case .plain:
                layer?.backgroundColor = (hovered
                    ? NSColor.labelColor.withAlphaComponent(0.08)
                    : NSColor.clear).cgColor
            case .checkbox:
                layer?.backgroundColor = NSColor.clear.cgColor
            }
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
}

class PanelCardView: NSView {
    let contentStack = PanelUI.stack(spacing: 4)

    init(padding: CGFloat = 12) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 0.5
        addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.035).cgColor
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.09).cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class PanelHeaderView: NSView {
    init(model: UsagePanelModel) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let row = PanelUI.stack(orientation: .horizontal, alignment: .centerY, spacing: 12)
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32)
        ])
        row.addArrangedSubview(icon)
        let titles = PanelUI.stack(spacing: 2)
        titles.alignment = .leading
        let title = PanelUI.label(model.title, size: 15, weight: .semibold, wrapping: false)
        PanelUI.addFullWidth(title, to: titles)
        if let email = model.email, !email.isEmpty {
            let emailLabel = PanelUI.label(email, size: 11, color: .secondaryLabelColor)
            PanelUI.addFullWidth(emailLabel, to: titles)
        }
        row.addArrangedSubview(titles)
        addSubview(row)
        PanelUI.pin(row, to: self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class QuotaProgressView: NSView {
    var remaining: Int? { didSet { needsLayout = true; needsDisplay = true } }
    private let fill = CALayer()

    init(remaining: Int?) {
        self.remaining = remaining
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
        fill.cornerRadius = 4
        layer?.addSublayer(fill)
        heightAnchor.constraint(equalToConstant: 8).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
            fill.backgroundColor = RemainingColorTier(remaining: remaining).color(for: effectiveAppearance).cgColor
        }
    }
    override func layout() {
        super.layout()
        let value = CGFloat(max(0, min(100, remaining ?? 0))) / 100
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * value, height: bounds.height)
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class QuotaWindowView: NSView {
    init(model: UsagePanelModel.Quota, compact: Bool = false) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let root = PanelUI.stack(spacing: 4)
        let main = PanelUI.stack(orientation: .horizontal, alignment: .centerY, spacing: 6)
        let shortTitle = model.title.replacingOccurrences(of: "窗口", with: "")
        let title = PanelUI.label(shortTitle, size: 12, weight: .semibold, wrapping: false)
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        title.widthAnchor.constraint(equalToConstant: 43).isActive = true
        main.addArrangedSubview(title)
        let remainingColor = NSColor(name: nil) { appearance in
            RemainingColorTier(remaining: model.remaining).color(for: appearance)
        }
        let remaining = PanelUI.label(model.remaining.map { "\($0)%" } ?? "--",
            size: 14, weight: .semibold, color: remainingColor,
            wrapping: false, monospacedDigits: true)
        remaining.widthAnchor.constraint(equalToConstant: 40).isActive = true
        remaining.setContentCompressionResistancePriority(.required, for: .horizontal)
        main.addArrangedSubview(remaining)
        let progress = QuotaProgressView(remaining: model.remaining)
        progress.widthAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        progress.setContentHuggingPriority(.defaultLow, for: .horizontal)
        main.addArrangedSubview(progress)
        let reset = PanelUI.label(model.resetText, size: 12, weight: .semibold,
            wrapping: false, monospacedDigits: true)
        reset.alignment = .right
        reset.setContentHuggingPriority(.required, for: .horizontal)
        reset.setContentCompressionResistancePriority(.required, for: .horizontal)
        main.addArrangedSubview(reset)
        PanelUI.addFullWidth(main, to: root)
        for notice in PanelUI.notices(model.notices) {
            PanelUI.addFullWidth(notice, to: root)
        }
        addSubview(root)
        PanelUI.pin(root, to: self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class ResetCardSectionView: PanelCardView {
    init(model: UsagePanelModel.ResetSection) {
        super.init(padding: 8)
        let header = PanelUI.stack(orientation: .horizontal, alignment: .centerY, spacing: 8)
        header.addArrangedSubview(PanelUI.symbol("calendar", size: 15, color: PanelAccent.codex.color))
        header.addArrangedSubview(PanelUI.label("重置卡", size: 13, weight: .semibold, wrapping: false))
        header.addArrangedSubview(PanelUI.spacer())
        if let count = model.count {
            header.addArrangedSubview(PanelUI.label("×\(count)", size: 12, weight: .semibold,
                color: PanelAccent.codex.color, wrapping: false, monospacedDigits: true))
        } else if let empty = model.emptyText {
            header.addArrangedSubview(PanelUI.label(empty, size: 11, color: .secondaryLabelColor, wrapping: false))
        }
        contentStack.addArrangedSubview(header)
        for (index, rowModel) in model.rows.enumerated() {
            _ = index
            let row = PanelUI.stack(orientation: .horizontal, alignment: .centerY, spacing: 8)
            let color: NSColor = rowModel.warning ? PanelAccent.codex.color : .labelColor
            let name = PanelUI.label((rowModel.warning ? "⚠ " : "") + rowModel.name,
                size: 12, color: color)
            row.addArrangedSubview(name)
            row.addArrangedSubview(PanelUI.spacer())
            let expires = PanelUI.label(rowModel.expires, size: 11,
                color: rowModel.warning ? PanelAccent.codex.color : .secondaryLabelColor,
                wrapping: false, monospacedDigits: true)
            expires.setContentHuggingPriority(.required, for: .horizontal)
            expires.setContentCompressionResistancePriority(.required, for: .horizontal)
            row.addArrangedSubview(expires)
            contentStack.addArrangedSubview(row)
        }
        for notice in PanelUI.notices(model.notices) {
            PanelUI.addFullWidth(notice, to: contentStack)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class UsagePanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

final class UsagePanelController: NSObject {
    var onClose: (() -> Void)?
    var onCheckUpdate: (() -> Void)?
    private var codexExpanded = true
    private var externalExpanded = true
    private var updateMessage: String?
    var previewWidth: CGFloat?
    var isOpen: Bool { panel.isVisible }

    private let panel: UsagePanel
    private let effect = NSVisualEffectView()
    private let solid = PanelSolidBackgroundView()
    private let headerContainer = NSView()
    private let footerContainer = NSView()
    private let scrollView = NSScrollView()
    private let stack = PanelUI.stack(spacing: 8)
    private var model: UsagePanelModel?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private weak var anchorButton: NSStatusBarButton?
    private static let maximumWidth: CGFloat = 330
    private var panelWidth = UsagePanelController.maximumWidth

    override init() {
        panel = UsagePanel(contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 320),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onCancel = { [weak self] in self?.close() }
        configureContent()
    }

    deinit {
        if let localMonitor = localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor = globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    }

    private func configureContent() {
        guard let container = panel.contentView else { return }
        container.wantsLayer = true
        container.layer?.cornerRadius = 16
        container.layer?.masksToBounds = true

        effect.frame = container.bounds
        effect.autoresizingMask = [.width, .height]
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true
        container.addSubview(effect)

        solid.frame = container.bounds
        solid.autoresizingMask = [.width, .height]
        solid.wantsLayer = true
        solid.layer?.cornerRadius = 16
        solid.layer?.masksToBounds = true
        container.addSubview(solid)

        for view in [headerContainer, footerContainer] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none

        container.addSubview(headerContainer)
        container.addSubview(scrollView)
        container.addSubview(footerContainer)
        NSLayoutConstraint.activate([
            headerContainer.topAnchor.constraint(equalTo: container.topAnchor),
            headerContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            headerContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: headerContainer.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footerContainer.topAnchor),
            footerContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footerContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footerContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        stack.alignment = .centerX
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        scrollView.documentView = stack
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor)
        ])
    }

    func update(model: UsagePanelModel) {
        self.model = model
        if isOpen { refreshPanelLayout() } else { rebuildContent() }
    }

    private func clear(container: NSView) {
        for view in container.subviews { view.removeFromSuperview() }
    }

    private func installChrome(model: UsagePanelModel) {
        clear(container: headerContainer)
        clear(container: footerContainer)

        let header = PanelHeaderView(model: model)
        let headerLine = PanelUI.separator()
        headerContainer.addSubview(header)
        headerContainer.addSubview(headerLine)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: headerContainer.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor, constant: -16),
            headerLine.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            headerLine.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 16),
            headerLine.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor, constant: -16),
            headerLine.bottomAnchor.constraint(equalTo: headerContainer.bottomAnchor)
        ])

        let footerLine = PanelUI.separator()
        let footer = PanelFooterView(model: model, updateMessage: updateMessage, target: self, buttonFactory: makeActionButton)
        footerContainer.addSubview(footerLine)
        footerContainer.addSubview(footer)
        NSLayoutConstraint.activate([
            footerLine.topAnchor.constraint(equalTo: footerContainer.topAnchor),
            footerLine.leadingAnchor.constraint(equalTo: footerContainer.leadingAnchor, constant: 16),
            footerLine.trailingAnchor.constraint(equalTo: footerContainer.trailingAnchor, constant: -16),
            footer.topAnchor.constraint(equalTo: footerLine.bottomAnchor, constant: 8),
            footer.leadingAnchor.constraint(equalTo: footerContainer.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: footerContainer.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: footerContainer.bottomAnchor, constant: -12)
        ])
    }

    private func addContentRow(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalToConstant: panelWidth - 32).isActive = true
    }

    private func rebuildContent() {
        guard let model = model else { return }
        installChrome(model: model)
        for row in stack.arrangedSubviews {
            stack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        if let update = model.updateItem {
            let button = makeActionButton(update, .prominent)
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
            addContentRow(button)
        }
        let quotaHeading = PanelUI.label("重置时间", size: 10, color: .secondaryLabelColor, wrapping: false)
        quotaHeading.alignment = .right
        addContentRow(quotaHeading)
        for quota in model.quotas { addContentRow(QuotaWindowView(model: quota, compact: panelWidth < 400)) }
        if let reset = model.resetCards {
            addContentRow(ResetCardSectionView(model: reset))
        }
        if let tibo = model.tibo {
            addContentRow(makeTiboSection(tibo))
        }
        addContentRow(TokenSectionView(model: model.codexTokens, expanded: codexExpanded, target: self, action: #selector(toggleCodex)))
        if let external = model.externalTokens {
            addContentRow(TokenSectionView(model: external, expanded: externalExpanded, target: self, action: #selector(toggleExternal)))
        }
        for notice in PanelUI.notices(model.notices) { addContentRow(notice) }
        stack.needsLayout = true
    }

    private func refreshPanelLayout() {
        rebuildContent()
        if let button = anchorButton, let window = button.window, isOpen {
            layoutPanel(anchoredTo: button, buttonWindow: window)
        }
    }
    @objc private func toggleCodex() { codexExpanded.toggle(); refreshPanelLayout() }
    @objc private func toggleExternal() { externalExpanded.toggle(); refreshPanelLayout() }
    @objc fileprivate func requestUpdateCheck() { onCheckUpdate?() }
    func setUpdateMessage(_ message: String?) { updateMessage = message; refreshPanelLayout() }

    private func makeTiboSection(_ model: UsagePanelModel.TiboSection) -> NSView {
        let card = PanelCardView(padding: 8)
        let header = PanelUI.stack(orientation: .horizontal, alignment: .centerY, spacing: 8)
        header.addArrangedSubview(PanelUI.symbol("checkmark.circle.fill", size: 16, color: .systemGreen))
        header.addArrangedSubview(PanelUI.label("Tibo 重置动态", size: 13, weight: .semibold, wrapping: false))
        header.addArrangedSubview(PanelUI.spacer())
        PanelUI.addFullWidth(header, to: card.contentStack)
        for row in model.rows {
            let view: NSView
            if let item = row.item {
                view = makeActionButton(item, .plain, title: row.text)
            } else {
                view = PanelUI.label(row.text, size: 12)
            }
            PanelUI.addFullWidth(view, to: card.contentStack)
        }
        for notice in PanelUI.notices(model.notices) {
            PanelUI.addFullWidth(notice, to: card.contentStack)
        }
        return card
    }

    private func makeActionButton(_ item: NSMenuItem, _ style: PanelActionButton.Style,
                                  title overrideTitle: String? = nil) -> PanelActionButton {
        let button = PanelActionButton()
        button.menuItem = item
        button.style = style
        button.target = self
        button.action = #selector(performAction(_:))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.alignment = style == .prominent ? .center : .left
        button.keyEquivalent = item.keyEquivalent
        button.keyEquivalentModifierMask = []
        button.toolTip = item.toolTip
        button.focusRingType = .none
        let title = overrideTitle ?? item.title
        let prominent = style == .prominent
        let textColor: NSColor = prominent
            ? NSColor(name: nil) { appearance in
                .white
            }
            : .labelColor
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: prominent ? .semibold : .regular),
            .foregroundColor: textColor
        ])
        if style == .checkbox {
            button.setButtonType(.switch)
            button.isBordered = false
            button.state = item.state
            button.contentTintColor = PanelAccent.codex.color
        } else {
            button.setButtonType(.momentaryChange)
            button.isBordered = false
            (button.cell as? NSButtonCell)?.highlightsBy = []
            button.cell?.wraps = true
            button.cell?.lineBreakMode = .byWordWrapping
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: style == .plain ? 26 : 30).isActive = true
        }
        return button
    }

    @objc private func performAction(_ sender: PanelActionButton) {
        guard let item = sender.menuItem, let action = item.action else { return }
        close()
        DispatchQueue.main.async {
            _ = NSApp.sendAction(action, to: item.target, from: item)
        }
    }

    // Verify independent disclosure and retained error notices using the real view tree.
    func verifyPreviewInteractions(expectScroll: Bool) -> Bool {
        func labels(_ view: NSView) -> [String] {
            (view as? NSTextField).map { [$0.stringValue] } ?? []
                + view.subviews.flatMap { labels($0) }
        }
        guard isOpen, codexExpanded, externalExpanded else { return false }
        if expectScroll && !scrollToEndForPreview() { return false }
        toggleCodex()
        guard !codexExpanded, externalExpanded,
              labels(stack).contains(where: { $0.contains("统计失败") }) else { return false }
        toggleExternal()
        guard !codexExpanded, !externalExpanded,
              labels(stack).filter({ $0.contains("统计失败") }).count == 2 else { return false }
        toggleCodex()
        guard codexExpanded, !externalExpanded else { return false }
        toggleExternal()
        return codexExpanded && externalExpanded
    }

    /// 视觉回归专用：真实滚动到底部并确认 clip view 位置发生变化。
    func scrollToEndForPreview() -> Bool {
        panel.contentView?.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        stack.layoutSubtreeIfNeeded()
        guard let document = scrollView.documentView else { return false }
        let clip = scrollView.contentView
        let maxY = max(0, document.frame.height - clip.bounds.height)
        guard maxY > 0 else { return false }
        let targetY = -maxY
        clip.scroll(to: NSPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(clip)
        return abs(clip.bounds.origin.y - targetY) < 1
    }

    /// 固定假数据预览的本地截图，只包含面板，不读取或捕捉其他窗口。
    func savePreviewImage(to path: String) -> Bool {
        guard let view = panel.contentView else { return false }
        view.layoutSubtreeIfNeeded()
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: image)
        guard let data = image.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }

    func toggle(anchoredTo button: NSStatusBarButton) {
        if isOpen { close() } else { show(anchoredTo: button) }
    }

    private func show(anchoredTo button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        anchorButton = button
        layoutPanel(anchoredTo: button, buttonWindow: buttonWindow)
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        solid.opacity = reduceTransparency ? 1 : 0.9
        effect.isHidden = reduceTransparency
        installMonitors()
        panel.makeKeyAndOrderFront(nil)
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func layoutPanel(anchoredTo button: NSStatusBarButton, buttonWindow: NSWindow) {
        let screen = buttonWindow.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let desiredWidth = min(previewWidth ?? Self.maximumWidth, visible.width - 24)
        var frame = panel.frame
        frame.size.width = desiredWidth
        panel.setFrame(frame, display: false)
        if desiredWidth != panelWidth {
            panelWidth = desiredWidth
            rebuildContent()
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        stack.layoutSubtreeIfNeeded()
        let chromeHeight = headerContainer.fittingSize.height + footerContainer.fittingSize.height
        let fittingHeight = max(chromeHeight + stack.fittingSize.height, 240)
        let maximumHeight = max(240, visible.height * 0.85)
        let height = min(fittingHeight, maximumHeight)
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let x = max(visible.minX + 8, min(buttonRect.midX - panelWidth / 2, visible.maxX - panelWidth - 8))
        let y = max(visible.minY + 8, buttonRect.minY - height - 4)
        panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: height), display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    private func installMonitors() {
        removeMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            let location = NSEvent.mouseLocation
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let button = self.anchorButton, let window = button.window,
                   window.convertToScreen(button.convert(button.bounds, to: nil)).contains(location) { return }
                self.close()
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self = self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.close(); return nil }
                return event
            }
            if event.window === self.panel || event.window === self.anchorButton?.window { return event }
            self.close()
            return event
        }
    }

    private func removeMonitors() {
        if let monitor = localMonitor { NSEvent.removeMonitor(monitor); localMonitor = nil }
        if let monitor = globalMonitor { NSEvent.removeMonitor(monitor); globalMonitor = nil }
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        removeMonitors()
        anchorButton = nil
        onClose?()
    }
}

private final class TokenDetailRow: NSView {
    init(values: [String], header: Bool, accent: PanelAccent) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let row = PanelUI.stack(orientation: .horizontal, alignment: .centerY, spacing: 4)
        row.distribution = .fillEqually
        for (index, value) in values.enumerated() {
            let label = PanelUI.label(value, size: header ? 10 : 11,
                weight: header ? .regular : (index == 0 ? .regular : .semibold),
                color: header ? .secondaryLabelColor : (index == 1 ? accent.color : .labelColor),
                wrapping: false, monospacedDigits: !header && index > 0)
            label.alignment = index == 0 ? .left : .right
            row.addArrangedSubview(label)
        }
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class TokenSectionView: NSView {
    init(model: UsagePanelModel.TokenSection, expanded: Bool, target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let root = PanelUI.stack(spacing: 3)
        let header = PanelUI.stack(orientation: .horizontal, alignment: .centerY, spacing: 6)
        header.addArrangedSubview(PanelUI.symbol(model.accent.symbol, size: 14, color: model.accent.color))
        header.addArrangedSubview(PanelUI.label(model.title, size: 12, weight: .semibold, wrapping: false))
        header.addArrangedSubview(PanelUI.spacer())
        let toggle = NSButton(image: NSImage(systemSymbolName: expanded ? "chevron.up" : "chevron.down", accessibilityDescription: expanded ? "折叠用量" : "展开用量")!, target: target, action: action)
        toggle.isBordered = false
        toggle.contentTintColor = .secondaryLabelColor
        toggle.toolTip = expanded ? "折叠" : "展开"
        toggle.setAccessibilityLabel(expanded ? "折叠\(model.title)" : "展开\(model.title)")
        toggle.widthAnchor.constraint(equalToConstant: 24).isActive = true
        toggle.heightAnchor.constraint(equalToConstant: 22).isActive = true
        header.addArrangedSubview(toggle)
        PanelUI.addFullWidth(header, to: root)
        if expanded {
        let tableHeader = TokenDetailRow(values: ["周期", "总量", "输入", "输出"], header: true, accent: model.accent)
        PanelUI.addFullWidth(tableHeader, to: root)
        for bucket in model.buckets {
            let row = TokenDetailRow(values: [bucket.summaryLabel, bucket.total, bucket.input, bucket.output], header: false, accent: model.accent)
            PanelUI.addFullWidth(row, to: root)
        }
        }
        for notice in PanelUI.notices(model.notices) { PanelUI.addFullWidth(notice, to: root) }
        addSubview(root)
        PanelUI.pin(root, to: self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class PanelFooterView: NSView {
    init(model: UsagePanelModel, updateMessage: String?, target: UsagePanelController,
         buttonFactory: (NSMenuItem, PanelActionButton.Style, String?) -> PanelActionButton) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let root = PanelUI.stack(spacing: 8)
        let meta = PanelUI.stack(orientation: .horizontal, alignment: .centerY, spacing: 8)
        meta.addArrangedSubview(PanelUI.label(model.lastAttempt, size: 11, color: .secondaryLabelColor, wrapping: false))
        meta.addArrangedSubview(PanelUI.spacer())
        let version = NSButton(title: model.version, target: target, action: #selector(UsagePanelController.requestUpdateCheck))
        version.isBordered = false
        version.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        version.contentTintColor = .secondaryLabelColor
        version.toolTip = "点击检查更新"
        version.setAccessibilityLabel("\(model.version)，点击检查更新")
        meta.addArrangedSubview(version)
        root.addArrangedSubview(meta)
        if let message = updateMessage {
            let label = PanelUI.label(message, size: 11, color: .secondaryLabelColor)
            root.addArrangedSubview(label)
        }

        let actions = PanelUI.stack(orientation: .horizontal, alignment: .centerY, spacing: 6)
        let refresh = buttonFactory(model.refreshItem, .prominent, nil)
        refresh.widthAnchor.constraint(equalToConstant: 76).isActive = true
        actions.addArrangedSubview(refresh)
        actions.addArrangedSubview(buttonFactory(model.loginItem, .checkbox, nil))
        actions.addArrangedSubview(PanelUI.spacer())
        let quit = buttonFactory(model.quitItem, .plain, nil)
        quit.widthAnchor.constraint(equalToConstant: 40).isActive = true
        actions.addArrangedSubview(quit)
        root.addArrangedSubview(actions)
        addSubview(root)
        PanelUI.pin(root, to: self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}



// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let panelController = UsagePanelController()
    private let visualPreview = CommandLine.arguments.contains { $0.hasPrefix("--visual-preview") }
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var updateTimer: Timer?
    private var usage = UsageData()
    private let refreshGate = RefreshGate()
    private let launchAgentLabel = "com.local.kimi-usage"
    // 月度接口的 accessToken 寿命短，过期后由 KimiUsage 自己用 refreshToken 续期
    // （GET /api/auth/token/refresh，会轮换 refresh_token 并写回 config.json）。
    // 记录最后一次月度拉取成功时间，用于菜单标注过期数据。
    private var lastMonthSuccessAt: Date?
    private var lastFiveHourSuccessAt: Date?
    private var lastSevenDaySuccessAt: Date?
    private var workTokensLastSuccessAt: Date?
    private var cliTokensLastSuccessAt: Date?
    private var lastAttemptAt = Date()
    private var lastSlowAttemptAt: Date?
    // 数据过期阈值：额度 10 分钟、token 统计 30 分钟——超过该时长未成功刷新即在 UI 标 ⚠️
    private let quotaStaleAfter: TimeInterval = 600
    private let tokensStaleAfter: TimeInterval = 1800

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[KimiUsage] launched, creating status item")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        panelController.onCheckUpdate = { [weak self] in self?.manualUpdateCheck() }
        if visualPreview { configureVisualPreview(); return }
        rebuildMenu()
        renderBar()
        refresh(manual: true)
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = 6
        // 更新检查：启动 20 秒后首查（避开启动网络高峰），此后每 30 分钟；
        // 打开菜单也会触发一次（同一 interval 节流，不增加请求频率）
        updateTimer = Timer.scheduledTimer(withTimeInterval: UpdateCheck.interval, repeats: true) { [weak self] _ in
            self?.checkForUpdate()
        }
        updateTimer?.tolerance = 60
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkForUpdate() }
    }

    // 额度每 30s 刷新；月度和本地扫描按上次尝试时间每 5 分钟刷新。
    private func refresh(manual: Bool = false) {
        guard refreshGate.begin(manual: manual) else { return }
        let now = Date()
        let includeSlow = RefreshSchedule.shouldRunSlow(manual: manual, lastAttempt: lastSlowAttemptAt, now: now)
        if includeSlow { lastSlowAttemptAt = now }
        performRefresh(includeSlow: includeSlow)
    }

    // 本轮所有来源都汇合到一份结果；锁保护并发网络回调，group.leave 前先解锁。
    private func performRefresh(includeSlow: Bool) {
        lastAttemptAt = Date()
        if includeSlow { lastSlowAttemptAt = lastAttemptAt }
        updateUI()
        let cred = CredStore.load()
        var merged = UsageData()
        let group = DispatchGroup()
        let mergeLock = NSLock()

        if let key = cred.codeApiKey, !key.isEmpty {
            group.enter()
            Fetcher.fetchCodeUsage(apiKey: key) { r in
                mergeLock.lock()
                merged.fiveHourUsed = r.fiveHourUsed
                merged.fiveHourReset = r.fiveHourReset
                merged.sevenDayUsed = r.sevenDayUsed
                merged.sevenDayReset = r.sevenDayReset
                merged.fiveHourError = r.fiveHourError
                merged.sevenDayError = r.sevenDayError
                mergeLock.unlock()
                group.leave()
            }
        } else {
            merged.fiveHourError = "no api key"
            merged.sevenDayError = "no api key"
        }

        if includeSlow, let token = CredStore.load().webToken, !token.isEmpty {
            group.enter()
            Fetcher.fetchMonthUsage(webToken: token) { r in
                if let err = r.monthError, err.contains("401") {
                    Fetcher.refreshWebToken { newToken in
                        if let newToken = newToken {
                            Fetcher.fetchMonthUsage(webToken: newToken) { r2 in
                                mergeLock.lock()
                                merged.monthUsed = r2.monthUsed
                                merged.monthReset = r2.monthReset
                                merged.monthError = r2.monthError
                                mergeLock.unlock()
                                group.leave()
                            }
                        } else {
                            mergeLock.lock()
                            merged.monthError = "HTTP 401（自刷新失败，请打开一次 Kimi 桌面端重新登录）"
                            mergeLock.unlock()
                            group.leave()
                        }
                    }
                } else {
                    mergeLock.lock()
                    merged.monthUsed = r.monthUsed
                    merged.monthReset = r.monthReset
                    merged.monthError = r.monthError
                    mergeLock.unlock()
                    group.leave()
                }
            }
        } else if includeSlow {
            merged.monthError = "no web token"
        }

        if includeSlow {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let d = TokenAggregator.aggregateBothDetailed()
                mergeLock.lock()
                merged.tokensToday = d.work.0; merged.tokens7d = d.work.1; merged.tokens30d = d.work.2
                merged.cliTokensToday = d.cli.0; merged.cliTokens7d = d.cli.1; merged.cliTokens30d = d.cli.2
                merged.workTokensError = d.workError
                merged.cliTokensError = d.cliError
                mergeLock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            let completedAt = Date()
            self.lastFiveHourSuccessAt = DataFreshness.updated(self.lastFiveHourSuccessAt,
                succeeded: merged.fiveHourUsed != nil, at: completedAt)
            self.lastSevenDaySuccessAt = DataFreshness.updated(self.lastSevenDaySuccessAt,
                succeeded: merged.sevenDayUsed != nil, at: completedAt)
            if includeSlow {
                self.lastMonthSuccessAt = DataFreshness.updated(self.lastMonthSuccessAt,
                    succeeded: merged.monthError == nil && merged.monthUsed != nil, at: completedAt)
                // 扫描失败面：已安装来源全部不可读时不推进成功时间，30 分钟后 ⚠️ 自动亮起
                self.workTokensLastSuccessAt = DataFreshness.updated(self.workTokensLastSuccessAt,
                    succeeded: merged.workTokensError == nil, at: completedAt)
                self.cliTokensLastSuccessAt = DataFreshness.updated(self.cliTokensLastSuccessAt,
                    succeeded: merged.cliTokensError == nil, at: completedAt)
            }

            let old = self.usage
            if merged.fiveHourUsed == nil { merged.fiveHourUsed = old.fiveHourUsed; merged.fiveHourReset = old.fiveHourReset }
            if merged.sevenDayUsed == nil { merged.sevenDayUsed = old.sevenDayUsed; merged.sevenDayReset = old.sevenDayReset }
            if !includeSlow {
                merged.monthUsed = old.monthUsed; merged.monthReset = old.monthReset; merged.monthError = old.monthError
                merged.tokensToday = old.tokensToday; merged.tokens7d = old.tokens7d; merged.tokens30d = old.tokens30d
                merged.cliTokensToday = old.cliTokensToday; merged.cliTokens7d = old.cliTokens7d; merged.cliTokens30d = old.cliTokens30d
                merged.workTokensError = old.workTokensError; merged.cliTokensError = old.cliTokensError
            } else {
                if merged.monthUsed == nil { merged.monthUsed = old.monthUsed; merged.monthReset = old.monthReset }
                // 扫描失败：保留旧值（⚠️ 过期标注由 lastSuccess 不推进自然产生）
                if merged.workTokensError != nil {
                    merged.tokensToday = old.tokensToday; merged.tokens7d = old.tokens7d; merged.tokens30d = old.tokens30d
                }
                if merged.cliTokensError != nil {
                    merged.cliTokensToday = old.cliTokensToday; merged.cliTokens7d = old.cliTokens7d; merged.cliTokens30d = old.cliTokens30d
                }
            }
            self.usage = merged
            self.updateUI()
            if self.refreshGate.finish() { self.performRefresh(includeSlow: true) }
        }
    }

    private func updateUI() {
        renderBar()
        rebuildMenu()
    }

    @objc private func togglePanel() {
        guard let button = statusItem.button else { return }
        if !panelController.isOpen && !visualPreview {
            refresh(manual: true)
            checkForUpdate()
        }
        panelController.toggle(anchoredTo: button)
    }

    // 过期判定：距最后成功超过阈值即过期；有数据但 lastOK 为 nil（异常情况）也视为过期。
    // 无数据不算过期——菜单里本就显示"暂无数据"，无需再标注。
    private func isStale(_ lastOK: Date?, hasData: Bool, after: TimeInterval) -> Bool {
        DataFreshness.isStale(lastSuccess: lastOK, hasData: hasData, now: Date(), after: after)
    }
    private var fiveHourStale: Bool { isStale(lastFiveHourSuccessAt, hasData: usage.fiveHourUsed != nil, after: quotaStaleAfter) }
    private var sevenDayStale: Bool { isStale(lastSevenDaySuccessAt, hasData: usage.sevenDayUsed != nil, after: quotaStaleAfter) }
    private var monthStale: Bool { isStale(lastMonthSuccessAt, hasData: usage.monthUsed != nil, after: 600) }
    private var tokensStale: Bool {
        isStale(workTokensLastSuccessAt, hasData: usage.tokensToday != nil || usage.tokens7d != nil || usage.tokens30d != nil,
            after: tokensStaleAfter)
    }
    private var cliTokensStale: Bool {
        isStale(cliTokensLastSuccessAt, hasData: usage.cliTokensToday != nil || usage.cliTokens7d != nil || usage.cliTokens30d != nil,
            after: tokensStaleAfter)
    }

    // 已用量 → 余额（剩余比例）
    private func remaining(_ used: Double?) -> Double? {
        guard let used = used else { return nil }
        return max(0, min(1, 1 - used))
    }

    // 菜单栏显示：5H / 7D 两行堆叠（显示余额）；额度过期时两行加 ⚠️ 前缀
    // （5H/7D 同属服务端额度组，整组标注；token 组无菜单栏行，仅在下拉菜单标注）
    private func renderBar() {
        let line1 = (fiveHourStale ? "⚠️ " : "") + "5H \(Fmt.pct(remaining(usage.fiveHourUsed)))"
        let line2 = (sevenDayStale ? "⚠️ " : "") + "7D \(Fmt.pct(remaining(usage.sevenDayUsed)))"
        statusItem.button?.image = StackImage.make(line1: line1, line2: line2)
        statusItem.button?.title = ""
        // toolTip 显示最后成功时间而非渲染时间：断网时能直接看出数据有多旧
        statusItem.button?.toolTip = "Kimi 余额 · 5H成功 \(Fmt.lastOK(lastFiveHourSuccessAt)) · 7D成功 \(Fmt.lastOK(lastSevenDaySuccessAt))"
            + " · 月度成功 \(Fmt.lastOK(lastMonthSuccessAt)) · Work扫描成功 \(Fmt.lastOK(workTokensLastSuccessAt))"
            + " · API扫描成功 \(Fmt.lastOK(cliTokensLastSuccessAt))"
        if !visualPreview { writeStatus(line1: line1, line2: line2) }
    }

    // 自诊断：把渲染内容和状态项可见性写到本地，便于排查
    private func writeStatus(line1: String, line2: String) {
        let dir = NSHomeDirectory() + "/Library/Application Support/KimiUsage"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let monthStatus: [String: Any] = [
            "remaining": remaining(usage.monthUsed) ?? -1.0,
            "error": usage.monthError ?? "",
            "lastSuccessAt": lastMonthSuccessAt.map { ISO8601DateFormatter().string(from: $0) } ?? ""
        ]
        var info: [String: Any] = [
            "line1": line1,
            "line2": line2,
            "lastAttemptAt": Fmt.iso8601.string(from: lastAttemptAt),
            "version": BuildInfo.version,
            "updateAvailable": UpdateChecker.shared.available,
            "lastSuccessAt": [
                "fiveHour": lastFiveHourSuccessAt.map { Fmt.iso8601.string(from: $0) } ?? "",
                "sevenDay": lastSevenDaySuccessAt.map { Fmt.iso8601.string(from: $0) } ?? "",
                "month": lastMonthSuccessAt.map { Fmt.iso8601.string(from: $0) } ?? "",
                "workTokens": workTokensLastSuccessAt.map { Fmt.iso8601.string(from: $0) } ?? "",
                "cliTokens": cliTokensLastSuccessAt.map { Fmt.iso8601.string(from: $0) } ?? ""
            ],
            "errors": [
                "fiveHour": usage.fiveHourError ?? "",
                "sevenDay": usage.sevenDayError ?? "",
                "month": usage.monthError ?? "",
                "workTokens": usage.workTokensError ?? "",
                "cliTokens": usage.cliTokensError ?? ""
            ],
            "fiveHourStale": fiveHourStale,
            "sevenDayStale": sevenDayStale,
            "monthStale": monthStale,
            "tokensStale": tokensStale,
            "cliTokensStale": cliTokensStale,
            "month": monthStatus,
            "imageSize": [
                "w": statusItem.button?.image?.size.width ?? -1,
                "h": statusItem.button?.image?.size.height ?? -1
            ]
        ]
        if let button = statusItem.button, let win = button.window {
            let f = button.convert(button.bounds, to: nil)
            let sf = win.convertToScreen(f)
            info["buttonScreenFrame"] = ["x": sf.origin.x, "y": sf.origin.y,
                                         "w": sf.size.width, "h": sf.size.height]
            info["windowVisible"] = win.isVisible
            info["windowOnActiveSpace"] = win.isOnActiveSpace
            var screens: [[String: Double]] = []
            for s in NSScreen.screens {
                screens.append(["x": s.frame.origin.x, "y": s.frame.origin.y,
                                "w": s.frame.size.width, "h": s.frame.size.height])
            }
            info["screens"] = screens
        } else {
            info["windowVisible"] = false
        }
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: dir + "/status.json"))
        }
        NSLog("[KimiUsage] rendered %@ / %@", line1, line2)
    }

    private func rebuildMenu() {
        func notice(_ text: String, _ level: UsagePanelModel.NoticeLevel = .info) -> UsagePanelModel.Notice {
            UsagePanelModel.Notice(text: text, level: level)
        }
        func quota(_ title: String, _ used: Double?, _ reset: Date?, _ error: String?, _ last: Date?, _ stale: Bool) -> UsagePanelModel.Quota {
            var notices: [UsagePanelModel.Notice] = []
            if stale { notices.append(notice("⚠ 已过期 · 最后成功 \(last.map { Fmt.dayTime($0) } ?? "--")", .warning)) }
            if let error = error { notices.append(notice("刷新失败：\(error) · 最后成功 \(last.map { Fmt.dayTime($0) } ?? "--")", .error)) }
            return .init(title: title, resetText: reset.map { Fmt.dayTime($0) } ?? "时间未知",
                         remaining: remaining(used).map { Int(($0 * 100).rounded()) }, notices: notices)
        }
        func section(_ title: String, _ accent: PanelAccent, _ values: [TokenStat?], _ error: String?, _ last: Date?, _ stale: Bool) -> UsagePanelModel.TokenSection {
            let names = ["今日", "近 7 天", "近 30 天"]
            let rows = zip(names, values).map { name, stat in
                UsagePanelModel.TokenBucket(summaryLabel: name, detailLabel: name,
                    total: stat.map { Fmt.tokens($0.total) } ?? "--", input: stat.map { Fmt.tokens($0.input) } ?? "--",
                    output: stat.map { Fmt.tokens($0.output) } ?? "--")
            }
            var notices: [UsagePanelModel.Notice] = []
            if stale { notices.append(notice("⚠ 已过期 · 最后成功 \(last.map { Fmt.dayTime($0) } ?? "--")", .warning)) }
            if let error = error { notices.append(notice("统计失败：\(error) · 最后成功 \(last.map { Fmt.dayTime($0) } ?? "--")", .error)) }
            return .init(title: title, accent: accent, buckets: rows, notices: notices)
        }
        func item(_ title: String, _ selector: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; return item
        }
        let login = item("开机自启", #selector(onToggleLogin))
        login.state = (!visualPreview && isLoginItemEnabled()) ? .on : .off
        let update = UpdateChecker.shared.available ? item("⬆ 新版本可用，点击更新", #selector(onUpdateApp)) : nil
        panelController.update(model: UsagePanelModel(updateItem: update, title: "Kimi 余额", email: nil,
            quotas: [quota("5 小时", usage.fiveHourUsed, usage.fiveHourReset, usage.fiveHourError, lastFiveHourSuccessAt, fiveHourStale),
                     quota("7 天", usage.sevenDayUsed, usage.sevenDayReset, usage.sevenDayError, lastSevenDaySuccessAt, sevenDayStale),
                     quota("月度", usage.monthUsed, usage.monthReset, usage.monthError, lastMonthSuccessAt, monthStale)],
            resetCards: nil, tibo: nil,
            codexTokens: section("Kimi Work 用量", .codex, [usage.tokensToday, usage.tokens7d, usage.tokens30d], usage.workTokensError, workTokensLastSuccessAt, tokensStale),
            externalTokens: section("API 客户端用量 · 仅 Kimi 模型", .external, [usage.cliTokensToday, usage.cliTokens7d, usage.cliTokens30d], usage.cliTokensError, cliTokensLastSuccessAt, cliTokensStale),
            notices: [], lastAttempt: "最近尝试刷新 \(Fmt.time(lastAttemptAt))", version: "版本 \(BuildInfo.version)",
            refreshItem: item("立即刷新", #selector(onRefresh)), loginItem: login, quitItem: item("退出", #selector(onQuit))))
    }

    private func configureVisualPreview() {
        let args = CommandLine.arguments
        if args.contains("--visual-preview-dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if args.contains("--visual-preview-narrow") { panelController.previewWidth = 300 }
        let now = Date(timeIntervalSince1970: 1_793_702_400)
        lastAttemptAt = now
        lastFiveHourSuccessAt = now; lastSevenDaySuccessAt = now; lastMonthSuccessAt = now
        workTokensLastSuccessAt = now; cliTokensLastSuccessAt = now
        usage.fiveHourUsed = 0.23; usage.sevenDayUsed = 0.67; usage.monthUsed = 0.42
        usage.fiveHourReset = now.addingTimeInterval(18000); usage.sevenDayReset = now.addingTimeInterval(604800); usage.monthReset = now.addingTimeInterval(2592000)
        usage.tokensToday = TokenStat(input: 1230000, output: 320000); usage.tokens7d = TokenStat(input: 8200000, output: 1200000); usage.tokens30d = TokenStat(input: 32000000, output: 5100000)
        usage.cliTokensToday = TokenStat(input: 5400000, output: 230000); usage.cliTokens7d = TokenStat(input: 61000000, output: 890000); usage.cliTokens30d = TokenStat(input: 440000000, output: 2100000)
        if args.contains("--visual-preview-empty") { usage = UsageData() }
        if args.contains("--visual-preview-states") || args.contains("--visual-preview-long") {
            let message = args.contains("--visual-preview-long") ? String(repeating: "网络连接失败，请稍后重试。", count: 80) : "网络连接失败"
            usage.fiveHourError = message; usage.sevenDayUsed = nil; usage.sevenDayError = "凭证已过期"; usage.monthError = "月度接口不可用"
            usage.workTokensError = message; usage.cliTokensError = "会话目录不可读"
        }
        rebuildMenu(); renderBar()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, let button = self.statusItem.button else { return }
            self.panelController.toggle(anchoredTo: button)
            if args.contains("--visual-preview-test") {
                guard self.panelController.verifyPreviewInteractions(expectScroll: args.contains("--visual-preview-long")) else {
                    fputs("KimiUsage visual interaction test: FAIL\n", stderr); exit(1)
                }
                button.performClick(nil)
                guard !self.panelController.isOpen else { fputs("toggle close failed\n", stderr); exit(1) }
                button.performClick(nil)
                guard self.panelController.isOpen else { fputs("toggle open failed\n", stderr); exit(1) }
                print("KimiUsage visual interaction test: PASS")
                exit(0)
            }
            let prefix = "--visual-preview-output="
            if let arg = args.first(where: { $0.hasPrefix(prefix) }) {
                let path = String(arg.dropFirst(prefix.count))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if args.contains("--visual-preview-scroll-end") { _ = self.panelController.scrollToEndForPreview() }
                    exit(self.panelController.savePreviewImage(to: path) ? 0 : 1)
                }
            }
        }
    }

    private func manualUpdateCheck() {
        if visualPreview { panelController.setUpdateMessage("预览模式：未联网检查更新"); return }
        panelController.setUpdateMessage("正在检查更新…")
        UpdateChecker.shared.check(force: true) { [weak self] in
            guard let self = self else { return }
            self.rebuildMenu()
            self.panelController.setUpdateMessage(UpdateChecker.shared.lastError ? "检查失败，请稍后重试" : (UpdateCheck.normalized(BuildInfo.version) == nil ? "当前版本无法比较" : (UpdateChecker.shared.available ? "发现新版本" : "已是最新版本")))
        }
    }

    // MARK: 开机自启（LaunchAgent）

    private var launchAgentPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(launchAgentLabel).plist"
    }

    private func isLoginItemEnabled() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentPath)
    }

    @objc private func onToggleLogin() {
        guard !visualPreview else { return }
        if isLoginItemEnabled() {
            try? FileManager.default.removeItem(atPath: launchAgentPath)
        } else {
            let exec = Bundle.main.executablePath ?? ""
            // KeepAlive 仅在非正常退出（崩溃/被 kill）时重启：菜单「退出」走 exit 0，launchd 不再复活进程
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key><string>\(launchAgentLabel)</string>
                <key>ProgramArguments</key>
                <array><string>\(exec)</string></array>
                <key>RunAtLoad</key><true/>
                <key>KeepAlive</key>
                <dict><key>SuccessfulExit</key><false/></dict>
            </dict>
            </plist>
            """
            try? plist.write(toFile: launchAgentPath, atomically: true, encoding: .utf8)
        }
        updateUI()
    }

    @objc private func onRefresh() { if !visualPreview { refresh(manual: true) } }

    // 更新检查完成后无条件重建菜单：横幅出现/消失都靠它自愈（刷新周期 ≤30s 也会兜底重建）
    private func checkForUpdate() {
        UpdateChecker.shared.check { [weak self] in self?.updateUI() }
    }

    // 更新横幅点击：唤起 Terminal 代跑 .app 内置 update.sh（从 GitHub Releases 下载最新
    // 发布包 → 替换本 app → 重启）；脚本随包携带，不依赖 clone 目录。
    // 内置脚本缺失（手工换包破坏 bundle）时退化为打开 Releases 页手动下载
    @objc private func onUpdateApp() {
        guard !visualPreview else { return }
        if let script = Bundle.main.path(forResource: "update", ofType: "sh"),
           let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.open([URL(fileURLWithPath: script)], withApplicationAt: terminal,
                configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            return
        }
        NSWorkspace.shared.open(UpdateCheck.releasesPage)
    }

    @objc private func onQuit() { NSApp.terminate(nil) }
}

enum KimiOfflineRegression {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(description: message) }
    }

    static func run() -> Int32 {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KimiUsage-self-test-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            try expect(UsageNumber.finite(Double.nan) == nil, "NaN accepted")
            try expect(UsageNumber.finite("Infinity") == nil, "Infinity accepted")
            try expect(UsageNumber.unitRatio("1.2") == nil, "out-of-range month ratio accepted")

            let absent = Fetcher.parseCodeUsagePayload([:])
            try expect(absent.fiveHourUsed == nil && absent.fiveHourError != nil, "missing 5H was not rejected")
            try expect(absent.sevenDayUsed == nil && absent.sevenDayError != nil, "missing 7D was not rejected")

            let partial = Fetcher.parseCodeUsagePayload([
                "usage": ["limit": "100", "remaining": "25"],
                "limits": [["window": ["duration": 300, "timeUnit": "TIME_UNIT_MINUTE"],
                            "detail": ["limit": "100", "used": "NaN", "remaining": "80"]]]
            ])
            try expect(partial.sevenDayUsed == 0.75, "valid 7D window lost when 5H invalid")
            try expect(partial.fiveHourUsed == nil && partial.fiveHourError != nil,
                       "invalid 5H fields were treated as zero or accepted")

            let partialReverse = Fetcher.parseCodeUsagePayload([
                "usage": ["limit": "NaN", "remaining": "0"],
                "limits": [["window": ["duration": 5, "timeUnit": "TIME_UNIT_HOUR"],
                            "detail": ["limit": "100", "used": "0"]]]
            ])
            try expect(partialReverse.fiveHourUsed == 0, "valid zero-use 5H value rejected")
            try expect(partialReverse.sevenDayUsed == nil && partialReverse.sevenDayError != nil,
                       "invalid 7D fields were treated as zero")
            try expect(Fetcher.parseMonthUsagePayload(["balances": [
                ["feature": "FEATURE_OMNI", "amountUsedRatio": 0.5]
            ]]).monthUsed == 0.5, "valid monthly ratio rejected")
            try expect(Fetcher.parseMonthUsagePayload(["balances": [
                ["feature": "FEATURE_OMNI", "amountUsedRatio": "NaN"]
            ]]).monthUsed == nil, "invalid monthly ratio accepted")

            // 扫描失败面：已安装来源全部不可读才置错；未安装/部分可读/仅 hermes 成功均不置错
            try expect(TokenAggregator.sourceError(installed: 1, enumerated: 0, hermesOK: nil) != nil,
                       "unreadable installed root was reported as success")
            try expect(TokenAggregator.sourceError(installed: 0, enumerated: 0, hermesOK: nil) == nil,
                       "not-installed source was reported as failure")
            try expect(TokenAggregator.sourceError(installed: 2, enumerated: 1, hermesOK: nil) == nil,
                       "partially readable sources were reported as total failure")
            try expect(TokenAggregator.sourceError(installed: 0, enumerated: 0, hermesOK: false) != nil,
                       "corrupt hermes db was reported as success")
            try expect(TokenAggregator.sourceError(installed: 1, enumerated: 0, hermesOK: true) == nil,
                       "healthy hermes source did not clear the failure")
            // 窗口口径：含今天共 7/30 个日历日（起算日 = 今天 −6/−29 天，此前 8/31 天）
            let cutNow = Date(timeIntervalSince1970: 1_800_000_000)
            let cuts = TokenAggregator.windowCutoffs(now: cutNow)
            try expect(cuts.d7 == TokenAggregator.dayFmt.string(from: cutNow.addingTimeInterval(-6 * 86400))
                       && cuts.d30 == TokenAggregator.dayFmt.string(from: cutNow.addingTimeInterval(-29 * 86400)),
                       "7/30 calendar-day window cutoffs drifted")

            let gate = RefreshGate()
            try expect(gate.begin(manual: false), "initial refresh gate did not open")
            try expect(!gate.begin(manual: false), "overlapping timer refresh started")
            try expect(!gate.begin(manual: true) && !gate.begin(manual: true), "manual overlap started immediately")
            try expect(gate.finish(), "manual refresh was not coalesced into one follow-up")
            try expect(!gate.begin(manual: false), "gate dropped active follow-up state")
            try expect(!gate.finish() && gate.begin(manual: false), "gate was not released after follow-up")
            let now = Date(timeIntervalSince1970: 1_000)
            try expect(RefreshSchedule.shouldRunSlow(manual: false, lastAttempt: nil, now: now),
                       "initial slow refresh was not due")
            try expect(!RefreshSchedule.shouldRunSlow(manual: false, lastAttempt: now, now: now.addingTimeInterval(299)),
                       "slow refresh ran before five minutes")
            try expect(RefreshSchedule.shouldRunSlow(manual: false, lastAttempt: now, now: now.addingTimeInterval(300)),
                       "slow refresh was not due after five minutes")
            try expect(RefreshSchedule.shouldRunSlow(manual: true, lastAttempt: now, now: now),
                       "manual refresh did not force slow items")
            let successTime = Date(timeIntervalSince1970: 900)
            try expect(DataFreshness.updated(successTime, succeeded: false, at: now) == successTime,
                       "failed window advanced its last-success time")
            try expect(DataFreshness.updated(successTime, succeeded: true, at: now) == now,
                       "successful window did not advance independently")
            try expect(DataFreshness.isStale(lastSuccess: successTime, hasData: true,
                                             now: now, after: 50), "old retained value was not marked stale")

            let authPath = root.appendingPathComponent("config.json").path
            func document(_ access: String, _ refresh: String, _ extra: String, _ updatedAt: String) -> [String: Any] {
                ["untouched": extra,
                 "credentials": ["kimiWeb": ["accessToken": access, "refreshToken": refresh,
                                               "updatedAt": updatedAt, "other": "keep"],
                                 "kimiCode": ["apiKey": "fake-api-key"]]]
            }
            let initial = try JSONSerialization.data(withJSONObject: document("old-access", "old-refresh", "before", "before-time"))
            try initial.write(to: URL(fileURLWithPath: authPath))
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: authPath)
            let expected = CredStore.WebTokens(access: "old-access", refresh: "old-refresh")

            // Simulate Kimi changing both tokens while our HTTP request is in flight.
            let clientUpdate = try JSONSerialization.data(withJSONObject: document("client-access", "client-refresh", "client-change", "client-time"))
            try clientUpdate.write(to: URL(fileURLWithPath: authPath), options: .atomic)
            let beforeConflict = try Data(contentsOf: URL(fileURLWithPath: authPath))
            let conflict = try CredStore.mergeWebTokens(at: authPath, expected: expected,
                                                        access: "stale-response", refresh: "stale-refresh")
            try expect(!conflict.wrote && conflict.access == "client-access", "client token rotation was overwritten")
            let afterConflict = try Data(contentsOf: URL(fileURLWithPath: authPath))
            try expect(afterConflict == beforeConflict,
                       "conflict path modified the latest client document")
            let conflictDocument = try JSONSerialization.jsonObject(with: afterConflict) as! [String: Any]
            let conflictWeb = ((conflictDocument["credentials"] as! [String: Any])["kimiWeb"] as! [String: Any])
            try expect(conflictWeb["updatedAt"] as? String == "client-time",
                       "conflict path changed the official client updatedAt")

            let latest = CredStore.WebTokens(access: "client-access", refresh: "client-refresh")
            let rotationTime = Date(timeIntervalSince1970: 1_800_000_000)
            let success = try CredStore.mergeWebTokens(at: authPath, expected: latest,
                                                       access: "rotated-access", refresh: "rotated-refresh",
                                                       now: rotationTime)
            try expect(success.wrote && success.access == "rotated-access", "credential rotation did not write")
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: authPath))) as! [String: Any]
            let savedCredentials = saved["credentials"] as! [String: Any]
            let savedWeb = savedCredentials["kimiWeb"] as! [String: Any]
            try expect(saved["untouched"] as? String == "client-change", "latest unrelated field was lost")
            try expect(savedWeb["other"] as? String == "keep", "unrelated Kimi web field was lost")
            try expect(savedWeb["accessToken"] as? String == "rotated-access"
                       && savedWeb["refreshToken"] as? String == "rotated-refresh", "rotated auth values not saved")
            try expect(savedWeb["updatedAt"] as? String == ISO8601DateFormatter().string(from: rotationTime),
                       "successful rotation did not update credentials.kimiWeb.updatedAt")
            let permissions = try FileManager.default.attributesOfItem(atPath: authPath)[.posixPermissions] as! NSNumber
            try expect(permissions.intValue & 0o077 == 0, "credential file gained group/other access")

            let failedTarget = root.appendingPathComponent("directory-target").path
            try FileManager.default.createDirectory(atPath: failedTarget, withIntermediateDirectories: false)
            try Data("marker".utf8).write(to: URL(fileURLWithPath: failedTarget).appendingPathComponent("marker"))
            var writeFailed = false
            do { try AtomicJSONFile.replace(Data("new".utf8), at: failedTarget) }
            catch { writeFailed = true }
            try expect(writeFailed, "atomic write failure was swallowed")

            let cachePath = root.appendingPathComponent("scan-state.json").path
            let cache = Data("{\"a\":1}".utf8)
            let initialWrite = try ScanStateFile.writeIfChanged(cache, to: cachePath)
            try expect(initialWrite, "initial cache write skipped")
            let cacheDate = try FileManager.default.attributesOfItem(atPath: cachePath)[.modificationDate] as! Date
            let secondWrite = try ScanStateFile.writeIfChanged(cache, to: cachePath)
            try expect(!secondWrite, "unchanged cache was rewritten")
            let cacheDateAfter = try FileManager.default.attributesOfItem(atPath: cachePath)[.modificationDate] as! Date
            try expect(cacheDateAfter == cacheDate, "unchanged cache modification time changed")

            // Token 窗口树形行：├/└ 分支、两空格缩进，空数据显示「暂无记录」
            let windowTree = TokenWindowLines.render([
                ("今日", TokenStat(input: 1234, output: 56)),
                ("近 7 天", nil),
                ("近 30 天", TokenStat(input: 0, output: 0))
            ])
            try expect(windowTree == [
                "  ├ 今日：入 1.23K · 出 56 · 计 1.29K",
                "  ├ 近 7 天：暂无记录",
                "  └ 近 30 天：暂无记录"
            ], "token window tree lines did not render with branch symbols")
            try expect(TokenWindowLines.render([]).isEmpty,
                       "empty token window rows still rendered lines")

            // 更新检查：Release 版本号比较（v 前缀与 describe/dirty 尾巴剥离、逐段数值、短侧补 0、无法解析不提示）
            try expect(!UpdateCheck.isOutdated(local: "v1.0.1", remote: "v1.0.1"), "same release flagged outdated")
            try expect(UpdateCheck.isOutdated(local: "v1.0.0-1-g95952a1", remote: "v1.0.1"), "newer release not detected")
            try expect(!UpdateCheck.isOutdated(local: "v1.0.1", remote: "v1.0.0"), "older release flagged outdated")
            try expect(UpdateCheck.isOutdated(local: "v1.9", remote: "v1.10"), "segments compared as numbers, not strings")
            try expect(!UpdateCheck.isOutdated(local: "v1.10", remote: "v1.9"), "segments compared as numbers, not strings")
            try expect(!UpdateCheck.isOutdated(local: "v1.2", remote: "v1.2.0"), "shorter version not zero-padded")
            try expect(!UpdateCheck.isOutdated(local: "v1.0.0-dirty", remote: "v1.0.0"), "dirty suffix not stripped")
            try expect(UpdateCheck.isOutdated(local: "v1.0.0", remote: "v1.0.1-beta"), "prerelease suffix not stripped")
            try expect(!UpdateCheck.isOutdated(local: "unknown", remote: "v9.9.9"), "unknown local version flagged outdated")
            try expect(!UpdateCheck.isOutdated(local: "v1.0.0", remote: "unknown"), "unknown remote version flagged outdated")
            try expect(!UpdateCheck.isOutdated(local: "", remote: "v1.0.0"), "empty local version flagged outdated")
            try expect(!UpdateCheck.isOutdated(local: "abc", remote: "1.2"), "non-numeric local version flagged outdated")

            print("KimiUsage --self-test: PASS (strict quota parsing, per-window partial success, token window tree lines, refresh gate/schedule, credential merge/permissions/failure, cache no-op, update check release version compare)")
            return 0
        } catch {
            fputs("KimiUsage --self-test: FAIL: \(error)\n", stderr)
            return 1
        }
    }
}

// MARK: - 入口（支持 --once 命令行自检）

if CommandLine.arguments.contains("--self-test") {
    exit(KimiOfflineRegression.run())
}

if CommandLine.arguments.contains("--once") {
    // 命令行自检模式：拉一次数据打印后退出
    let cred = CredStore.load()
    let group = DispatchGroup()
    // 网络回调来自不同线程，与 App 主路径同款经锁合并；避免 wait 超时后边写边读
    let onceLock = NSLock()
    var merged = UsageData()
    func applyResult(_ body: (inout UsageData) -> Void, leave: Bool = true) {
        onceLock.lock()
        body(&merged)
        onceLock.unlock()
        if leave { group.leave() }
    }
    if let key = cred.codeApiKey {
        group.enter()
        Fetcher.fetchCodeUsage(apiKey: key) { r in
            applyResult { current in
                current.fiveHourUsed = r.fiveHourUsed
                current.fiveHourReset = r.fiveHourReset
                current.sevenDayUsed = r.sevenDayUsed
                current.sevenDayReset = r.sevenDayReset
                current.fiveHourError = r.fiveHourError
            }
        }
    } else { print("no kimiCode apiKey found") }
    if let token = cred.webToken {
        group.enter()
        Fetcher.fetchMonthUsage(webToken: token) { r in
            if let err = r.monthError, err.contains("401") {
                Fetcher.refreshWebToken { newToken in
                    if let newToken = newToken {
                        Fetcher.fetchMonthUsage(webToken: newToken) { r2 in
                            applyResult { current in
                                current.monthUsed = r2.monthUsed
                                current.monthReset = r2.monthReset
                                current.monthError = r2.monthError
                            }
                        }
                    } else {
                        applyResult { $0.monthError = "HTTP 401（自刷新失败）" }
                    }
                }
            } else {
                applyResult { current in
                    current.monthUsed = r.monthUsed
                    current.monthReset = r.monthReset
                    current.monthError = r.monthError
                }
            }
        }
    } else { print("no kimiWeb token found") }
    // 月度 401 时存在 刷新→重试 串行链（每段最长 15s），20s 会截断重试结果
    _ = group.wait(timeout: .now() + 45)
    onceLock.lock()
    let snapshot = merged
    onceLock.unlock()
    func rem(_ used: Double?) -> Double? { used.map { max(0, min(1, 1 - $0)) } }
    let detailed = TokenAggregator.aggregateBothDetailed()
    let (work, cli) = (detailed.work, detailed.cli)
    if let e = detailed.workError { print("work tokens error: \(e)") }
    if let e = detailed.cliError { print("api tokens error: \(e)") }
    let (tt, tw, tm) = work
    print("menubar: 5H \(Fmt.pct(rem(snapshot.fiveHourUsed))) / 7D \(Fmt.pct(rem(snapshot.sevenDayUsed)))")
    print("5h remaining=\(Fmt.pctLong(rem(snapshot.fiveHourUsed))) reset=\(Fmt.dayTime(snapshot.fiveHourReset))")
    print("7d remaining=\(Fmt.pctLong(rem(snapshot.sevenDayUsed))) reset=\(Fmt.dayTime(snapshot.sevenDayReset))")
    print("month remaining=\(Fmt.pctLong(rem(snapshot.monthUsed))) reset=\(Fmt.dayTime(snapshot.monthReset))")
    print("tokens today: in=\(Fmt.tokens(tt.input)) out=\(Fmt.tokens(tt.output)) total=\(Fmt.tokens(tt.total))")
    print("tokens 7d:    in=\(Fmt.tokens(tw.input)) out=\(Fmt.tokens(tw.output)) total=\(Fmt.tokens(tw.total))")
    print("tokens 30d:   in=\(Fmt.tokens(tm.input)) out=\(Fmt.tokens(tm.output)) total=\(Fmt.tokens(tm.total))")
    let (ct, cw, cm) = cli
    print("api tokens today: in=\(Fmt.tokens(ct.input)) out=\(Fmt.tokens(ct.output)) total=\(Fmt.tokens(ct.total))")
    print("api tokens 7d:    in=\(Fmt.tokens(cw.input)) out=\(Fmt.tokens(cw.output)) total=\(Fmt.tokens(cw.total))")
    print("api tokens 30d:   in=\(Fmt.tokens(cm.input)) out=\(Fmt.tokens(cm.output)) total=\(Fmt.tokens(cm.total))")
    if let e = snapshot.fiveHourError { print("5h error: \(e)") }
    if let e = snapshot.monthError { print("month error: \(e)") }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // 不显示 Dock 图标
let delegate = AppDelegate()
app.delegate = delegate
app.run()
