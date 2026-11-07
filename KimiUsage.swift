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

struct ModelTokenStat {
    var input: Double = 0
    var output: Double = 0
    var total: Double { input + output }
}

struct TokenStat {
    var input: Double = 0    // 含缓存读取/创建的输入
    var output: Double = 0
    var models: [String: ModelTokenStat] = [:]
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
    var planName: String?          // 订阅套餐名（GetSubscription subscription.goods.title）
    var accountName: String?       // 登录账号昵称（GET /api/user name）
    var accountPhone: String?      // 登录账号手机号（服务端已打码）；Kimi 账号可能无 email，头部账号行用
    var accountFetched: Bool = false
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
    // v1.5 用量洞察：合并视图（Work + API 客户端）、逐日序列与逐工具贡献，同一扫描快照派生
    var mergedTokens: (today: TokenStat, week: TokenStat, month: TokenStat)?
    var daily: [String: [Double]] = [:]
    var tools: [TokenAggregator.ToolStats] = []
    var staleTokensInWindow: Double = 0
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

    typealias ModelDays = [String: [String: [Double]]]  // day -> model -> [input, output]

    // days 保留用于兼容旧缓存与对账；modelDays 是窗口汇总和模型明细的共同数据源。
    struct FileScanState: Codable {
        var offset: UInt64 = 0
        var days: [String: [Double]] = [:]
        var modelDays: ModelDays = [:]
        /// 已出现 usage.record 的 Work 文件，在追加后重扫以重新匹配镜像。
        var preferUsageRecord: Bool = false
        var scanRevision: Int? = nil
    }
    struct ScanState: Codable {
        var work: [String: FileScanState] = [:]   // Kimi Work 本地会话
        var cli: [String: FileScanState] = [:]    // API 客户端（仅 Kimi 模型）
        var hermes: HermesState?                  // hermes（sqlite 快照差分）
        var zcodeDays: [String: [Double]]?         // 最近一次成功快照（兼容旧调用）
        var zcodeModelDays: ModelDays?             // 同一快照的模型维度
    }
    /// hermes session_model_usage 是 (session,model,...) 级累计行：rows 存上次快照，
    /// 每次刷新做差，delta 按行的 last_seen 归入该 row 自己的 days。
    /// rowDays 分行保存，键变化/行删除时同步撤掉旧贡献，避免换 key 后新行全量回填造成双算。
    struct HermesState: Codable {
        var rows: [String: [Double]] = [:]                 // rowKey -> [累计input, 累计output]
        var rowDays: [String: [String: [Double]]] = [:]    // rowKey -> dayKey -> [input, output]
        var days: [String: [Double]] {
            var total: [String: [Double]] = [:]
            for days in rowDays.values {
                for (day, v) in days {
                    var a = total[day] ?? [0, 0]
                    a[0] += v[0]; a[1] += v[1]
                    total[day] = a
                }
            }
            return total
        }
        var modelDays: ModelDays {
            var result: ModelDays = [:]
            for (key, days) in rowDays {
                let fields = key.split(separator: "|", omittingEmptySubsequences: false)
                let model = fields.count > 1 ? TokenAggregator.normalizedModel(String(fields[1])) : "未知模型"
                for (day, value) in days {
                    var current = result[day]?[model] ?? [0, 0]
                    current[0] += value[0]; current[1] += value[1]
                    result[day, default: [:]][model] = current
                }
            }
            return result
        }
    }

    // v6：增加按天按模型聚合并重建文件缓存；保留旧 Hermes / ZCode 快照。
    static let statePath = NSHomeDirectory()
        + "/Library/Application Support/KimiUsage/scan-state-v6.json"
    private static var state: ScanState?
    private static let lock = NSLock()

    // 只关心近 30 天窗口，日聚合保留 31 天余量
    private static let retainSeconds: TimeInterval = 31 * 86400

    static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"   // 本地时区，与旧逻辑 Calendar.current 一致
        return f
    }()

    /// Claude SDK / ZCode 可混接多家 API，按 model 字段甄别 Kimi。
    /// 缺失模型默认不归属；可信 Kimi Code 目录的旧格式由调用方单独放行。
    static func isKimiModel(_ model: String?) -> Bool {
        guard let m = model?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !m.isEmpty else { return false }
        if m.contains("kimi") || m.contains("moonshot") { return true }
        return m.hasPrefix("k") && m.count > 1 && m[m.index(after: m.startIndex)].isNumber
    }

    static func normalizedModel(_ model: String?) -> String {
        var name = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.lowercased().hasPrefix("kimi-code/") {
            name = String(name.dropFirst("kimi-code/".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let known = ["k3.1-pro", "k3-256k", "k3", "kimi-for-coding"]
        if known.contains(name.lowercased()) { return name.lowercased() }
        return name.isEmpty ? "未知模型" : name
    }

    static func modelDisplayName(_ model: String) -> String {
        let name = normalizedModel(model)
        switch name {
        case "k3.1-pro": return "K3.1 Pro"
        case "k3-256k": return "K3-256k"
        case "k3": return "K3"
        case "kimi-for-coding": return "Kimi for Coding"
        default: return name
        }
    }

    private static func loadState() -> ScanState {
        if let s = state { return s }
        if let data = FileManager.default.contents(atPath: statePath),
           let s = try? JSONDecoder().decode(ScanState.self, from: data) {
            state = s
            return s
        }
        // 保留旧缓存；文件通过 scanRevision 全量重建，sqlite 快照继续增量对账。
        let oldPath = statePath.replacingOccurrences(of: "scan-state-v6.json", with: "scan-state-v5.json")
        let s = (FileManager.default.contents(atPath: oldPath)).flatMap { try? JSONDecoder().decode(ScanState.self, from: $0) } ?? ScanState()
        state = s
        return s
    }

    private static func saveState(_ s: ScanState) {
        do { try ScanStateFile.writeIfChanged(ScanStateFile.encoded(s), to: statePath) }
        catch { NSLog("[KimiUsage] scan cache save failed: %@", error.localizedDescription) }
    }

    /// 双路统计 + 失败面：work/cli 各自的错误（已安装来源全部不可读时非 nil）。
    /// merged / daily / tools 为 v1.5 用量洞察的合并视图：与 work+cli 同一扫描快照派生，
    /// 逐工具窗口之和 = 合并总量（原始精度）。
    struct BothStats {
        var work: (TokenStat, TokenStat, TokenStat)
        var cli: (TokenStat, TokenStat, TokenStat)
        var workError: String?
        var cliError: String?
        var merged: (today: TokenStat, week: TokenStat, month: TokenStat)
        var daily: [String: [Double]]
        var tools: [ToolStats]
    }

    /// Kimi Work 本地会话统计
    static func aggregateBoth() -> (work: (TokenStat, TokenStat, TokenStat), cli: (TokenStat, TokenStat, TokenStat)) {
        let d = aggregateBothDetailed()
        return (d.work, d.cli)
    }

    static func aggregateBothDetailed(persist: Bool = true) -> BothStats {
        lock.lock(); defer { lock.unlock() }
        var st = loadState()
        let workScan = scan(roots: [sessionsRoot], kimiOnly: false, into: &st.work)
        let cliScan = scan(roots: apiSessionsRoots, kimiOnly: true, into: &st.cli)
        var hermesOK: Bool?   // nil = 未安装（state.db 不存在），不算失败
        if FileManager.default.fileExists(atPath: hermesDBPath) {
            hermesOK = scanHermes(into: &st)
        }
        var zcodeOK: Bool?    // nil = 未安装（db.sqlite 不存在），不算失败
        if FileManager.default.fileExists(atPath: zcodeDBPath) || st.zcodeDays != nil || st.zcodeModelDays != nil {
            zcodeOK = updateZCode(into: &st, at: zcodeDBPath)
        }
        let cutoffKey = dayFmt.string(from: Date().addingTimeInterval(-retainSeconds))
        st.zcodeDays = st.zcodeDays?.filter { $0.key >= cutoffKey }
        st.zcodeModelDays = st.zcodeModelDays?.filter { $0.key >= cutoffKey }
        state = st
        if persist { saveState(st) }
        // 旧缓存没有模型维度时保留总量并归入未知模型；数据库恢复后会自动替换为真实模型。
        let zcodeModels = st.zcodeModelDays ?? (st.zcodeDays ?? [:]).mapValues { ["未知模型": $0] }
        let extraModels = mergeSourceModelDays(st.hermes?.modelDays ?? [:], zcodeModels)
        // v1.5 用量洞察：逐工具贡献（Work + 5 类 API 客户端），与上方窗口同一扫描快照。
        var tools: [ToolStats] = [
            fileToolStats(id: .work, roots: [sessionsRoot], okRoots: workScan.okRoots, files: st.work),
            fileToolStats(id: .cli, roots: [apiSessionsRoots[0]], okRoots: cliScan.okRoots, files: st.cli),
            fileToolStats(id: .proma, roots: Array(apiSessionsRoots[1...2]), okRoots: cliScan.okRoots, files: st.cli),
            fileToolStats(id: .claude, roots: [apiSessionsRoots[3]], okRoots: cliScan.okRoots, files: st.cli)
        ]
        if hermesOK != nil {
            tools.append(ToolStats(id: .hermes, modelDays: st.hermes?.modelDays ?? [:],
                                   installed: true, ok: hermesOK == true))
        }
        if zcodeOK != nil {
            tools.append(ToolStats(id: .zcode, modelDays: zcodeModels, installed: true, ok: zcodeOK == true))
        }
        var mergedDays: ModelDays = [:]
        for tool in tools { mergedDays = mergeSourceModelDays(mergedDays, tool.modelDays) }
        return BothStats(
            work: buckets(st.work), cli: buckets(st.cli, extraModelDays: extraModels),
            workError: sourceError(installed: workScan.installed, enumerated: workScan.enumerated, hermesOK: nil),
            cliError: sourceError(installed: cliScan.installed, enumerated: cliScan.enumerated,
                                  hermesOK: hermesOK, zcodeOK: zcodeOK),
            merged: statWindows(mergedDays),
            daily: dailyTotals(mergedDays),
            tools: tools)
    }

    static func mergeSourceDays(_ first: [String: [Double]], _ second: [String: [Double]]) -> [String: [Double]] {
        var result = first
        for (day, value) in second {
            var total = result[day] ?? [0, 0]
            total[0] += value[0]; total[1] += value[1]
            result[day] = total
        }
        return result
    }

    static func mergeSourceModelDays(_ first: ModelDays, _ second: ModelDays) -> ModelDays {
        // 在聚合边界归一，也兼容旧缓存里的提供商前缀，不必重建 API 来源。
        var result: ModelDays = [:]
        for source in [first, second] {
            for (day, models) in source {
                for (rawModel, value) in models {
                    let model = normalizedModel(rawModel)
                    var total = result[day]?[model] ?? [0, 0]
                    total[0] += value[0]; total[1] += value[1]
                    result[day, default: [:]][model] = total
                }
            }
        }
        return result
    }

    /// 失败面判定：有已安装来源（目录 / sqlite 库存在）但无一可读 → 错误；
    /// 全部未安装（路径不存在）返回 nil——没装对应工具时该来源自然为 0，不算失败；
    /// 部分来源失败时返回提示，并保留失败来源最近一次贡献。
    static func sourceError(installed: Int, enumerated: Int, hermesOK: Bool?, zcodeOK: Bool? = nil) -> String? {
        let anySource = installed > 0 || hermesOK != nil || zcodeOK != nil
        let anySuccess = enumerated > 0 || hermesOK == true || zcodeOK == true
        if anySource && !anySuccess { return "会话目录 / 客户端用量数据库均不可读" }
        if enumerated < installed || hermesOK == false || zcodeOK == false { return "部分来源读取失败，显示上次数据" }
        return nil
    }

    /// 本地日历日键（yyyy-MM-dd）：与 dayFmt 同口径，但支持注入 Calendar 以便测试 DST/跨月。
    static func dayKey(_ offset: Int, from now: Date, calendar: Calendar = .current) -> String {
        let date = calendar.date(byAdding: .day, value: offset, to: now)
            ?? now.addingTimeInterval(Double(offset) * 86400)
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 窗口起算日：含今天共 7 / 30 个日历日（Calendar 日历日运算，覆盖 DST 与跨月；
    /// 此前为固定 86400 秒回退，跨夏令时日界会漂移一天）
    static func windowCutoffs(now: Date, calendar: Calendar = .current) -> (d7: String, d30: String) {
        (dayKey(-6, from: now, calendar: calendar), dayKey(-29, from: now, calendar: calendar))
    }

    /// 兼容既有调用；主刷新使用 aggregateBoth 合并扫描和缓存写入。
    static func aggregate() -> (TokenStat, TokenStat, TokenStat) { aggregateBoth().work }

    /// API 客户端（ZCode / Kimi Code CLI / Proma / Claude Code / hermes）中的 Kimi 用量统计
    static func aggregateCLI() -> (TokenStat, TokenStat, TokenStat) {
        aggregateBoth().cli
    }

    /// 全解析符号链接的绝对路径（realpath(3)）；路径不存在时原样返回。
    /// 枚举器产出的 url.path 是 realpath 形式（如 /var → /private/var；URL 的
    /// resolvingSymlinksInPath 不解析根级链接），前缀清理必须同口径才能匹配上
    static func realPath(_ p: String) -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(p, &buf) != nil else { return p }
        return String(cString: buf)
    }

    /// 增量扫描 roots 下的 jsonl：未变化文件只 stat，追加文件只读新增字节；
    /// 已被删除的文件从状态中剔除（旧全量逻辑下删除即不再计入，保持一致）。
    /// 返回 (已安装 root 数, 成功枚举 root 数)：目录不存在 = 未安装，不计入失败面
    static func scan(roots: [String], kimiOnly: Bool,
                     into files: inout [String: FileScanState]) -> (installed: Int, enumerated: Int, okRoots: [String]) {
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
                // Work v4 按请求关联模型及双写；旧缓存即使文件未变也重建。
                let revision = kimiOnly ? 2 : 4
                // 文件只增不改：大小未变直接跳过（绝大多数文件走这里）
                if st.offset == sizeU && st.scanRevision == revision { files[path] = st; continue }
                // 首次见到且 31 天未修改：不可能贡献近 30 天数据，记录大小后跳过
                if st.offset == 0, st.days.isEmpty, st.modelDays.isEmpty,
                   let mtime = vals.contentModificationDate, mtime < cutoff {
                    st.offset = sizeU; st.scanRevision = revision; files[path] = st; continue
                }
                // 截断/轮换：该文件的旧聚合已不可信，清零重扫
                if sizeU < st.offset { st = FileScanState() }

                guard let fh = try? FileHandle(forReadingFrom: url) else { continue }
                // Work 的请求与用量可跨刷新追加，变更时重扫，避免丢失请求上下文。
                let rebuild = st.scanRevision != revision || !kimiOnly
                if rebuild { st = FileScanState() }
                fh.seek(toFileOffset: st.offset)
                let data = fh.readDataToEndOfFile()
                guard let lastNL = data.lastIndex(of: UInt8(ascii: "\n")) else { try? fh.close(); continue }
                let text = String(data: data[..<lastNL], encoding: .utf8)
                try? fh.close()
                let consumed = st.offset + UInt64(lastNL + 1)
                guard let text else { continue }
                if kimiOnly {
                    let trusted = realPath(root) == realPath(apiSessionsRoots[0])
                    parseLines(text, kimiOnly: true, cutoffKey: cutoffKey, allowMissingModel: trusted, into: &st)
                } else {
                    parseWorkLines(text, cutoffKey: cutoffKey, into: &st)
                }
                st.offset = consumed
                st.scanRevision = revision
                st.days = st.days.filter { $0.key >= cutoffKey }
                st.modelDays = st.modelDays.filter { $0.key >= cutoffKey }
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
        return (installed, enumedRoots.count, enumedRoots)
    }

    // hermes 用量库（sqlite，只读打开，绝不写入）
    private static let hermesDBPath = NSHomeDirectory() + "/.hermes/state.db"

    /// hermes 的 Kimi 用量：只读查询 billing_base_url 指向 kimi.com / moonshot 的累计行。
    /// 每行独立保存快照差分与按日贡献；换 key / 删除行时旧贡献同步移除，
    /// 避免 provider、mode、task 等主键字段变化后，新行全量回填而旧行仍计入。
    /// 返回是否成功读取（库文件不存在由调用方先行排除，不算失败）。
    static func scanHermes(into st: inout ScanState, at path: String = hermesDBPath) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
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
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { return false }
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
            var days = hs.rowDays[key] ?? [:]
            if (dIn > 0 || dOut > 0), lastSeen > 0 {
                let dayKey = dayFmt.string(from: Date(timeIntervalSince1970: lastSeen))
                if dayKey >= cutoffKey {
                    var day = days[dayKey] ?? [0, 0]
                    day[0] += dIn; day[1] += dOut
                    days[dayKey] = day
                }
            }
            hs.rowDays[key] = days.filter { $0.key >= cutoffKey }
        }
        // 换 key / 删除行时，快照和按日贡献必须一起撤掉，不能只清快照。
        hs.rows = hs.rows.filter { alive.contains($0.key) }
        hs.rowDays = hs.rowDays.filter { alive.contains($0.key) }
        st.hermes = hs
        return true
    }

    // ZCode 用量库：model_usage 每次逻辑请求一行；turn_usage / JSONL 是其汇总或并行日志，不叠加。
    private static let zcodeDBPath = NSHomeDirectory() + "/.zcode/cli/db/db.sqlite"

    static func updateZCode(into state: inout ScanState, at path: String, now: Date = Date()) -> Bool {
        guard let modelDays = scanZCodeModelDays(at: path, now: now) else { return false }
        state.zcodeModelDays = modelDays
        state.zcodeDays = days(from: modelDays)
        return true
    }

    static func days(from modelDays: ModelDays) -> [String: [Double]] {
        modelDays.mapValues { models in
            models.values.reduce([0, 0]) { [$0[0] + $1[0], $0[1] + $1[1]] }
        }
    }

    /// 兼容既有对账调用；窗口展示使用同一快照的模型维度。
    static func scanZCode(at path: String = zcodeDBPath, now: Date = Date()) -> [String: [Double]]? {
        scanZCodeModelDays(at: path, now: now).map { days(from: $0) }
    }

    /// 直接按 started_at 索引读取近 31 天明细，天然支持历史回填，无需持久化扫描状态。
    /// input_tokens 已包含 cache read/write（provider_total = input + output），缓存字段不能再加。
    /// error / running 行若已有非零 token 也计入；cancelled 行通常为零，无需按状态丢弃真实消耗。
    static func scanZCodeModelDays(at path: String = zcodeDBPath, now: Date = Date()) -> ModelDays? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT model_id, input_tokens, output_tokens, started_at
            FROM model_usage
            WHERE started_at >= ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        let cutoff = now.addingTimeInterval(-retainSeconds)
        sqlite3_bind_int64(stmt, 1, Int64(cutoff.timeIntervalSince1970 * 1000))
        let cutoffKey = dayFmt.string(from: cutoff)
        var days: ModelDays = [:]
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { return nil }
            let model = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            guard isKimiModel(model) else { continue }
            let startedAt = sqlite3_column_double(stmt, 3)
            guard startedAt > 0 else { continue }
            let dayKey = dayFmt.string(from: Date(timeIntervalSince1970: startedAt / 1000))
            guard dayKey >= cutoffKey else { continue }
            var value = days[dayKey]?[model] ?? [0, 0]
            value[0] += sqlite3_column_double(stmt, 1)
            value[1] += sqlite3_column_double(stmt, 2)
            days[dayKey, default: [:]][model] = value
        }
        return days
    }

    // 请求 ID / agent + turnStep 关联不依赖耗时，兼容工具执行导致延迟的双写。
    // 缺少请求上下文的旧日志，仍只匹配时间和位置邻近的事件。
    static func parseWorkLines(_ text: String, cutoffKey: String, into st: inout FileScanState) {
        struct WorkRequest {
            let lineIndex: Int
            let milliseconds: Double
            let model: String?
            let kind: String?
            let turnStep: String?
            let requestID: String?
        }
        struct WorkEvent {
            let lineIndex: Int
            let agent: String
            let kind: String
            let milliseconds: Double
            let usage: String
            let requestID: String?
            let requestIndex: Int?
            let hasRequestContext: Bool
            var object: [String: Any]
            var model: String?
        }
        func name(_ value: Any?) -> String? {
            guard let value = value as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        func requestID(_ object: [String: Any]) -> String? {
            let event = object["event"] as? [String: Any] ?? [:]
            return name(object["request_id"]) ?? name(object["requestId"])
                ?? name(event["request_id"]) ?? name(event["requestId"])
        }
        var requests: [String: WorkRequest] = [:]
        var events: [WorkEvent] = []
        for (index, line) in text.split(separator: "\n").enumerated() {
            // 只解析请求和逐调用用量；subagent.completed 是子会话汇总，不能再次计入。
            guard line.contains("llm.request") || line.contains("usage.record")
                    || line.contains("context.append_loop_event") else { continue }
            guard let data = line.data(using: .utf8),
                  var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let kind = obj["type"] as? String,
                  let ms = obj["time"] as? Double else { continue }
            let agent = name(obj["agentId"]) ?? ""
            if kind == "llm.request" {
                requests[agent] = WorkRequest(lineIndex: index, milliseconds: ms,
                    model: name(obj["model"]) ?? name(obj["modelAlias"]), kind: name(obj["kind"]),
                    turnStep: name(obj["turnStep"]), requestID: requestID(obj))
                continue
            }
            guard kind == "usage.record" || kind == "context.append_loop_event",
                  let usage = (obj["event"] as? [String: Any])?["usage"] as? [String: Any] ?? obj["usage"] as? [String: Any],
                  let encoded = try? JSONSerialization.data(withJSONObject: usage, options: [.sortedKeys]),
                  let value = String(data: encoded, encoding: .utf8) else { continue }
            let event = obj["event"] as? [String: Any] ?? [:]
            let id = requestID(obj)
            var request = requests[agent]
            if let active = request {
                let conflictingID = id != nil && active.requestID != nil && id != active.requestID
                if ms < active.milliseconds || conflictingID { request = nil }
                if kind == "context.append_loop_event" {
                    let turn = name(event["turnId"])
                    let step = (event["step"] as? Int).map(String.init)
                    let turnStep = turn.flatMap { t in step.map { "\(t).\($0)" } }
                    if active.kind != "loop" || turnStep == nil || turnStep != active.turnStep { request = nil }
                }
            }
            let message = obj["message"] as? [String: Any] ?? [:]
            let model = name(message["model"]) ?? name(obj["model"]) ?? name(event["model"]) ?? request?.model
            if let model { obj["model"] = model }
            events.append(WorkEvent(lineIndex: index, agent: agent, kind: kind, milliseconds: ms, usage: value,
                                    requestID: id, requestIndex: request?.lineIndex,
                                    hasRequestContext: requests[agent] != nil, object: obj, model: model))
        }
        var paired = Set<Int>()
        func compatible(_ i: Int, _ j: Int) -> Bool {
            let a = events[i], b = events[j]
            return a.agent == b.agent && a.usage == b.usage
                && (a.requestID == nil || b.requestID == nil || a.requestID == b.requestID)
                && (a.model == nil || b.model == nil || a.model == b.model)
        }
        func pair(_ i: Int, _ j: Int) {
            // 匹配成功后，缺模型的 record 也可使用另一侧明确记录的模型。
            for (target, source) in [(i, j), (j, i)] where events[target].model == nil {
                if let model = events[source].model {
                    events[target].model = model
                    events[target].object["model"] = model
                }
            }
            paired.insert(i); paired.insert(j)
        }
        // 仅在同 ID 两侧各一条且用量一致时，才作为可验证的关联。
        var loopsByID: [String: [Int]] = [:], recordsByID: [String: [Int]] = [:]
        for i in events.indices {
            guard let id = events[i].requestID else { continue }
            if events[i].kind == "usage.record" { recordsByID[id, default: []].append(i) }
            else { loopsByID[id, default: []].append(i) }
        }
        for (id, loops) in loopsByID {
            guard loops.count == 1, let records = recordsByID[id], records.count == 1,
                  compatible(loops[0], records[0]) else { continue }
            pair(loops[0], records[0])
        }
        var byRequest: [Int: [Int]] = [:]
        for i in events.indices {
            if let request = events[i].requestIndex { byRequest[request, default: []].append(i) }
        }
        for group in byRequest.values {
            let records = group.filter { events[$0].kind == "usage.record" }
            let loops = group.filter { events[$0].kind == "context.append_loop_event" }
            guard records.count == 1, loops.count == 1,
                  !paired.contains(records[0]), !paired.contains(loops[0]), compatible(records[0], loops[0]) else { continue }
            pair(records[0], loops[0])
        }
        // 不凭用量和日期推断：没有冲突 ID 时，限相邻用量事件且时间非常接近。
        if events.count > 1 {
            for i in 0..<(events.count - 1) {
                let j = i + 1, a = events[i], b = events[j]
                guard !paired.contains(i), !paired.contains(j), a.kind != b.kind, compatible(i, j),
                      b.lineIndex - a.lineIndex <= 20, abs(a.milliseconds - b.milliseconds) <= 5_000,
                      !(a.hasRequestContext && a.requestIndex == nil),
                      !(b.hasRequestContext && b.requestIndex == nil),
                      a.requestIndex == nil || b.requestIndex == nil || a.requestIndex == b.requestIndex else { continue }
                pair(i, j)
            }
        }
        let skip = Set(events.indices.filter { paired.contains($0) && events[$0].kind == "context.append_loop_event" }.map { events[$0].lineIndex })
        for event in events where !skip.contains(event.lineIndex) {
            guard let data = try? JSONSerialization.data(withJSONObject: event.object),
                  let line = String(data: data, encoding: .utf8) else { continue }
            parseLines(line, kimiOnly: false, cutoffKey: cutoffKey, into: &st)
        }
        st.preferUsageRecord = events.contains { $0.kind == "usage.record" }
    }

    /// 解析一批完整行，把 usage 按日累加进 st.days（解析逻辑与旧全量版一致）
    static func parseLines(_ text: String, kimiOnly: Bool,
                           cutoffKey: String, preferUsageRecord: Bool = false, allowMissingModel: Bool = false,
                           into st: inout FileScanState) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true)
        where line.contains("\"usage\"") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            // Proma result 行的 modelUsage / 顶层 usage 都是全会话累计汇总，逐条 assistant 行已含每次调用。
            // 有些 result 没有 modelUsage，必须按 type 一并跳过，不能只判断 modelUsage 字段。
            if obj["modelUsage"] != nil { continue }
            let rowType = obj["type"] as? String
            if kimiOnly && rowType == "result" { continue }
            // Kimi Code 的 usage.record 与 context.append_loop_event 是同一次调用的双写。
            // API 只取前者；Kimi Work 旧文件只有 loop 时保留 loop，新文件出现 record 后只取 record。
            if rowType == "context.append_loop_event" && (kimiOnly || preferUsageRecord) { continue }
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
            let event = obj["event"] as? [String: Any] ?? [:]
            let rawModel = (obj["message"] as? [String: Any])?["model"] as? String
                ?? obj["model"] as? String ?? event["model"] as? String
            // 混接客户端只统计 Kimi 模型的行；可信旧格式与 Work 旧镜像归入未知模型。
            if kimiOnly {
                guard isKimiModel(rawModel) || (allowMissingModel && (rawModel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)) else { continue }
            }
            let model = normalizedModel(rawModel)
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
                var modelDay = st.modelDays[dayKey]?[model] ?? [0, 0]
                modelDay[0] += input
                modelDay[1] += output
                st.modelDays[dayKey, default: [:]][model] = modelDay
            }
        }
    }

    /// 从按日 × 模型聚合计算三个窗口（今天及含今天的近 7 / 30 个日历日）。
    /// 模型名须已归一；各模型之和等于周期总量；日图与周期共用同一份数据。
    static func statWindows(_ days: ModelDays, now: Date = Date())
        -> (today: TokenStat, week: TokenStat, month: TokenStat) {
        let todayKey = dayFmt.string(from: now)
        let (d7Key, d30Key) = windowCutoffs(now: now)
        var today = TokenStat(), week = TokenStat(), month = TokenStat()
        func add(_ value: [Double], model: String, to stat: inout TokenStat) {
            stat.input += value[0]; stat.output += value[1]
            var current = stat.models[model] ?? ModelTokenStat()
            current.input += value[0]; current.output += value[1]
            stat.models[model] = current
        }
        for (day, models) in days where day >= d30Key {
            for (model, value) in models {
                add(value, model: model, to: &month)
                if day >= d7Key { add(value, model: model, to: &week) }
                if day >= todayKey { add(value, model: model, to: &today) }
            }
        }
        return (today, week, month)
    }

    /// 按日 × 模型聚合同步生成窗口汇总与明细，保证各模型之和等于周期总量。
    static func buckets(_ files: [String: FileScanState], extraModelDays: ModelDays = [:])
        -> (TokenStat, TokenStat, TokenStat) {
        var allDays: ModelDays = [:]
        for (_, st) in files {
            allDays = mergeSourceModelDays(allDays, st.modelDays)
        }
        allDays = mergeSourceModelDays(allDays, extraModelDays)
        return statWindows(allDays)
    }

    /// 合并视图的逐日总量（不补零；缺键是否为真实 0 由覆盖状态决定）。
    static func dailyTotals(_ days: ModelDays) -> [String: [Double]] {
        var result: [String: [Double]] = [:]
        for (day, models) in days {
            var total = result[day] ?? [0, 0]
            for (_, value) in models {
                total[0] += value[0]; total[1] += value[1]
            }
            result[day] = total
        }
        return result
    }

    /// 用量简析的固定对比项（较昨日 / 较前 7 天）。
    /// 区间以 D=今天为基准、本地日历日运算；仅当覆盖可证实（失败来源在区间内无贡献）才出百分比。
    struct Comparison {
        enum Value {
            case percent(Double)   // 相对变化（%）
            case flat              // 两期持平（含两期均为 0）
            case added(Double)     // 基期为 0、本期为正：不产生无穷百分比
            case insufficient      // 覆盖未证实，不编造百分比
        }
        let day: Value
        let week: Value
        let dayDetail: String      // 具体日期区间与公式（悬停 / VoiceOver）
        let weekDetail: String
    }

    static func comparisons(daily: [String: [Double]], staleTokensInWindow: Double,
                            now: Date = Date(), calendar: Calendar = .current) -> Comparison {
        func key(_ offset: Int) -> String { dayKey(offset, from: now, calendar: calendar) }
        func mmdd(_ key: String) -> String {
            let parts = key.split(separator: "-")
            return parts.count == 3 ? "\(parts[1])/\(parts[2])" : key
        }
        func total(_ from: Int, _ to: Int) -> Double {
            var sum = 0.0
            for offset in from...to {
                if let value = daily[key(offset)] { sum += value[0] + value[1] }
            }
            return sum
        }
        if staleTokensInWindow > 0 {
            return Comparison(day: .insufficient, week: .insufficient,
                              dayDetail: "部分来源读取失败，覆盖未证实",
                              weekDetail: "部分来源读取失败，覆盖未证实")
        }
        func value(_ current: Double, _ previous: Double) -> Comparison.Value {
            if current == previous { return .flat }
            if previous == 0 { return .added(current) }
            let pct = (current - previous) / previous * 100
            if abs(pct) < 0.05 { return .flat }   // GLM 同款：一位小数下防 ±0.0%
            return .percent(pct)
        }
        let dayDetail = "比较区间 \(mmdd(key(-1)))–\(mmdd(key(0)))（今日未结束）· （最近1日总量−前1日总量）÷前1日总量"
        let weekDetail = "比较区间 \(mmdd(key(-13)))–\(mmdd(key(-7))) 与 \(mmdd(key(-6)))–\(mmdd(key(0)))（今日未结束）· （最近7日总量−前7日总量）÷前7日总量"
        return Comparison(day: value(total(0, 0), total(-1, -1)),
                          week: value(total(-6, 0), total(-13, -7)),
                          dayDetail: dayDetail, weekDetail: weekDetail)
    }

    /// 失败来源（保留旧快照）在比较区间 [D-13, D] 内的贡献量；> 0 时比较不可证实。
    static func staleTokensInWindow(tools: [ToolStats], now: Date = Date(),
                                    calendar: Calendar = .current) -> Double {
        let startKey = dayKey(-13, from: now, calendar: calendar)
        var total = 0.0
        for tool in tools where tool.installed && !tool.ok {
            for (day, models) in tool.modelDays where day >= startKey {
                for (_, value) in models { total += value[0] + value[1] }
            }
        }
        return total
    }

    // MARK: 逐工具维度（v1.5 用量洞察）

    /// 面板「工具明细」的来源维度：Work 与 5 类 API 客户端各自独立聚合。
    enum ToolID: String, CaseIterable {
        case work, cli, proma, claude, hermes, zcode

        var displayName: String {
            switch self {
            case .work: return "Kimi Work"
            case .cli: return "Kimi CLI"
            case .proma: return "Proma"
            case .claude: return "Claude Code"
            case .hermes: return "Hermes"
            case .zcode: return "ZCode"
            }
        }
    }

    struct ToolStats {
        let id: ToolID
        let modelDays: ModelDays
        let installed: Bool
        let ok: Bool   // 本轮读取成功；installed 且 !ok = 保留上次快照（stale）
        func windows(now: Date = Date()) -> (today: TokenStat, week: TokenStat, month: TokenStat) {
            statWindows(modelDays, now: now)
        }
    }

    /// CLI 会话文件路径 → 工具归属（两侧都过 realpath，与扫描同口径）。
    static func toolID(forSessionPath rawPath: String, roots: [String] = apiSessionsRoots) -> ToolID {
        let path = realPath(rawPath)
        func under(_ root: String) -> Bool {
            let base = realPath(root)
            return path == base || path.hasPrefix(base + "/")
        }
        if roots.count > 3 {
            if under(roots[3]) { return .claude }
            if under(roots[2]) || under(roots[1]) { return .proma }
            if under(roots[0]) { return .cli }
        }
        return .cli
    }

    /// 从文件状态字典聚合单个工具的按日 × 模型贡献。
    private static func toolModelDays(_ files: [String: FileScanState],
                                      under roots: [String] = []) -> ModelDays {
        var days: ModelDays = [:]
        for (path, st) in files {
            if !roots.isEmpty && !roots.contains(where: { root in
                let base = realPath(root)
                return path == base || path.hasPrefix(base + "/")
            }) { continue }
            days = mergeSourceModelDays(days, st.modelDays)
        }
        return days
    }

    /// 组装逐工具贡献与安装/读取状态。okRoots 为本轮枚举成功的 realpath 集合；
    /// 失败 root 的旧快照贡献保留（工具明细标「部分记录 · 缓存」）。
    private static func fileToolStats(id: ToolID, roots: [String], okRoots: [String],
                                      files: [String: FileScanState]) -> ToolStats {
        var installed = false
        var ok = true
        for root in roots {
            guard FileManager.default.fileExists(atPath: root) else { continue }
            installed = true
            if !okRoots.contains(realPath(root)) { ok = false }
        }
        return ToolStats(id: id, modelDays: toolModelDays(files, under: roots), installed: installed, ok: ok)
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

    /// 本月总额度：Kimi 订阅接口（OMNI 余额）+ 套餐名（与 GLM/Codex 面板标题同款逻辑）
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
        if let goods = (obj["subscription"] as? [String: Any])?["goods"] as? [String: Any],
           let title = goods["title"] as? String, !title.isEmpty {
            result.planName = title
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

    // MARK: 登录账号信息（GET www.kimi.com/api/user，头部账号行）

    /// 昵称与手机号。手机号由服务端打码返回（如 185****5369），客户端原样展示不自行加工；
    /// 昵称缺失回退 shared_user_name；空串一律视为缺失。
    static func parseKimiAccountPayload(_ obj: [String: Any]) -> (name: String?, phone: String?) {
        func clean(_ key: String) -> String? {
            guard let s = obj[key] as? String else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        return (clean("name") ?? clean("shared_user_name"), clean("phone"))
    }

    static func fetchKimiAccount(webToken: String,
                                 completion: @escaping (_ name: String?, _ phone: String?, _ error: String?) -> Void) {
        guard let url = URL(string: "https://www.kimi.com/api/user") else {
            completion(nil, nil, "bad url"); return
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(webToken)", forHTTPHeaderField: "Authorization")
        req.setValue("mac", forHTTPHeaderField: "x-msh-platform")
        req.setValue("3.1.2", forHTTPHeaderField: "x-msh-version")
        req.setValue("KimiUsage-Menubar/1.0", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { data, resp, err in
            guard err == nil, let data = data,
                  let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let reason = (resp as? HTTPURLResponse).map { "HTTP \($0.statusCode)" }
                    ?? err?.localizedDescription ?? "bad response"
                completion(nil, nil, reason); return
            }
            let parsed = parseKimiAccountPayload(obj)
            completion(parsed.name, parsed.phone, nil)
        }.resume()
    }
}

// MARK: - 菜单栏堆叠两行文字渲染

enum StackImage {
    struct Line {
        let label: String
        let value: String
        let remaining: Int?
    }

    private static func attributed(_ line: Line, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(string: line.label + " ", attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ])
        result.append(NSAttributedString(string: line.value, attributes: [
            .font: font,
            .foregroundColor: RemainingColorTier(remaining: line.remaining).color()
        ]))
        return result
    }

    static func make(line1: Line, line2: Line, appearance: NSAppearance? = nil) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9.0, weight: .semibold)
        let s1 = attributed(line1, font: font)
        let s2 = attributed(line2, font: font)
        let w = max(ceil(s1.size().width), ceil(s2.size().width)) + 2
        let draw = {
            s1.draw(at: NSPoint(x: 1, y: 10.5))
            s2.draw(at: NSPoint(x: 1, y: 0.5))
        }
        let img = NSImage(size: NSSize(width: w, height: 21), flipped: false) { _ in
            // 正常时不钉死绘制外观，由系统按每条菜单栏各自解析动态颜色，兼容双屏不同底色。
            // 显式外观仅供离线像素测试使用，生产渲染始终跟随菜单栏自身外观。
            if let appearance = appearance {
                appearance.performAsCurrentDrawingAppearance(draw)
            } else {
                draw()
            }
            return true
        }
        img.isTemplate = false   // 保留百分比的柔彩色；动态色由系统按各屏菜单栏外观解析
        img.cacheMode = .never   // 小图直接重绘，避免菜单栏外观变化后复用旧颜色位图
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
    private static let resetDateTimeFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd EEE HH:mm"
        return f
    }()
    static func resetDateTime(_ d: Date?) -> String {
        guard let d = d else { return "" }
        return resetDateTimeFmt.string(from: d)
    }
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


// 从应用直接启动更新子进程，保留 TCC 的责任应用归属。
// nohup 与独立的临时脚本确保应用退出换包后，子进程仍能完成更新或回滚。
// 进度在下拉面板内原位展示（更新按钮变进度行），不再弹独立窗口、不抢占焦点：
// 任务与 UI 解耦，关闭面板不影响更新，重开面板时根据这里的状态恢复进度行；
// 失败另用 alert 兜底，因为那一刻面板可能已经关闭。
final class UpdateProgressController: NSObject {
    static let shared = UpdateProgressController()
    static let didChangeNotification = Notification.Name("KimiUsage.UpdateProgress.didChange")

    enum Phase: Equatable {
        case idle, preparing, downloading, verifying, staging, installing, finished, failed
    }

    private(set) var phase: Phase = .idle
    private(set) var fraction: Double = 0   // 仅 downloading 阶段有意义，0–100
    /// 进行中（含安装重启阶段）；失败/结束后恢复为可点击的更新按钮
    var isActive: Bool { [.preparing, .downloading, .verifying, .staging, .installing].contains(phase) }
    var statusLine: String {
        switch phase {
        case .idle: return ""
        case .preparing: return "正在准备更新…"
        case .downloading: return "正在下载更新… \(Int(fraction))%"
        case .verifying: return "正在校验更新…"
        case .staging: return "正在准备安装…"
        case .installing: return "正在安装并重启…"
        case .finished: return "更新完成，正在重启…"
        case .failed: return "更新失败"
        }
    }
    /// 安装阶段的重启预告：用户需要知道应用即将自己退出，不是异常消失
    var detailLine: String? {
        phase == .installing ? "应用将自动退出并重启，无需手动操作" : nil
    }

    private var timer: Timer?
    private var directory: URL?

    func start(script: String, targetTag: String, appPath: String) {
        guard !isActive else { return }   // 进度行已替换按钮，这里再兜底防重入
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usage-update-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            directory = dir
            let copiedScript = dir.appendingPathComponent("update.sh")
            try FileManager.default.copyItem(atPath: script, toPath: copiedScript.path)
            let wrapper = dir.appendingPathComponent("run.sh")
            let wrapperText = """
            #!/bin/bash
            cd "$1" || exit 1
            export UPDATE_PROGRESS_FILE="$1/progress"
            /bin/bash "$1/update.sh" "$2" "$3" > "$1/log" 2>&1
            result=$?
            printf '%s' "$result" > "$1/result"
            if [ "$result" -ne 0 ] && /usr/bin/grep -q '4/5' "$1/log"; then
                detail=$(/usr/bin/grep '!!' "$1/log" | /usr/bin/tail -1)
                /usr/bin/osascript - "${detail:-更新未完成，请查看日志。}" "$1/log" <<'APPLESCRIPT' >/dev/null 2>&1
            on run argv
                display dialog ((item 1 of argv) & return & return & "日志：" & (item 2 of argv)) with title "更新失败" buttons {"好"} default button 1 with icon caution
            end run
            APPLESCRIPT
            fi
            if [ "$result" -eq 0 ]; then /bin/sleep 5; /bin/rm -rf "$1"; fi
            exit "$result"
            """
            try wrapperText.write(to: wrapper, atomically: true, encoding: .utf8)
            phase = .preparing
            fraction = 0
            notify()
            let launch = Process()
            launch.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
            launch.arguments = ["/bin/bash", wrapper.path, dir.path, targetTag, appPath]
            launch.currentDirectoryURL = dir
            launch.standardInput = FileHandle.nullDevice
            launch.standardOutput = FileHandle.nullDevice; launch.standardError = FileHandle.nullDevice
            try launch.run()
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.refresh() }
        } catch {
            finishError("无法启动更新，请稍后重试。")
        }
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private func setPhase(_ newPhase: Phase, fraction newFraction: Double? = nil) {
        let changed = phase != newPhase || (newFraction.map { $0 != fraction } ?? false)
        phase = newPhase
        if let newFraction = newFraction { fraction = newFraction }
        if changed { notify() }
    }

    private func refresh() {
        guard let dir = directory else { return }
        let log = (try? String(contentsOf: dir.appendingPathComponent("log"), encoding: .utf8)) ?? ""
        if log.contains("4/5") || log.contains("5/5") { setPhase(.installing) }
        else if log.contains("3/5") { setPhase(.staging) }
        else if log.contains("2/5") { setPhase(.verifying) }
        else if log.contains("下载 v") {
            var value: Double?
            if let text = try? String(contentsOf: dir.appendingPathComponent("progress"), encoding: .utf8),
               let regex = try? NSRegularExpression(pattern: #"([0-9]+(?:\.[0-9]+)?)%"#),
               let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
               let range = Range(match.range(at: 1), in: text) {
                value = Double(text[range])
            }
            setPhase(.downloading, fraction: value)   // 百分比尚未写出时保留旧值
        }
        if let result = try? String(contentsOf: dir.appendingPathComponent("result"), encoding: .utf8) {
            if result != "0" {
                let detail = log.components(separatedBy: .newlines).last(where: { $0.contains("!!") }) ?? "更新未完成，请查看日志。"
                finishError(detail.replacingOccurrences(of: "!! ", with: ""))
            } else {
                // 正常路径下旧进程已被脚本替换重启，走不到这里；兜底停止轮询
                timer?.invalidate(); timer = nil
                setPhase(.finished)
            }
        }
    }

    private func finishError(_ detail: String) {
        timer?.invalidate(); timer = nil
        phase = .failed
        notify()   // 先恢复面板里的更新按钮，再模态弹窗
        let alert = NSAlert(); alert.messageText = "更新失败"; alert.informativeText = detail
        if let dir = directory { alert.informativeText += "\n\n日志：\(dir.appendingPathComponent("log").path)" }
        alert.addButton(withTitle: "好"); alert.runModal()
        directory = nil
    }

    /// 视觉预览专用：不启动子进程，仅呈现进行中的进度行。
    func simulateForPreview(phase previewPhase: Phase, fraction previewFraction: Double) {
        phase = previewPhase
        fraction = previewFraction
    }
}

/// 下拉面板内的更新进度行：原位替换「新版本可用」按钮。
/// 自身订阅进度通知刷新文本与进度条，避免每 0.25s 重建整个面板；
/// 面板关闭后重开，rebuildContent 会新建本行并同步到当前进度。
final class UpdateProgressRowView: NSView {
    private let status = PanelUI.label("", size: 12, weight: .semibold, wrapping: false)
    private let detail = PanelUI.label("", size: 10, color: .secondaryLabelColor)
    private let bar = NSProgressIndicator()
    private var observer: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        status.alignment = .left
        detail.alignment = .left
        bar.style = .bar
        bar.translatesAutoresizingMaskIntoConstraints = false
        let stack = PanelUI.stack(spacing: 6)
        PanelUI.addFullWidth(status, to: stack)
        PanelUI.addFullWidth(bar, to: stack)
        PanelUI.addFullWidth(detail, to: stack)
        addSubview(stack)
        PanelUI.pin(stack, to: self)
        observer = NotificationCenter.default.addObserver(
            forName: UpdateProgressController.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.sync() }
        sync()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func sync() {
        let controller = UpdateProgressController.shared
        status.stringValue = controller.statusLine
        detail.stringValue = controller.detailLine ?? ""
        detail.isHidden = controller.detailLine == nil
        if controller.phase == .downloading {
            if bar.isIndeterminate { bar.stopAnimation(nil) }
            bar.isIndeterminate = false
            bar.minValue = 0; bar.maxValue = 100
            bar.doubleValue = controller.fraction
        } else {
            if !bar.isIndeterminate { bar.isIndeterminate = true }
            bar.startAnimation(nil)
        }
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
    static let apiURL = URL(string: "https://api.github.com/repos/JUNX7764/kimi-usage-menubar/releases?per_page=20")!
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

    /// GitHub 按创建时间倒序返回 Release；空 Release 或附件上传不完整时跳过，
    /// 与 update.sh 选择同一个「最近可安装版本」，避免提示后下载 404。
    static func latestDownloadableTag(in releases: [[String: Any]]) -> String? {
        for release in releases {
            guard let tag = release["tag_name"] as? String, normalized(tag) != nil,
                  release["draft"] as? Bool != true, release["prerelease"] as? Bool != true
            else { continue }
            let assets = release["assets"] as? [[String: Any]] ?? []
            let names = Set(assets.compactMap { $0["name"] as? String })
            if names.contains("KimiUsage.zip") && names.contains("KimiUsage.zip.sha256") {
                return tag
            }
        }
        return nil
    }
}

/// 更新检查状态：低频匿名请求 GitHub，失败静默保留旧结论（不打扰主刷新，也不弹任何东西）。
/// 状态只在主线程读写（回调统一 dispatch 回主线程），无需加锁。
final class UpdateChecker {
    static let shared = UpdateChecker()
    private(set) var available = false
    private(set) var targetTag: String?
    private var etag: String?
    private var hasValidRelease = false
    private var lastCheck: Date?
    private var inFlight = false
    private var waiters: [() -> Void] = []
    private(set) var lastError = false
    typealias Transport = (URLRequest, @escaping (Data?, URLResponse?, Error?) -> Void) -> Void
    private let transport: Transport

    init(transport: @escaping Transport = { request, completion in
        URLSession.shared.dataTask(with: request, completionHandler: completion).resume()
    }) { self.transport = transport }

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
        transport(req) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.inFlight = false
                self.lastCheck = Date()
                let http = resp as? HTTPURLResponse
                let releases = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
                self.lastError = !(err == nil && ((http?.statusCode == 304 && self.hasValidRelease) ||
                    (http?.statusCode == 200 && releases != nil)))
                if http?.statusCode == 304 && !self.lastError {
                    // 内容未变：结论保持
                } else if err == nil, let data = data, http?.statusCode == 200,
                          let releases = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
                    self.hasValidRelease = true
                    if let tag = UpdateCheck.latestDownloadableTag(in: releases) {
                        self.available = UpdateCheck.isOutdated(local: BuildInfo.version, remote: tag)
                        self.targetTag = self.available ? tag : nil
                    } else {
                        self.available = false
                        self.targetTag = nil
                    }
                    if let e = http?.value(forHTTPHeaderField: "ETag"), !e.isEmpty { self.etag = e }
                }
                completion()
                let pending = self.waiters
                self.waiters.removeAll()
                pending.forEach { $0() }
            }
        }
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

    /// 动态颜色：不钉死绘制外观，由系统在每条菜单栏绘制时按该栏外观解析——
    /// 双屏两条栏底色不同（扩展屏全屏深色栏 + 主屏浅色栏）也能各自正确
    func color() -> NSColor {
        NSColor(name: nil) { appearance in self.color(for: appearance) }
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
    struct TokenModel {
        var name: String
        var total: String
        var input: String
        var output: String
    }
    struct TokenBucket {
        var summaryLabel: String
        var detailLabel: String
        var total: String
        var input: String
        var output: String
        var models: [TokenModel]
    }
    struct TokenSection {
        var title: String
        var accent: PanelAccent
        var buckets: [TokenBucket]
        var notices: [Notice]
    }
    enum ComparisonDirection { case up, down, flat }
    struct BriefDay {
        var label: String        // MM/DD
        var total: Double
        var input: Double
        var output: Double
        var covered: Bool        // false = 覆盖未证实：缺失占位，不补零
        var isToday: Bool
    }
    struct BriefComparison {
        var label: String        // 较昨日 / 较前 7 天
        var text: String         // +17.7% / −3.3% / 持平 / 新增 / 数据不足
        var direction: ComparisonDirection
        var detail: String       // 具体日期区间与公式（悬停 / VoiceOver）
    }
    struct BriefSection {
        var days: [BriefDay]
        var day: BriefComparison
        var week: BriefComparison
        var notices: [Notice]
    }
    struct ToolRow {
        var name: String
        var total: String
        var share: Double        // 0...1
        var shareText: String
        var status: String
        var detail: String       // 悬停 / VoiceOver：状态 · 输入 · 输出 · 占比
    }
    struct ToolsSection {
        var periods: [[ToolRow]] // [今日, 近 7 天, 近 30 天]
        var notices: [Notice]
    }

    var updateItem: NSMenuItem?
    var title: String
    var planName: String?        // 套餐名标签（缺失隐藏）
    var accountLine: String?     // 头部账号行（CodexUsage 同款布局：标题行下一行账号信息）
    var quotas: [Quota]
    var resetCards: ResetSection?
    var tibo: TiboSection?
    var usage: TokenSection      // 用量情况：合并本机全部来源，口径见 docs/DEVELOPMENT.md
    var brief: BriefSection      // 用量简析：近 30 天日图 + 较昨日/较前 7 天
    var tools: ToolsSection      // 工具明细：逐来源占比
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
        let titleRow = PanelUI.stack(orientation: .horizontal, alignment: .centerY, spacing: 8)
        let title = PanelUI.label(model.title, size: 15, weight: .semibold, wrapping: false)
        titleRow.addArrangedSubview(title)
        if let plan = model.planName, !plan.isEmpty {
            let tag = PlanTagView(text: plan)
            tag.toolTip = plan
            tag.setAccessibilityLabel("套餐 \(plan)")
            titleRow.addArrangedSubview(tag)
        }
        titleRow.addArrangedSubview(PanelUI.spacer())
        PanelUI.addFullWidth(titleRow, to: titles)
        if let accountLine = model.accountLine, !accountLine.isEmpty {
            let accountLabel = PanelUI.label(accountLine, size: 11, color: .secondaryLabelColor)
            PanelUI.addFullWidth(accountLabel, to: titles)
        }
        row.addArrangedSubview(titles)
        addSubview(row)
        PanelUI.pin(row, to: self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 套餐名标签：中性底色次要文字，过长截断、悬停可读全称。
final class PlanTagView: NSView {
    private let label: NSTextField
    init(text: String) {
        label = PanelUI.label(text, size: 11, color: .secondaryLabelColor, wrapping: false)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            widthAnchor.constraint(lessThanOrEqualToConstant: 150),
            heightAnchor.constraint(equalToConstant: 18)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
            self.layer?.cornerRadius = 5
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class QuotaProgressView: NSView {
    var remaining: Int? { didSet { needsLayout = true; needsDisplay = true } }
    private let fill = CALayer()

    init(remaining: Int?) {
        self.remaining = remaining
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 3
        layer?.masksToBounds = true
        fill.cornerRadius = 3
        layer?.addSublayer(fill)
        heightAnchor.constraint(equalToConstant: 6).isActive = true
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
        // 保留两位百分比时的对齐宽度；100% 按实际文字宽度扩展，避免百分号被截断。
        remaining.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        remaining.setContentHuggingPriority(.required, for: .horizontal)
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

final class UsagePanelController: NSObject, NSPopoverDelegate {
    var onClose: (() -> Void)?
    var onCheckUpdate: (() -> Void)?
    private var usageExpanded = true
    private var briefExpanded = true
    private var toolsExpanded = false
    private var toolPeriodIndex = 1   // 工具明细默认「7 天」（板块折叠状态独立于周期选择）
    private var briefSelectedIndex: Int?   // 用量简析选中日（重建保留；nil = 最新一日）
    private var expandedUsageBuckets: Set<Int> = []
    private var updateMessage: String?
    private var updateMessageDismissal: DispatchWorkItem?
    var previewWidth: CGFloat?
    var previewAppearance: NSAppearance? { didSet { contentController.view.appearance = previewAppearance } }
    var isOpen: Bool { popover.isShown }

    private let popover = NSPopover()
    private let contentController = NSViewController()
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
        super.init()
        contentController.view = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 320))
        configureContent()
        popover.contentViewController = contentController
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
    }

    deinit {
        if let localMonitor = localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor = globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    }

    private func configureContent() {
        let container = contentController.view
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
        // 更新进行中：原按钮位置换成进度行（重开面板也在此恢复）；空闲时才显示更新按钮
        if UpdateProgressController.shared.isActive {
            addContentRow(UpdateProgressRowView())
        } else if let update = model.updateItem {
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
        addContentRow(TokenSectionView(model: model.usage, expanded: usageExpanded,
            expandedBuckets: expandedUsageBuckets, target: self, action: #selector(toggleUsage),
            bucketAction: #selector(toggleUsageBucket(_:))))
        addContentRow(DailyBriefSectionView(model: model.brief, expanded: briefExpanded,
            selectedIndex: briefSelectedIndex, target: self, action: #selector(toggleBrief),
            onSelect: { [weak self] index in self?.briefSelectedIndex = index }))
        addContentRow(ToolBreakdownView(model: model.tools, periodIndex: toolPeriodIndex, expanded: toolsExpanded,
            target: self, periodAction: #selector(toggleToolPeriod(_:)), toggleAction: #selector(toggleTools)))
        for notice in PanelUI.notices(model.notices) { addContentRow(notice) }
        stack.needsLayout = true
    }

    private func refreshPanelLayout() {
        let previousOrigin = scrollView.contentView.bounds.origin
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rebuildContent()
        if let button = anchorButton, let window = button.window {
            layoutPanel(buttonWindow: window)
            let clip = scrollView.contentView
            let desired = NSRect(origin: previousOrigin, size: clip.bounds.size)
            clip.scroll(to: clip.constrainBoundsRect(desired).origin)
            scrollView.reflectScrolledClipView(clip)
        }
        CATransaction.commit()
    }
    @objc private func toggleUsage() { usageExpanded.toggle(); refreshPanelLayout() }
    @objc private func toggleBrief() { briefExpanded.toggle(); refreshPanelLayout() }
    @objc private func toggleTools() { toolsExpanded.toggle(); refreshPanelLayout() }
    @objc private func toggleToolPeriod(_ sender: NSButton) {
        guard sender.tag != toolPeriodIndex else { return }
        toolPeriodIndex = sender.tag
        refreshPanelLayout()
    }
    @objc private func toggleUsageBucket(_ sender: NSButton) {
        if expandedUsageBuckets.contains(sender.tag) { expandedUsageBuckets.remove(sender.tag) }
        else { expandedUsageBuckets.insert(sender.tag) }
        refreshPanelLayout()
    }
    @objc fileprivate func requestUpdateCheck() { onCheckUpdate?() }
    // 版本点击等临时状态行；dismissAfter 到点后自动清除（与 CodexUsage 一致）
    func setUpdateMessage(_ message: String?, dismissAfter: TimeInterval? = nil) {
        updateMessageDismissal?.cancel()
        updateMessageDismissal = nil
        updateMessage = message
        refreshPanelLayout()
        if message != nil, let delay = dismissAfter {
            let dismissal = DispatchWorkItem { [weak self] in self?.setUpdateMessage(nil) }
            updateMessageDismissal = dismissal
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: dismissal)
        }
    }

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
        button.keyEquivalentModifierMask = item.keyEquivalentModifierMask
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
        // 只有「退出」先收起面板；刷新/开机自启等保持面板打开，动作结果就地可见
        if action == #selector(AppDelegate.onQuit) { close() }
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
        guard isOpen, usageExpanded, briefExpanded else { return false }
        if expectScroll {
            guard scrollToEndForPreview(), let model = model else { return false }
            let oldOrigin = scrollView.contentView.bounds.origin
            guard abs(oldOrigin.y) > 1 else { return false }
            update(model: model)
            let refreshedOrigin = scrollView.contentView.bounds.origin
            guard isOpen, abs(refreshedOrigin.y - oldOrigin.y) < 1 else { return false }
            let sender = NSButton(); sender.tag = 0
            toggleUsageBucket(sender)
            let expandedOrigin = scrollView.contentView.bounds.origin
            let expected = scrollView.contentView.constrainBoundsRect(NSRect(origin: oldOrigin, size: scrollView.contentView.bounds.size)).origin
            guard isOpen, abs(expandedOrigin.y - expected.y) < 1 else { return false }
            toggleUsageBucket(sender)
            let collapsedOrigin = scrollView.contentView.bounds.origin
            let collapsedExpected = scrollView.contentView.constrainBoundsRect(NSRect(origin: expandedOrigin, size: scrollView.contentView.bounds.size)).origin
            guard isOpen, abs(collapsedOrigin.y - collapsedExpected.y) < 1 else { return false }
            print("KimiUsage nonzero scroll: before=\(oldOrigin.y) refresh=\(refreshedOrigin.y) expand=\(expandedOrigin.y) collapse=\(collapsedOrigin.y)")
        }
        guard let model = model else { return false }
        let expectedErrors = model.usage.notices
            .map { $0.text }.filter { $0.contains("统计失败") }
        let requiresErrors = CommandLine.arguments.contains("--visual-preview-states") || CommandLine.arguments.contains("--visual-preview-long")
        guard !requiresErrors || expectedErrors.count == 1 else {
            fputs("KimiUsage visual test: expected one fixture usage error, got \(expectedErrors.count)\n", stderr); return false
        }
        func verifyErrors(_ stage: String) -> Bool {
            let actual = labels(stack).filter { $0.contains("统计失败") }
            guard actual.sorted() == expectedErrors.sorted() else {
                fputs("KimiUsage visual test: \(stage) notices expected=\(expectedErrors), actual=\(actual)\n", stderr); return false
            }
            return true
        }
        guard verifyErrors("initial") else { return false }
        toggleUsage()
        guard !usageExpanded, briefExpanded, verifyErrors("first collapse") else {
            fputs("KimiUsage visual test: first collapse state or notices\n", stderr); return false
        }
        toggleBrief()
        guard !usageExpanded, !briefExpanded, verifyErrors("second collapse") else {
            fputs("KimiUsage visual test: second collapse state or notices\n", stderr); return false
        }
        toggleUsage()
        guard usageExpanded, !briefExpanded else {
            fputs("KimiUsage visual test: first expansion state\n", stderr); return false
        }
        toggleBrief()
        guard usageExpanded, briefExpanded, verifyErrors("re-expanded") else {
            fputs("KimiUsage visual test: second expansion state or notices\n", stderr); return false
        }
        guard verifyTokenBucketInteractionsForPreview() else {
            fputs("KimiUsage visual test: model bucket interactions or alignment\n", stderr); return false
        }
        return true
    }

    func expandAllTokenBucketsForPreview() {
        expandedUsageBuckets = [0, 1, 2]
        refreshPanelLayout()
    }

    /// 视觉预览：展开工具明细（默认折叠，单独开关验证行布局）
    func expandToolsForPreview() {
        toolsExpanded = true
        refreshPanelLayout()
    }

    /// 逐一点击两个板块的三个周期行，核对明细数量、列坐标和刷新后的展开状态。
    func verifyTokenBucketInteractionsForPreview() -> Bool {
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { descendants($0) }
        }
        func rows(_ action: Selector) -> [TokenBucketRow] {
            descendants(stack).compactMap { $0 as? TokenBucketRow }
                .filter { $0.action == action }.sorted { $0.tag < $1.tag }
        }
        func details() -> [TokenDetailRow] {
            descendants(stack).compactMap { $0 as? TokenDetailRow }.filter { $0.isModelDetail }
        }
        func detailCount() -> Int { details().count }
        func numericColumnsAligned() -> Bool {
            contentController.view.layoutSubtreeIfNeeded()
            stack.layoutSubtreeIfNeeded()
            let summary = rows(#selector(toggleUsageBucket(_:)))[0].cells
            guard let detail = details().first else { return false }
            for index in 1..<4 {
                let summaryLabel = summary.columnLabels[index]
                let detailLabel = detail.columnLabels[index]
                let summaryFrame = summaryLabel.convert(summaryLabel.bounds, to: stack)
                let detailFrame = detailLabel.convert(detailLabel.bounds, to: stack)
                guard abs(summaryFrame.minX - detailFrame.minX) < 0.5,
                      abs(summaryFrame.width - detailFrame.width) < 0.5 else { return false }
            }
            return true
        }
        guard rows(#selector(toggleUsageBucket(_:))).count == 3,
              rows(#selector(toggleUsageBucket(_:))).allSatisfy({ $0.verifyHoverForPreview() }),
              detailCount() == 0 else { return false }
        for (index, expected) in [(0, 2), (1, 4), (2, 6)] {
            rows(#selector(toggleUsageBucket(_:)))[index].performClick(nil)
            guard detailCount() == expected else { return false }
            if index == 0, !numericColumnsAligned() { return false }
        }
        rows(#selector(toggleUsageBucket(_:)))[1].performClick(nil)
        guard detailCount() == 4, let model = model else { return false }
        update(model: model)
        return expandedUsageBuckets == [0, 2] && detailCount() == 4
    }

    // Runs against one real popover after AppKit has settled the initial presentation.
    func runPopoverResizeTest(outputDirectory: String) {
        func fail(_ message: String) { fputs("KimiUsage popover test: FAIL: \(message)\n", stderr); exit(1) }
        func row() -> TokenBucketRow? {
            func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { all($0) } }
            return all(stack).compactMap { $0 as? TokenBucketRow }
                .first { $0.action == #selector(toggleUsageBucket(_:)) && $0.tag == 0 }
        }
        toggleBrief()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard self.isOpen, let window = self.contentController.view.window,
                  let button = self.anchorButton, let buttonWindow = button.window,
                  let document = self.scrollView.documentView, let first = row() else { return fail("initial state") }
            let initial = window.frame
            let controller = self.popover.contentViewController
            let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            func stable(_ frame: NSRect) -> Bool {
                self.isOpen && self.contentController.view.window === window &&
                    self.popover.contentViewController === controller && self.scrollView.documentView === document &&
                    abs(frame.maxY - initial.maxY) < 2 &&
                    (window.screen?.frame.contains(frame) ?? true)
            }
            guard self.savePreviewImage(to: outputDirectory + "/before.png") else { return fail("before screenshot") }
            first.performClick(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let expanded = window.frame
                guard stable(expanded), expanded.height > initial.height + 1 else {
                    return fail("expand \(initial) -> \(expanded); shown=\(self.isOpen) sameWindow=\(self.contentController.view.window === window) sameController=\(self.popover.contentViewController === controller) sameDocument=\(self.scrollView.documentView === document) screen=\(String(describing: window.screen?.frame))")
                }
                guard self.savePreviewImage(to: outputDirectory + "/expanded.png"), let next = row() else { return fail("expanded screenshot or row") }
                next.performClick(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    let collapsed = window.frame
                    guard stable(collapsed), collapsed.height < expanded.height - 1 else { return fail("collapse \(expanded) -> \(collapsed)") }
                    guard self.savePreviewImage(to: outputDirectory + "/collapsed.png") else { return fail("collapsed screenshot") }
                    print("KimiUsage popover test: PASS heights=\(initial.height),\(expanded.height),\(collapsed.height) maxY=\(initial.maxY),\(expanded.maxY),\(collapsed.maxY) anchor=\(anchor)")
                    exit(0)
                }
            }
        }
    }

    /// 视觉回归专用：真实滚动到底部并确认 clip view 位置发生变化。
    func scrollToEndForPreview() -> Bool {
        contentController.view.layoutSubtreeIfNeeded()
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

    /// 捕捉完整系统窗口，包括原生箭头和阴影。
    func savePreviewImage(to path: String) -> Bool {
        guard let window = contentController.view.window,
              let image = CGWindowListCreateImage(.null, .optionIncludingWindow,
                  CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else { return false }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }

    func toggle(anchoredTo button: NSStatusBarButton) {
        if isOpen { close() } else { show(anchoredTo: button) }
    }

    private func show(anchoredTo button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        anchorButton = button
        layoutPanel(buttonWindow: buttonWindow)
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        solid.opacity = reduceTransparency ? 1 : 0.9
        effect.isHidden = reduceTransparency
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if isOpen { installMonitors() }
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func layoutPanel(buttonWindow: NSWindow) {
        let screen = buttonWindow.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let desiredWidth = min(previewWidth ?? Self.maximumWidth, visible.width - 24)
        if desiredWidth != panelWidth {
            panelWidth = desiredWidth
            rebuildContent()
        }
        contentController.view.layoutSubtreeIfNeeded()
        stack.layoutSubtreeIfNeeded()
        let chromeHeight = headerContainer.fittingSize.height + footerContainer.fittingSize.height
        let fittingHeight = max(chromeHeight + stack.fittingSize.height, 240)
        let maximumHeight = max(240, visible.height * 0.85)
        let desiredSize = NSSize(width: panelWidth, height: min(fittingHeight, maximumHeight))
        contentController.preferredContentSize = desiredSize
        popover.contentSize = desiredSize
        contentController.view.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        stack.layoutSubtreeIfNeeded()
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
            if event.window === self.contentController.view.window || event.window === self.anchorButton?.window { return event }
            self.close()
            return event
        }
    }

    private func removeMonitors() {
        if let monitor = localMonitor { NSEvent.removeMonitor(monitor); localMonitor = nil }
        if let monitor = globalMonitor { NSEvent.removeMonitor(monitor); globalMonitor = nil }
    }

    func close() { popover.performClose(nil) }

    func popoverDidClose(_ notification: Notification) {
        removeMonitors()
        anchorButton = nil
        onClose?()
    }
}

private final class TokenDetailRow: NSView {
    let isModelDetail: Bool
    private(set) var columnLabels: [NSTextField] = []

    init(values: [String], header: Bool, accent: PanelAccent, modelDetail: Bool = false) {
        isModelDetail = modelDetail
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let row = PanelUI.stack(orientation: .horizontal, alignment: .centerY, spacing: 4)
        row.distribution = .fillEqually
        for (index, value) in values.enumerated() {
            let size: CGFloat = header ? 10 : (modelDetail ? (index == 0 ? 9 : 10) : 11)
            let label = PanelUI.label(value, size: size,
                weight: header || modelDetail ? .regular : (index == 0 ? .regular : .semibold),
                color: header || modelDetail ? .secondaryLabelColor : (index == 1 ? accent.color : .labelColor),
                wrapping: false, monospacedDigits: !header && index > 0)
            label.alignment = index == 0 ? .left : .right
            if modelDetail && index == 0 {
                label.maximumNumberOfLines = 1
                label.lineBreakMode = .byTruncatingMiddle
                label.toolTip = value
            }
            row.addArrangedSubview(label)
            columnLabels.append(label)
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

private final class TokenBucketRow: NSButton {
    let cells: TokenDetailRow
    private var hovered = false { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { true }

    init(bucket: UsagePanelModel.TokenBucket, accent: PanelAccent, expanded: Bool,
         tag: Int, target: AnyObject, action: Selector) {
        cells = TokenDetailRow(values: [bucket.summaryLabel, bucket.total, bucket.input, bucket.output],
            header: false, accent: accent)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        title = ""
        isBordered = false
        isEnabled = !bucket.models.isEmpty
        wantsLayer = true
        layer?.cornerRadius = 5
        self.tag = tag
        self.target = target
        self.action = action
        addSubview(cells)
        NSLayoutConstraint.activate([
            cells.topAnchor.constraint(equalTo: topAnchor),
            cells.leadingAnchor.constraint(equalTo: leadingAnchor),
            cells.trailingAnchor.constraint(equalTo: trailingAnchor),
            cells.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        let summary = "\(bucket.detailLabel)，总量 \(bucket.total)，输入 \(bucket.input)，输出 \(bucket.output)"
        toolTip = bucket.models.isEmpty ? "暂无模型明细" : (expanded ? "收起模型明细" : "展开模型明细")
        setAccessibilityLabel(summary + (bucket.models.isEmpty ? "，无模型明细" : "，\(expanded ? "收起" : "展开")模型明细"))
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(hovered && isEnabled ? 0.08 : 0).cgColor
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

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEnabled, let parent = superview else { return super.hitTest(point) }
        return bounds.contains(convert(point, from: parent)) ? self : nil
    }

    func verifyHoverForPreview() -> Bool {
        updateTrackingAreas()
        hovered = true; updateLayer()
        let highlighted = layer?.backgroundColor?.alpha ?? 0
        hovered = false; updateLayer()
        let cleared = layer?.backgroundColor?.alpha ?? 0
        return highlighted > 0 && cleared == 0 && !trackingAreas.isEmpty
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class TokenSectionView: NSView {
    init(model: UsagePanelModel.TokenSection, expanded: Bool, expandedBuckets: Set<Int>,
         target: AnyObject, action: Selector, bucketAction: Selector) {
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
            for (index, bucket) in model.buckets.enumerated() {
                let row = TokenBucketRow(bucket: bucket, accent: model.accent,
                    expanded: expandedBuckets.contains(index), tag: index, target: target, action: bucketAction)
                PanelUI.addFullWidth(row, to: root)
                if expandedBuckets.contains(index) {
                    for (modelIndex, tokenModel) in bucket.models.enumerated() {
                        let detail = TokenDetailRow(values: [tokenModel.name, tokenModel.total,
                            tokenModel.input, tokenModel.output], header: false,
                            accent: model.accent, modelDetail: true)
                        PanelUI.addFullWidth(detail, to: root)
                        if modelIndex == bucket.models.count - 1 { root.setCustomSpacing(8, after: detail) }
                    }
                }
            }
        }
        for notice in PanelUI.notices(model.notices) { PanelUI.addFullWidth(notice, to: root) }
        addSubview(root)
        PanelUI.pin(root, to: self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 用量简析的近 30 天柱状图：整列命中、图内浮层即时读值、今日未结束描边、缺失占位不补零。
/// 柱条在 draw(_:) 内一次性绘制（避免逐列 layer 帧与布局时序竞争）；列视图只做命中/焦点/VoiceOver。
/// 用量简析每日柱状图画布：逻辑整体移植 GLMUsage GLMDailyChartCanvas（颜色为 Kimi 深蓝）。
/// 选中制交互：悬停/点击/左右方向键切换，鼠标离开保留最后选中；缺失日缺口不画、不当 0；
/// 命中覆盖整天宽度；面板重建经 configure(initialIndex:) 保留选择。
final class DailyBarChartCanvas: NSView {
    private var days: [UsagePanelModel.BriefDay] = []
    private(set) var selectedIndex = 0
    /// 选中变化回调（含悬停/点击/键盘）；上层记录状态用于面板重建，不触发刷新
    var onSelect: ((Int) -> Void)?
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill() }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { noteFocusRingMaskChanged() }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { noteFocusRingMaskChanged() }
        return accepted
    }

    var dayList: [UsagePanelModel.BriefDay] { days }

    func configure(days: [UsagePanelModel.BriefDay], initialIndex: Int) {
        self.days = days
        selectedIndex = clamped(initialIndex)
        needsDisplay = true
        updateAccessibilityValue()
    }

    private func clamped(_ index: Int) -> Int {
        guard !days.isEmpty else { return 0 }
        return max(0, min(days.count - 1, index))
    }

    private var columnWidth: CGFloat { bounds.width / CGFloat(max(1, days.count)) }

    private func dayIndex(atX x: CGFloat) -> Int { clamped(Int(x / max(1, columnWidth))) }

    private func select(_ index: Int) {
        let next = clamped(index)
        guard next != selectedIndex else { return }
        selectedIndex = next
        needsDisplay = true
        updateAccessibilityValue()
        onSelect?(next)
    }

    override func draw(_ dirtyRect: NSRect) {
        // 基线：1pt 全宽发丝线（GLM 同款）
        NSColor.labelColor.withAlphaComponent(0.15).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        guard !days.isEmpty else { return }
        let peak = max(days.map { $0.total }.max() ?? 0, 1)
        let chartHeight = bounds.height - 3
        let width = min(6, columnWidth)
        let inset = (columnWidth - width) / 2
        for (index, day) in days.enumerated() {
            guard day.covered else { continue }   // 缺失日 = 缺口，不画、不当 0
            let x = CGFloat(index) * columnWidth + inset
            PanelAccent.codex.color.withAlphaComponent(index == selectedIndex ? 1 : 0.4).setFill()
            if day.total == 0 {
                NSRect(x: x, y: 1, width: width, height: 2).fill()   // 有记录的零日 = 基线短柱
            } else {
                let height = max(3, chartHeight * CGFloat(min(1, day.total / peak)))
                NSRect(x: x, y: 1, width: width, height: min(chartHeight, height)).fill()
            }
        }
    }

    override func updateTrackingAreas() { installTrackingArea() }
    // 面板重建、Popover 关开切换：不依赖 AppKit 时机，入窗/布局时主动重挂
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installTrackingArea()
    }
    override func layout() {
        super.layout()
        installTrackingArea()
    }
    private func installTrackingArea() {
        if let old = trackingArea { removeTrackingArea(old); trackingArea = nil }
        guard window != nil else { return }
        let area = NSTrackingArea(rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        select(dayIndex(atX: convert(event.locationInWindow, from: nil).x))
    }
    override func mouseDown(with event: NSEvent) {
        select(dayIndex(atX: convert(event.locationInWindow, from: nil).x))
        window?.makeFirstResponder(self)   // 点击后即可用方向键继续切换
    }
    // 鼠标离开图表：保留最后选中值，不跳回末日
    override func mouseExited(with event: NSEvent) {}
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: select(selectedIndex - 1)   // ←
        case 124: select(selectedIndex + 1)   // →
        default: super.keyDown(with: event)
        }
    }

    private func updateAccessibilityValue() {
        guard days.indices.contains(selectedIndex) else { setAccessibilityValue(""); return }
        let day = days[selectedIndex]
        let value = day.covered ? "\(Fmt.tokens(day.total)) tokens" : "数据不足"
        setAccessibilityValue("\(selectionDateText(day)) \(value)")
    }

    private func selectionDateText(_ day: UsagePanelModel.BriefDay) -> String {
        let parts = day.label.split(separator: "/")
        guard parts.count == 2 else { return day.label }
        let base = "\(Int(parts[0]) ?? 0)月\(Int(parts[1]) ?? 0)日"
        return day.isToday ? base + "（今日未结束）" : base
    }
}

/// 用量简析板块：chart.bar.fill 深蓝图标、独立折叠默认展开、无主数值；
/// 每日图区逻辑移植 GLMUsage——选中行（日期左/数值右）→ 62pt 画布 → 首/中/末三刻度 → 比较条。
private final class DailyBriefSectionView: NSView {
    private let dateLabel: NSTextField
    private let valueLabel: NSTextField
    private let canvas = DailyBarChartCanvas()

    init(model: UsagePanelModel.BriefSection, expanded: Bool, selectedIndex: Int?,
         target: AnyObject, action: Selector, onSelect: @escaping (Int) -> Void) {
        dateLabel = PanelUI.label("", size: 11, color: .secondaryLabelColor, wrapping: false)
        valueLabel = PanelUI.label("", size: 11, weight: .semibold, wrapping: false)
        valueLabel.identifier = NSUserInterfaceItemIdentifier("kimi-brief-value")
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let root = PanelUI.stack(spacing: 6)
        let header = PanelUI.stack(orientation: .horizontal, alignment: .centerY, spacing: 6)
        header.addArrangedSubview(PanelUI.symbol("chart.bar.fill", size: 14, color: PanelAccent.codex.color))
        header.addArrangedSubview(PanelUI.label("用量简析", size: 12, weight: .semibold, wrapping: false))
        header.addArrangedSubview(PanelUI.spacer())
        let toggle = NSButton(image: NSImage(systemSymbolName: expanded ? "chevron.up" : "chevron.down",
            accessibilityDescription: expanded ? "折叠用量简析" : "展开用量简析")!,
            target: target, action: action)
        toggle.isBordered = false
        toggle.contentTintColor = .secondaryLabelColor
        toggle.toolTip = expanded ? "折叠" : "展开"
        toggle.setAccessibilityLabel(expanded ? "折叠用量简析" : "展开用量简析")
        toggle.widthAnchor.constraint(equalToConstant: 24).isActive = true
        toggle.heightAnchor.constraint(equalToConstant: 22).isActive = true
        header.addArrangedSubview(toggle)
        PanelUI.addFullWidth(header, to: root)

        if expanded {
            // 选中行：日期左 / 数值右；canvas 选中变化时原地更新，不重建面板（GLM 同款）
            let selectionRow = PanelUI.stack(orientation: .horizontal, alignment: .centerY, spacing: 6)
            selectionRow.addArrangedSubview(dateLabel)
            selectionRow.addArrangedSubview(PanelUI.spacer())
            valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            selectionRow.addArrangedSubview(valueLabel)
            PanelUI.addFullWidth(selectionRow, to: root)
            root.setCustomSpacing(2, after: selectionRow)

            if model.days.isEmpty {
                dateLabel.stringValue = "暂不可用"
                valueLabel.stringValue = ""
                canvas.isHidden = true
            } else {
                canvas.configure(days: model.days, initialIndex: selectedIndex ?? model.days.count - 1)
                canvas.focusRingType = .default
                canvas.onSelect = { [weak self] index in
                    self?.syncSelection(index)
                    onSelect(index)
                }
                canvas.setAccessibilityLabel("近 30 天每日用量柱状图，可用左右方向键选择日期")
                // 有意不设 setAccessibilityElement(true)：避免 Full Keyboard Access 的 Tab 遍历
                // 跳过本视图；VoiceOver 用户经选中行两个文本标签获取选中日信息（GLM 实测结论）
                canvas.heightAnchor.constraint(equalToConstant: 62).isActive = true
                PanelUI.addFullWidth(canvas, to: root)
            }

            // 日期刻度：首/中/末（与柱图两端对齐，GLM 同款）
            let ticks = PanelUI.stack(orientation: .horizontal, spacing: 0)
            ticks.distribution = .fillEqually
            if let first = model.days.first, let mid = model.days.indices.contains(model.days.count / 2) ? model.days[model.days.count / 2] : nil, let last = model.days.last {
                for (tick, alignment) in [(first.label, NSTextAlignment.left),
                                          (mid.label, NSTextAlignment.center),
                                          (last.label, NSTextAlignment.right)] {
                    let label = PanelUI.label(tick, size: 10, color: .secondaryLabelColor,
                        wrapping: false, monospacedDigits: true)
                    label.alignment = alignment
                    ticks.addArrangedSubview(label)
                }
            }
            PanelUI.addFullWidth(ticks, to: root)
            root.setCustomSpacing(6, after: ticks)

            PanelUI.addFullWidth(ComparisonRowView(day: model.day, week: model.week), to: root)
            for notice in PanelUI.notices(model.notices) { PanelUI.addFullWidth(notice, to: root) }
            if !model.days.isEmpty { syncSelection(canvas.selectedIndex) }
        }
        addSubview(root)
        PanelUI.pin(root, to: self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 由 canvas 在选中变化时调用（含键盘/悬停）；直接改本块标签，不重建面板、不发请求
    private func syncSelection(_ index: Int) {
        guard days(indices: index) else { return }
        let day = canvas.dayList[index]
        dateLabel.stringValue = {
            let parts = day.label.split(separator: "/")
            let base = parts.count == 2 ? "\(Int(parts[0]) ?? 0)月\(Int(parts[1]) ?? 0)日" : day.label
            return day.isToday ? base + "（今日未结束）" : base
        }()
        if day.covered {
            valueLabel.stringValue = "\(Fmt.tokens(day.total)) Token"
            valueLabel.textColor = .labelColor
        } else {
            valueLabel.stringValue = "数据不足"
            valueLabel.textColor = .secondaryLabelColor
        }
    }
    private func days(indices index: Int) -> Bool { canvas.dayList.indices.contains(index) }
}

/// 固定对比条：架构对齐 GLMUsage GLMComparisonStrip——30pt 圆角条、两项均分、中缝竖线、
/// 非数值（持平/数据不足）弱化色；数值色沿用 Kimi 语义（增深蓝 / 减绿）。
private final class ComparisonRowView: NSView {
    init(day: UsagePanelModel.BriefComparison, week: UsagePanelModel.BriefComparison) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 7
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        let row = PanelUI.stack(orientation: .horizontal, alignment: .centerY, spacing: 0)
        row.distribution = .fillEqually
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.heightAnchor.constraint(equalToConstant: 30),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        ])
        let items = [(day, "今日（未结束）与前一日比较"), (week, "最近 7 日（含今日）与此前 7 日比较")]
        for (index, item) in items.enumerated() {
            if index > 0 {
                // GLM 同款：裸 NSBox 分隔线（PanelUI.separator 自带 height=1 会与 16pt 约束冲突塌陷）
                let divider = NSBox()
                divider.boxType = .separator
                divider.translatesAutoresizingMaskIntoConstraints = false
                row.addArrangedSubview(divider)
                divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
                divider.heightAnchor.constraint(equalToConstant: 16).isActive = true
            }
            let half = NSView()
            half.translatesAutoresizingMaskIntoConstraints = false
            half.toolTip = "\(item.1) · \(item.0.detail)"
            half.setAccessibilityLabel("\(item.0.label) \(item.0.text)，\(item.0.detail)")
            let content = PanelUI.stack(orientation: .horizontal, alignment: .centerY, spacing: 5)
            content.translatesAutoresizingMaskIntoConstraints = false
            let caption = PanelUI.label(item.0.label, size: 10, color: .secondaryLabelColor, wrapping: false)
            let valueColor = NSColor(name: nil) { appearance in
                switch item.0.direction {
                case .up: return PanelAccent.codex.color
                case .down: return RemainingColorTier.green.color(for: appearance)
                case .flat: return .secondaryLabelColor
                }
            }
            let value = PanelUI.label(item.0.text, size: 11, weight: .semibold, color: valueColor,
                wrapping: false, monospacedDigits: true)
            value.setContentHuggingPriority(.required, for: .horizontal)
            value.setContentCompressionResistancePriority(.required, for: .horizontal)
            content.addArrangedSubview(caption)
            content.addArrangedSubview(value)
            half.addSubview(content)
            NSLayoutConstraint.activate([
                content.centerXAnchor.constraint(equalTo: half.centerXAnchor),
                content.centerYAnchor.constraint(equalTo: half.centerYAnchor)
            ])
            row.addArrangedSubview(half)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.055).cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// 工具明细：list.bullet 深蓝图标、默认折叠、标题行内深蓝周期按钮、行=名称+占比条+总量。
private final class ToolBreakdownView: NSView {
    init(model: UsagePanelModel.ToolsSection, periodIndex: Int, expanded: Bool,
         target: AnyObject, periodAction: Selector, toggleAction: Selector) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let root = PanelUI.stack(spacing: 5)
        let header = PanelUI.stack(orientation: .horizontal, alignment: .centerY, spacing: 6)
        header.addArrangedSubview(PanelUI.symbol("list.bullet", size: 14, color: PanelAccent.codex.color))
        header.addArrangedSubview(PanelUI.label("工具明细", size: 12, weight: .semibold, wrapping: false))
        header.addArrangedSubview(PanelUI.spacer())
        let periodNames = ["今日", "7 天", "30 天"]
        let periods = PanelUI.stack(orientation: .horizontal, alignment: .centerY, spacing: 2)
        for (index, name) in periodNames.enumerated() {
            let button = ToolPeriodButton(title: name)
            button.tag = index
            button.selected = index == periodIndex
            button.target = target
            button.action = periodAction
            button.setAccessibilityLabel("工具明细周期：\(name)")
            periods.addArrangedSubview(button)
        }
        header.addArrangedSubview(periods)
        let toggle = NSButton(image: NSImage(systemSymbolName: expanded ? "chevron.up" : "chevron.down",
            accessibilityDescription: expanded ? "折叠工具明细" : "展开工具明细")!,
            target: target, action: toggleAction)
        toggle.isBordered = false
        toggle.contentTintColor = .secondaryLabelColor
        toggle.toolTip = expanded ? "折叠" : "展开"
        toggle.setAccessibilityLabel(expanded ? "折叠工具明细" : "展开工具明细")
        toggle.widthAnchor.constraint(equalToConstant: 24).isActive = true
        toggle.heightAnchor.constraint(equalToConstant: 22).isActive = true
        header.addArrangedSubview(toggle)
        PanelUI.addFullWidth(header, to: root)
        if expanded {
            let rows = model.periods.indices.contains(periodIndex) ? model.periods[periodIndex] : []
            if rows.isEmpty {
                PanelUI.addFullWidth(PanelUI.label("本周期暂无用量", size: 11, color: .secondaryLabelColor), to: root)
            }
            for (index, row) in rows.enumerated() {
                let view = ToolRowView(row: row)
                PanelUI.addFullWidth(view, to: root)
                if index == rows.count - 1 { root.setCustomSpacing(4, after: view) }
            }
            for notice in PanelUI.notices(model.notices) { PanelUI.addFullWidth(notice, to: root) }
        }
        addSubview(root)
        PanelUI.pin(root, to: self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 紧凑周期按钮：选中深蓝实底白字，未选中浅蓝底蓝字（Codex 同款语义、Kimi 深蓝）。
private final class ToolPeriodButton: NSButton {
    var selected = false { didSet { refreshStyle() } }

    init(title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 5
        font = .systemFont(ofSize: 10, weight: .medium)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.labelColor])
        heightAnchor.constraint(equalToConstant: 18).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func refreshStyle() {
        let title = attributedTitle.string
        let isSelected = selected
        let textColor = NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if isSelected {
                return dark ? NSColor(red: 0.06, green: 0.11, blue: 0.19, alpha: 1) : .white
            }
            return PanelAccent.codex.color
        }
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: textColor])
        layer?.backgroundColor = (isSelected
            ? PanelAccent.codex.color
            : PanelAccent.codex.color.withAlphaComponent(0.14)).cgColor
        needsDisplay = true
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshStyle()
    }
}

/// 细占比条：分母为同周期同一快照的合并总量。
private final class ShareBarView: NSView {
    private let fill = CALayer()
    var ratio: CGFloat = 0 { didSet { needsLayout = true } }

    init(ratio: CGFloat) {
        self.ratio = ratio
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 3
        layer?.masksToBounds = true
        layer?.addSublayer(fill)
        heightAnchor.constraint(equalToConstant: 6).isActive = true
        widthAnchor.constraint(equalToConstant: 84).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
            self.fill.backgroundColor = PanelAccent.codex.color.withAlphaComponent(0.8).cgColor
        }
    }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = NSRect(x: 0, y: 0, width: bounds.width * max(0, min(1, ratio)), height: bounds.height)
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// 工具行：名称 + 占比条 + 总量；固定列宽保证跨行对齐（占比条 84 ｜ % 34 ｜ 总量 64）。
/// 状态/输入/输出/占比入悬停与 VoiceOver（v0.4 规格）。
private final class ToolRowView: NSView {
    init(row: UsagePanelModel.ToolRow) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let main = PanelUI.stack(orientation: .horizontal, alignment: .centerY, spacing: 8)
        let name = PanelUI.label(row.name, size: 11, weight: .medium, wrapping: false)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        main.addArrangedSubview(name)
        main.addArrangedSubview(PanelUI.spacer())
        let bar = ShareBarView(ratio: CGFloat(row.share))
        main.addArrangedSubview(bar)
        let shareLabel = PanelUI.label(row.shareText, size: 10, color: .secondaryLabelColor,
            wrapping: false, monospacedDigits: true)
        shareLabel.alignment = .right
        shareLabel.setContentHuggingPriority(.required, for: .horizontal)
        shareLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        shareLabel.widthAnchor.constraint(equalToConstant: 34).isActive = true
        main.addArrangedSubview(shareLabel)
        let total = PanelUI.label(row.total, size: 11, weight: .semibold, wrapping: false, monospacedDigits: true)
        total.alignment = .right
        total.setContentHuggingPriority(.required, for: .horizontal)
        total.setContentCompressionResistancePriority(.required, for: .horizontal)
        total.widthAnchor.constraint(equalToConstant: 64).isActive = true
        main.addArrangedSubview(total)
        addSubview(main)
        PanelUI.pin(main, to: self)
        toolTip = row.detail
        setAccessibilityLabel("\(row.name)，\(row.detail)")
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
        version.toolTip = "\(BuildInfo.version) · 点击检查更新"
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
    private var previewRefreshCount = 0
    private var previewQuitCount = 0
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var updateTimer: Timer?
    private var usage = UsageData()
    private let refreshGate = RefreshGate()
    private let launchAgentLabel = "com.local.kimi-usage"
    // 状态栏底色随全屏进出/深浅模式翻转时，KVO 触发按新外观重画（否则浅色栏上残留白色余量文字）；
    // setImage 也会再次触发 KVO 通知，用明暗主题快照去重防止 renderBar↔KVO 反馈循环。
    // 菜单栏可因深色壁纸、双屏或全屏而与 App 外观合法地不同，不能用 App 外观覆盖菜单栏。
    // 每 5s 对账，不一致时仅重建不缓存的动态颜色图片，不切换 isVisible、不钉死绘制外观。
    private var statusItemAppearanceObs: NSKeyValueObservation?
    private var barThemeDark: Bool?
    private var appearancePollTimer: Timer?
    private var updateProgressObserver: NSObjectProtocol?
    private var updateProgressWasActive = false
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
        // 面板内更新进度：状态翻转时重建内容（按钮↔进度行），进度百分比由进度行自刷；
        // 菜单栏 toolTip 同步更新状态，面板关闭时更新也在后台继续
        updateProgressObserver = NotificationCenter.default.addObserver(
            forName: UpdateProgressController.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.updateProgressDidChange() }
        refresh(manual: true)
        attachBarAppearanceObserver()
        appearancePollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.reconcileBarAppearance()
        }
        appearancePollTimer?.tolerance = 1
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = 3
        // 更新检查：启动 20 秒后首查（避开启动网络高峰），此后每 30 分钟；
        // 打开菜单也会触发一次（同一 interval 节流，不增加请求频率）
        updateTimer = Timer.scheduledTimer(withTimeInterval: UpdateCheck.interval, repeats: true) { [weak self] _ in
            self?.checkForUpdate()
        }
        updateTimer?.tolerance = 60
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkForUpdate() }
    }

    // 额度每 10s 刷新；月度和本地扫描按上次尝试时间每 5 分钟刷新。
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
        let quotaGroup = DispatchGroup()
        let mergeLock = NSLock()

        if let key = cred.codeApiKey, !key.isEmpty {
            group.enter()
            quotaGroup.enter()
            Fetcher.fetchCodeUsage(apiKey: key) { r in
                mergeLock.lock()
                merged.fiveHourUsed = r.fiveHourUsed
                merged.fiveHourReset = r.fiveHourReset
                merged.sevenDayUsed = r.sevenDayUsed
                merged.sevenDayReset = r.sevenDayReset
                merged.fiveHourError = r.fiveHourError
                merged.sevenDayError = r.sevenDayError
                mergeLock.unlock()
                quotaGroup.leave()
                group.leave()
            }
        } else {
            merged.fiveHourError = "no api key"
            merged.sevenDayError = "no api key"
        }

        // 额度先展示，不等待月度接口或本地扫描。
        quotaGroup.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            mergeLock.lock()
            let five = merged.fiveHourUsed, fiveReset = merged.fiveHourReset, fiveError = merged.fiveHourError
            let seven = merged.sevenDayUsed, sevenReset = merged.sevenDayReset, sevenError = merged.sevenDayError
            mergeLock.unlock()
            if let five { self.usage.fiveHourUsed = five; self.usage.fiveHourReset = fiveReset; self.lastFiveHourSuccessAt = Date() }
            if let seven { self.usage.sevenDayUsed = seven; self.usage.sevenDayReset = sevenReset; self.lastSevenDaySuccessAt = Date() }
            self.usage.fiveHourError = fiveError; self.usage.sevenDayError = sevenError
            self.updateUI()
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
                                merged.planName = r2.planName
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
                    merged.planName = r.planName
                    merged.monthError = r.monthError
                    mergeLock.unlock()
                    group.leave()
                }
            }
        } else if includeSlow {
            merged.monthError = "no web token"
        }

        // 头部账号行（CodexUsage 头部同款）：昵称 + 服务端打码手机号；401 走与月度相同的 refresh→重试链
        if includeSlow, let token = CredStore.load().webToken, !token.isEmpty {
            merged.accountFetched = true
            group.enter()
            func applyAccount(_ name: String?, _ phone: String?) {
                mergeLock.lock()
                merged.accountName = name
                merged.accountPhone = phone
                mergeLock.unlock()
                group.leave()
            }
            Fetcher.fetchKimiAccount(webToken: token) { name, phone, err in
                if let err = err, err.contains("401") {
                    Fetcher.refreshWebToken { newToken in
                        if let newToken = newToken {
                            Fetcher.fetchKimiAccount(webToken: newToken) { n2, p2, _ in applyAccount(n2, p2) }
                        } else {
                            group.leave()   // 续期失败：本轮不改写，保留旧值
                        }
                    }
                } else {
                    applyAccount(name, phone)
                }
            }
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
                merged.mergedTokens = d.merged
                merged.daily = d.daily
                merged.tools = d.tools
                merged.staleTokensInWindow = TokenAggregator.staleTokensInWindow(tools: d.tools)
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
                merged.planName = old.planName
                merged.accountName = old.accountName; merged.accountPhone = old.accountPhone
                merged.tokensToday = old.tokensToday; merged.tokens7d = old.tokens7d; merged.tokens30d = old.tokens30d
                merged.cliTokensToday = old.cliTokensToday; merged.cliTokens7d = old.cliTokens7d; merged.cliTokens30d = old.cliTokens30d
                merged.workTokensError = old.workTokensError; merged.cliTokensError = old.cliTokensError
                merged.mergedTokens = old.mergedTokens; merged.daily = old.daily
                merged.tools = old.tools; merged.staleTokensInWindow = old.staleTokensInWindow
            } else {
                if merged.monthUsed == nil { merged.monthUsed = old.monthUsed; merged.monthReset = old.monthReset }
                // 套餐名随月度接口走：本轮拉取失败（含未订阅报错）保留旧值，避免标题闪空
                if merged.monthError != nil { merged.planName = old.planName }
                // 账号行：本轮拉到哪个字段用哪个，缺的保留旧值；未拉取（无 web token）整组保留
                if merged.accountFetched {
                    if merged.accountName == nil { merged.accountName = old.accountName }
                    if merged.accountPhone == nil { merged.accountPhone = old.accountPhone }
                } else {
                    merged.accountName = old.accountName; merged.accountPhone = old.accountPhone
                }
                // 即使部分来源失败，也显示健康来源的新贡献和失败来源的缓存。

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
            refresh()
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
    private func attachBarAppearanceObserver() {
        statusItemAppearanceObs = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.renderBarIfThemeChanged() }
        }
    }

    private func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// 外观不一致既可能是按钮粘滞，也可能是深色壁纸或双屏的正常状态。
    /// 因此只重建不缓存的动态颜色图片，让实际菜单栏绘制上下文决定颜色。
    private func reconcileBarAppearance() {
        guard let button = statusItem.button else { return }
        let appDark = isDark(NSApp.effectiveAppearance)
        let buttonDark = isDark(button.effectiveAppearance)
        if buttonDark != appDark {
            renderBar()
        } else {
            renderBarIfThemeChanged()
        }
    }

    /// 仅当按钮解析出的明暗主题与上次渲染快照不同时才重画（防止 setImage↔KVO 循环）
    private func renderBarIfThemeChanged() {
        guard let button = statusItem.button else { return }
        let dark = isDark(button.effectiveAppearance)
        guard dark != barThemeDark else { return }
        renderBar()
    }

    /// 进度行自己刷新文本与百分比；这里只在「进行中」状态翻转时重建面板内容（按钮↔进度行），
    /// 并刷新菜单栏 toolTip。失败时面板若开着，额外给一条可重试的提示。
    private func updateProgressDidChange() {
        let active = UpdateProgressController.shared.isActive
        if active != updateProgressWasActive {
            updateProgressWasActive = active
            rebuildMenu()
            if !active, UpdateProgressController.shared.phase == .failed {
                panelController.setUpdateMessage("更新失败，详见弹窗提示", dismissAfter: 8)
            }
        }
        renderBar()
    }

    private func renderBar() {
        let fiveRemaining = remaining(usage.fiveHourUsed).map { Int(($0 * 100).rounded()) }
        let sevenRemaining = remaining(usage.sevenDayUsed).map { Int(($0 * 100).rounded()) }
        let line1 = StackImage.Line(label: (fiveHourStale ? "⚠️ 5H" : "5H"),
                                    value: Fmt.pct(remaining(usage.fiveHourUsed)), remaining: fiveRemaining)
        let line2 = StackImage.Line(label: (sevenDayStale ? "⚠️ 7D" : "7D"),
                                    value: Fmt.pct(remaining(usage.sevenDayUsed)), remaining: sevenRemaining)
        let appearance = statusItem.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        barThemeDark = isDark(appearance)
        statusItem.button?.image = StackImage.make(line1: line1, line2: line2)
        statusItem.button?.title = ""
        // toolTip 显示最后成功时间而非渲染时间：断网时能直接看出数据有多旧
        statusItem.button?.toolTip = "Kimi 余额 · 5H成功 \(Fmt.lastOK(lastFiveHourSuccessAt)) · 7D成功 \(Fmt.lastOK(lastSevenDaySuccessAt))"
            + " · 月度成功 \(Fmt.lastOK(lastMonthSuccessAt)) · Work扫描成功 \(Fmt.lastOK(workTokensLastSuccessAt))"
            + " · API扫描成功 \(Fmt.lastOK(cliTokensLastSuccessAt))"
        if UpdateProgressController.shared.isActive {
            statusItem.button?.toolTip = (statusItem.button?.toolTip ?? "")
                + " · \(UpdateProgressController.shared.statusLine)"
        }
        if !visualPreview { writeStatus(line1: "\(line1.label) \(line1.value)", line2: "\(line2.label) \(line2.value)") }
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
            "planName": usage.planName ?? "",
            "accountName": usage.accountName ?? "",
            "accountPhone": usage.accountPhone ?? "",
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
            return .init(title: title, resetText: reset.map { Fmt.resetDateTime($0) } ?? "时间未知",
                         remaining: remaining(used).map { Int(($0 * 100).rounded()) }, notices: notices)
        }
        func section(_ title: String, _ accent: PanelAccent, _ values: [TokenStat?], _ error: String?, _ last: Date?, _ stale: Bool) -> UsagePanelModel.TokenSection {
            let names = ["今日", "近 7 天", "近 30 天"]
            let rows = zip(names, values).map { name, stat in
                UsagePanelModel.TokenBucket(summaryLabel: name, detailLabel: name,
                    total: stat.map { Fmt.tokens($0.total) } ?? "--", input: stat.map { Fmt.tokens($0.input) } ?? "--",
                    output: stat.map { Fmt.tokens($0.output) } ?? "--",
                    models: (stat?.models ?? [:]).filter { $0.value.total > 0 }
                        .sorted { $0.value.total != $1.value.total ? $0.value.total > $1.value.total : $0.key < $1.key }
                        .map { UsagePanelModel.TokenModel(name: TokenAggregator.modelDisplayName($0.key), total: Fmt.tokens($0.value.total),
                            input: Fmt.tokens($0.value.input), output: Fmt.tokens($0.value.output)) })
            }
            var notices: [UsagePanelModel.Notice] = []
            if stale { notices.append(notice("⚠ 已过期 · 最后成功 \(last.map { Fmt.dayTime($0) } ?? "--")", .warning)) }
            if let error = error { notices.append(notice("统计失败：\(error) · 最后成功 \(last.map { Fmt.dayTime($0) } ?? "--")", .error)) }
            return .init(title: title, accent: accent, buckets: rows, notices: notices)
        }
        func item(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key); item.target = self; return item
        }
        let login = item("开机自启", #selector(onToggleLogin))
        login.state = (!visualPreview && isLoginItemEnabled()) ? .on : .off
        let update = UpdateChecker.shared.available ? item("⬆ 新版本可用，点击更新", #selector(onUpdateApp)) : nil
        // v1.5 用量洞察：用量情况（合并 Work + API 客户端）+ 用量简析 + 工具明细，同一扫描快照
        let coverageOK = usage.workTokensError == nil && usage.cliTokensError == nil
        let comparison = TokenAggregator.comparisons(daily: usage.daily, staleTokensInWindow: usage.staleTokensInWindow)
        func briefDay(_ offset: Int) -> UsagePanelModel.BriefDay {
            let key = TokenAggregator.dayKey(offset, from: Date())
            let parts = key.split(separator: "-")
            let label = parts.count == 3 ? "\(parts[1])/\(parts[2])" : key
            if let value = usage.daily[key] {
                return UsagePanelModel.BriefDay(label: label, total: value[0] + value[1], input: value[0],
                                                output: value[1], covered: true, isToday: offset == 0)
            }
            // 覆盖可证实时缺键 = 真实 0；否则缺失占位，不补零伪装趋势
            return UsagePanelModel.BriefDay(label: label, total: 0, input: 0, output: 0, covered: coverageOK, isToday: offset == 0)
        }
        // 比较条架构与文案对齐 GLMUsage：日环比/7日环比、%+.1f%% 中性数值、新增带数值
        func comparisonItem(_ label: String, _ value: TokenAggregator.Comparison.Value,
                            _ detail: String) -> UsagePanelModel.BriefComparison {
            switch value {
            case .percent(let pct):
                return UsagePanelModel.BriefComparison(label: label,
                    text: String(format: "%+.1f%%", pct),
                    direction: pct < 0 ? .down : .up, detail: detail)
            case .flat:
                return UsagePanelModel.BriefComparison(label: label, text: "持平", direction: .flat, detail: detail)
            case .added(let total):
                return UsagePanelModel.BriefComparison(label: label, text: "新增 \(Fmt.tokens(total))",
                    direction: .up, detail: detail)
            case .insufficient:
                return UsagePanelModel.BriefComparison(label: label, text: "数据不足", direction: .flat, detail: detail)
            }
        }
        let brief = UsagePanelModel.BriefSection(days: (-29...0).map(briefDay),
            day: comparisonItem("日环比", comparison.day, comparison.dayDetail),
            week: comparisonItem("7日环比", comparison.week, comparison.weekDetail),
            notices: [])
        func fixedOrder(_ id: TokenAggregator.ToolID) -> Int {
            TokenAggregator.ToolID.allCases.firstIndex(of: id) ?? .max
        }
        let mergedTotals = [usage.mergedTokens?.today.total ?? 0,
                            usage.mergedTokens?.week.total ?? 0,
                            usage.mergedTokens?.month.total ?? 0]
        func toolRows(_ index: Int) -> [UsagePanelModel.ToolRow] {
            // 该周期使用量为 0 的来源直接隐藏（用户 2026-11-07 要求）；
            // 失败来源若有历史贡献（>0）仍保留行并标缓存，全部为零时显示「本周期暂无用量」空态
            let active = usage.tools.filter { tool in
                let window = tool.windows()
                return [window.today, window.week, window.month][index].total > 0
            }
            let sorted = active.sorted { lhs, rhs in
                let lhsWindow = lhs.windows()
                let rhsWindow = rhs.windows()
                let lhsTotal = [lhsWindow.today.total, lhsWindow.week.total, lhsWindow.month.total][index]
                let rhsTotal = [rhsWindow.today.total, rhsWindow.week.total, rhsWindow.month.total][index]
                if lhsTotal != rhsTotal { return lhsTotal > rhsTotal }
                return fixedOrder(lhs.id) < fixedOrder(rhs.id)
            }
            return sorted.compactMap { tool in
                let window = tool.windows()
                let stat = [window.today, window.week, window.month][index]
                let denominator = mergedTotals[index]
                let share = denominator > 0 ? stat.total / denominator : 0
                let status: String
                switch tool.id {
                case .hermes:
                    status = !tool.ok ? "部分记录 · 缓存" : (tool.modelDays.isEmpty ? "可读取 · 无记录" : "可读取 · 近似归日")
                case .work, .cli, .proma, .claude, .zcode:
                    if !tool.installed { status = "标准路径未发现" }
                    else if !tool.ok { status = "部分记录 · 缓存" }
                    else if tool.modelDays.isEmpty { status = "可读取 · 无记录" }
                    else { status = "可读取" }
                }
                let sharePct = Int((share * 100).rounded())
                let detail = "\(status) · 输入 \(Fmt.tokens(stat.input)) · 输出 \(Fmt.tokens(stat.output)) · 占比 \(sharePct)%"
                return UsagePanelModel.ToolRow(name: tool.id.displayName, total: Fmt.tokens(stat.total),
                    share: share, shareText: "\(sharePct)%", status: status, detail: detail)
            }
        }
        let toolsSection = UsagePanelModel.ToolsSection(periods: [toolRows(0), toolRows(1), toolRows(2)], notices: [])
        let usageSection = section("用量情况", .codex,
            [usage.mergedTokens?.today, usage.mergedTokens?.week, usage.mergedTokens?.month],
            usage.workTokensError ?? usage.cliTokensError,
            usage.workTokensError != nil ? workTokensLastSuccessAt : cliTokensLastSuccessAt,
            tokensStale)
        // 头部账号行：昵称（打码手机号）；账号无手机号时回退昵称，两者皆缺则隐藏该行
        let accountLine: String? = {
            switch (usage.accountName, usage.accountPhone) {
            case let (name?, phone?): return "\(name)（\(phone)）"
            case let (nil, phone?): return phone
            case let (name?, nil): return name
            default: return nil
            }
        }()
        panelController.update(model: UsagePanelModel(updateItem: update,
            title: "Kimi 用量", planName: usage.planName, accountLine: accountLine,
            quotas: [quota("5 小时", usage.fiveHourUsed, usage.fiveHourReset, usage.fiveHourError, lastFiveHourSuccessAt, fiveHourStale),
                     quota("7 天", usage.sevenDayUsed, usage.sevenDayReset, usage.sevenDayError, lastSevenDaySuccessAt, sevenDayStale),
                     quota("月度", usage.monthUsed, usage.monthReset, usage.monthError, lastMonthSuccessAt, monthStale)],
            resetCards: nil, tibo: nil,
            usage: usageSection,
            brief: brief,
            tools: toolsSection,
            notices: [], lastAttempt: "最近尝试刷新 \(Fmt.time(lastAttemptAt))", version: "版本 \(BuildInfo.version.split(separator: "-").first.map(String.init) ?? BuildInfo.version)",
            refreshItem: item("立即刷新", #selector(onRefresh), key: "r"), loginItem: login, quitItem: item("退出", #selector(onQuit), key: "q")))
    }

    private func configureVisualPreview() {
        let args = CommandLine.arguments
        if args.contains("--visual-preview-dark") {
            NSApp.appearance = NSAppearance(named: .darkAqua)
            panelController.previewAppearance = NSAppearance(named: .darkAqua)
        }
        if args.contains("--visual-preview-narrow") { panelController.previewWidth = 300 }
        let now = Date(timeIntervalSince1970: 1_793_702_400)
        lastAttemptAt = now
        lastFiveHourSuccessAt = now; lastSevenDaySuccessAt = now; lastMonthSuccessAt = now
        workTokensLastSuccessAt = now; cliTokensLastSuccessAt = now
        usage.fiveHourUsed = 0.23; usage.sevenDayUsed = 0.67; usage.monthUsed = 0.42
        if args.contains("--visual-preview-full") {
            usage.fiveHourUsed = 0; usage.sevenDayUsed = 0; usage.monthUsed = 0
        }
        usage.planName = "Allegretto"
        usage.accountName = "Junxiao"; usage.accountPhone = "185****5369"
        usage.fiveHourReset = now.addingTimeInterval(18000); usage.sevenDayReset = now.addingTimeInterval(604800); usage.monthReset = now.addingTimeInterval(2592000)
        func previewStat(_ input: Double, _ output: Double, _ first: [Double], _ second: [Double]) -> TokenStat {
            var stat = TokenStat(input: input, output: output)
            stat.models = ["k3.1-pro": ModelTokenStat(input: first[0], output: first[1]),
                           "k3-256k": ModelTokenStat(input: second[0], output: second[1])]
            return stat
        }
        usage.tokensToday = previewStat(1230000, 320000, [800000, 200000], [430000, 120000])
        usage.tokens7d = previewStat(8200000, 1200000, [6000000, 800000], [2200000, 400000])
        usage.tokens30d = previewStat(32000000, 5100000, [24000000, 4000000], [8000000, 1100000])
        usage.cliTokensToday = previewStat(5400000, 230000, [4000000, 180000], [1400000, 50000])
        usage.cliTokens7d = previewStat(61000000, 890000, [45000000, 700000], [16000000, 190000])
        usage.cliTokens30d = previewStat(440000000, 2100000, [320000000, 1500000], [120000000, 600000])
        if args.contains("--visual-preview-empty") {
            usage = UsageData()
        } else {
            // v1.5 用量洞察预览：合并窗口 + 近 30 天日序列 + 逐工具贡献（与评审原型演示数据同款）
            let workPattern: [Double] = [0.9, 1.1, 1.2, 1.0, 1.4, 1.3, 1.1, 1.5, 1.2, 1.4, 1.0, 1.6, 1.2,
                                         1.3, 1.5, 1.1, 1.2, 1.4, 1.3, 1.6, 1.1, 1.2, 1.4, 1.1, 1.6, 1.0,
                                         1.35, 1.4, 1.4, 1.55]
            let apiPattern: [Double] = [7, 9, 8, 8.5, 9, 9.26, 11]
            // 日序列锚定真实今天：图表与比较条演示健康分支；额度冻结区仍锚定固定预览时间
            let chartNow = Date()
            func previewWorkDays() -> TokenAggregator.ModelDays {
                var days: TokenAggregator.ModelDays = [:]
                for (index, value) in workPattern.enumerated() {
                    days[TokenAggregator.dayKey(index - 29, from: chartNow)] =
                        ["k3.1-pro": [value * 0.88e6 * 0.8, value * 0.12e6 * 0.8],
                         "k3-256k": [value * 0.88e6 * 0.2, value * 0.12e6 * 0.2]]
                }
                return days
            }
            func previewAPIDays(_ share: Double) -> TokenAggregator.ModelDays {
                var days: TokenAggregator.ModelDays = [:]
                for (index, value) in workPattern.enumerated() {
                    let api = (index >= 23 ? apiPattern[index - 23] : value * 7) * 1e6 * share
                    days[TokenAggregator.dayKey(index - 29, from: chartNow)] =
                        ["k3.1-pro": [api * 0.9 * 0.7, api * 0.1 * 0.7],
                         "k3-256k": [api * 0.9 * 0.3, api * 0.1 * 0.3]]
                }
                return days
            }
            usage.tools = [
                TokenAggregator.ToolStats(id: .work, modelDays: previewWorkDays(), installed: true, ok: true),
                TokenAggregator.ToolStats(id: .cli, modelDays: previewAPIDays(0.36), installed: true, ok: true),
                TokenAggregator.ToolStats(id: .proma, modelDays: previewAPIDays(0.24), installed: true, ok: true),
                TokenAggregator.ToolStats(id: .claude, modelDays: previewAPIDays(0.18), installed: true, ok: true),
                TokenAggregator.ToolStats(id: .zcode, modelDays: previewAPIDays(0.1), installed: true, ok: true),
                TokenAggregator.ToolStats(id: .hermes, modelDays: previewAPIDays(0.12), installed: true, ok: true)
            ]
            var allDays: TokenAggregator.ModelDays = [:]
            var dailyTotals: [String: [Double]] = [:]
            for tool in usage.tools {
                allDays = TokenAggregator.mergeSourceModelDays(allDays, tool.modelDays)
                for (key, models) in tool.modelDays {
                    var total = dailyTotals[key] ?? [0, 0]
                    for (_, value) in models { total[0] += value[0]; total[1] += value[1] }
                    dailyTotals[key] = total
                }
            }
            usage.daily = dailyTotals
            usage.mergedTokens = TokenAggregator.statWindows(allDays, now: chartNow)
            usage.staleTokensInWindow = 0
            if args.contains("--visual-preview-states") || args.contains("--visual-preview-long") {
                usage.staleTokensInWindow = 1   // 演示比较条「数据不足」分支
            }
        }
        // 更新进度行预览：updating 为下载中 62%；updating-install 为安装重启阶段（含重启预告）
        if args.contains("--visual-preview-updating-install") {
            UpdateProgressController.shared.simulateForPreview(phase: .installing, fraction: 100)
        } else if args.contains("--visual-preview-updating") {
            UpdateProgressController.shared.simulateForPreview(phase: .downloading, fraction: 62)
        }
        if args.contains("--visual-preview-states") || args.contains("--visual-preview-long") {
            let message = args.contains("--visual-preview-long") ? String(repeating: "网络连接失败，请稍后重试。", count: 80) : "网络连接失败"
            usage.fiveHourError = message; usage.sevenDayUsed = nil; usage.sevenDayError = "凭证已过期"; usage.monthError = "月度接口不可用"
            usage.workTokensError = message; usage.cliTokensError = "会话目录不可读"
        }
        rebuildMenu(); renderBar()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, let button = self.statusItem.button else { return }
            self.panelController.toggle(anchoredTo: button)
            if args.contains("--visual-preview-models") { self.panelController.expandAllTokenBucketsForPreview() }
            if args.contains("--visual-preview-tools") { self.panelController.expandToolsForPreview() }
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
            if let arg = args.first(where: { $0.hasPrefix("--visual-preview-popover-test=") }) {
                self.panelController.runPopoverResizeTest(outputDirectory: String(arg.dropFirst("--visual-preview-popover-test=".count)))
                return
            }
            if args.contains("--visual-preview-update-test") {
                self.runPreviewUpdateTest()
                return
            }
            if args.contains("--visual-preview-key-test") {
                self.runPreviewKeyTest(button: button)
                return
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

    // The fake transport lets overlapping checks complete through the normal main-queue path.
    private func runPreviewUpdateTest() {
        typealias Reply = (Data?, URLResponse?, Error?) -> Void
        var replies: [Reply] = []
        var completions = 0
        let checker = UpdateChecker { _, reply in replies.append(reply) }
        func fail(_ message: String) { fputs("KimiUsage update test: FAIL: \(message)\n", stderr); exit(1) }
        func response(_ status: Int) -> HTTPURLResponse {
            HTTPURLResponse(url: UpdateCheck.apiURL, statusCode: status, httpVersion: nil, headerFields: nil)!
        }
        checker.check { completions += 1 }
        checker.check(force: true) { completions += 1 }
        guard replies.count == 1 else { return fail("overlapping checks started extra requests") }
        replies.removeFirst()(nil, nil, NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard completions == 2, checker.lastError else { return fail("concurrent error callbacks") }
            checker.check(force: true) { completions += 1 }
            guard replies.count == 1 else { return fail("forced retry") }
            replies.removeFirst()(Data("{\"tag_name\":\"invalid\"}".utf8), response(200), nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                guard completions == 3, checker.lastError else { return fail("invalid release reported success") }
                checker.check(force: true) { completions += 1 }
                let release = """
                    [{"tag_name":"v999.0.0","draft":false,"prerelease":false,
                      "assets":[{"name":"KimiUsage.zip"},{"name":"KimiUsage.zip.sha256"}]}]
                    """
                replies.removeFirst()(Data(release.utf8), response(200), nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    guard completions == 4, !checker.lastError, checker.available, checker.targetTag == "v999.0.0" else { return fail("successful release check") }
                    checker.check(force: true) { completions += 1 }
                    replies.removeFirst()(nil, response(304), nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        guard completions == 5, !checker.lastError, checker.available, checker.targetTag == "v999.0.0" else { return fail("cached 304") }
                        print("KimiUsage update check test: PASS")
                        exit(0)
                    }
                }
            }
        }
    }

    private func runPreviewKeyTest(button: NSStatusBarButton) {
        func fail(_ message: String) { fputs("KimiUsage key event test: FAIL: \(message)\n", stderr); exit(1) }
        func send(_ character: String, _ keyCode: UInt16) {
            guard let window = NSApp.keyWindow,
                  let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                      timestamp: 0, windowNumber: window.windowNumber, context: nil,
                      characters: character, charactersIgnoringModifiers: character,
                      isARepeat: false, keyCode: keyCode) else { fail("cannot create event"); return }
            NSApp.sendEvent(event)
        }
        guard let keyWindow = NSApp.keyWindow,
              let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                  windowNumber: keyWindow.windowNumber, context: nil, characters: "\u{1b}",
                  charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) else { return fail("escape event") }
        NSApp.sendEvent(escape)
        guard !panelController.isOpen else { return fail("Escape") }
        button.performClick(nil)
        guard panelController.isOpen else { return fail("reopen after Escape") }
        send("r", 15)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            // 刷新不再收起面板（与点击「立即刷新」同路径），随后手动走关闭→重开→⌘Q
            guard self.previewRefreshCount == 1, self.panelController.isOpen else { return fail("Command-R") }
            button.performClick(nil)
            guard !self.panelController.isOpen else { return fail("toggle close") }
            button.performClick(nil)
            guard self.panelController.isOpen else { return fail("toggle reopen") }
            send("q", 12)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                guard self.previewQuitCount == 1, !self.panelController.isOpen else { return fail("Command-Q") }
                print("KimiUsage key event test: PASS")
                exit(0)
            }
        }
    }

    private func manualUpdateCheck() {
        if visualPreview { panelController.setUpdateMessage("预览模式：未联网检查更新", dismissAfter: 3); return }
        panelController.setUpdateMessage("正在检查更新…")
        UpdateChecker.shared.check(force: true) { [weak self] in
            guard let self = self else { return }
            self.rebuildMenu()
            self.panelController.setUpdateMessage(UpdateChecker.shared.lastError ? "检查失败，请稍后重试" : (UpdateCheck.normalized(BuildInfo.version) == nil ? "当前版本无法比较" : (UpdateChecker.shared.available ? "发现新版本" : "已是最新版本")), dismissAfter: 3)
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

    @objc private func onRefresh() { if visualPreview { previewRefreshCount += 1 } else { refresh(manual: true) } }

    // 更新检查完成后无条件重建菜单：横幅出现/消失都靠它自愈（刷新周期 ≤10s 也会兜底重建）
    private func checkForUpdate() {
        UpdateChecker.shared.check { [weak self] in self?.updateUI() }
    }

    @objc private func onUpdateApp() {
        guard !visualPreview else { return }
        // App Translocation：从下载目录直接运行的应用被挂载到只读位置，原地更新必然失败，
        // 在发起更新前拦截并给出安装指引，而不是让脚本在暂存阶段报错。
        if Bundle.main.bundleURL.path.contains("/AppTranslocation/") {
            let alert = NSAlert()
            alert.messageText = "无法原地更新"
            alert.informativeText = "KimiUsage 正在从临时位置运行（App Translocation），无法原地替换。\n请退出应用，把 KimiUsage.app 拖入「应用程序」文件夹后从那里打开。"
            alert.addButton(withTitle: "好")
            alert.runModal()
            return
        }
        guard let script = Bundle.main.path(forResource: "update", ofType: "sh") else {
            NSWorkspace.shared.open(UpdateCheck.releasesPage); return
        }
        guard let tag = UpdateChecker.shared.targetTag else { return }
        UpdateProgressController.shared.start(script: script, targetTag: tag, appPath: Bundle.main.bundleURL.path)
    }

    @objc func onQuit() { if visualPreview && CommandLine.arguments.contains("--visual-preview-key-test") { previewQuitCount += 1 } else { NSApp.terminate(nil) } }
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

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let resetDate = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 6, minute: 15))!
            try expect(Fmt.resetDateTime(resetDate) == "11-10 周二 06:15", "reset weekday formatting changed")
            try expect(Fmt.dayTime(resetDate) == "11-10 06:15", "existing date formatting changed")
            try expect(Fmt.resetDateTime(nil).isEmpty, "missing reset date formatting changed")

            try expect(UsageNumber.finite(Double.nan) == nil, "NaN accepted")
            try expect(UsageNumber.finite("Infinity") == nil, "Infinity accepted")
            try expect(UsageNumber.unitRatio("1.2") == nil, "out-of-range month ratio accepted")

            let tiers: [(Int?, RemainingColorTier)] = [
                (nil, .normal), (0, .red), (19, .red), (20, .orange), (39, .orange),
                (40, .normal), (79, .normal), (80, .green), (100, .green)
            ]
            for (remaining, expected) in tiers {
                try expect(RemainingColorTier(remaining: remaining) == expected,
                           "wrong menu bar color tier for \(remaining.map(String.init) ?? "nil")")
            }
            let previewLine = StackImage.Line(label: "7D", value: "39%", remaining: 39)
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                let appearance = NSAppearance(named: name)!
                // 菜单栏图片已全面动态取色；此处分外观验证解析结果与渲染仍然成立
                let green = RemainingColorTier.green.color(for: appearance).usingColorSpace(.sRGB)
                try expect(green.map { $0.greenComponent > $0.redComponent
                                      && $0.greenComponent > $0.blueComponent } == true,
                           "green tier did not resolve to green for \(name.rawValue)")
                let image = StackImage.make(line1: previewLine, line2: previewLine, appearance: appearance)
                try expect(!image.isTemplate && image.cacheMode == .never
                           && image.size.width > 0 && image.tiffRepresentation != nil,
                           "menu bar uncached color image did not render for \(name.rawValue)")
            }

            // 外观重绘必须真正改变文字颜色：浅色外观画深字，深色外观画浅字。
            func neutralInkCount(_ image: NSImage, white: Bool) -> Int {
                guard let data = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: data) else { return 0 }
                var count = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                              color.alphaComponent > 0.8 else { continue }
                        let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                        let brightness = (channels[0] + channels[1] + channels[2]) / 3
                        let grayscale = channels.allSatisfy { abs($0 - brightness) < 0.02 }
                        if grayscale && (white ? brightness > 0.8 : brightness < 0.2) { count += 1 }
                    }
                }
                return count
            }
            let neutralLine = StackImage.Line(label: "5H", value: "50%", remaining: 50)
            let lightImage = StackImage.make(line1: neutralLine, line2: neutralLine,
                                             appearance: NSAppearance(named: .aqua)!)
            let darkImage = StackImage.make(line1: neutralLine, line2: neutralLine,
                                            appearance: NSAppearance(named: .darkAqua)!)
            try expect(neutralInkCount(lightImage, white: false) > 0,
                       "light appearance override did not draw dark menu bar text")
            try expect(neutralInkCount(darkImage, white: true) > 0,
                       "dark appearance override did not draw light menu bar text")

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
            // 套餐名：取 subscription.goods.title；缺失/空串一律视为无套餐，不得报错
            try expect(Fetcher.parseMonthUsagePayload([
                "subscription": ["goods": ["title": "Allegretto"]],
                "balances": [["feature": "FEATURE_OMNI", "amountUsedRatio": 0.5]]
            ]).planName == "Allegretto", "valid plan title rejected")
            try expect(Fetcher.parseMonthUsagePayload([
                "balances": [["feature": "FEATURE_OMNI", "amountUsedRatio": 0.5]]
            ]).planName == nil, "missing subscription was treated as a plan")
            try expect(Fetcher.parseMonthUsagePayload([
                "subscription": ["goods": ["title": ""]],
                "balances": [["feature": "FEATURE_OMNI", "amountUsedRatio": 0.5]]
            ]).planName == nil, "empty plan title was accepted")

            // 头部账号行解析：昵称回退 shared_user_name、打码手机号原样保留、空串视为缺失
            let account = Fetcher.parseKimiAccountPayload(["name": "Junxiao", "phone": "185****5369"])
            try expect(account.name == "Junxiao" && account.phone == "185****5369",
                       "kimi account name/phone lost")
            let accountFallback = Fetcher.parseKimiAccountPayload(["shared_user_name": "昵称", "phone": "   "])
            try expect(accountFallback.name == "昵称" && accountFallback.phone == nil,
                       "kimi account fallback or blank-phone guard wrong")
            try expect(Fetcher.parseKimiAccountPayload([:]).name == nil
                       && Fetcher.parseKimiAccountPayload([:]).phone == nil,
                       "missing kimi account fields were fabricated")

            // 扫描失败面：已安装来源全部不可读才置错；未安装/部分可读/仅 hermes 成功均不置错
            try expect(TokenAggregator.sourceError(installed: 1, enumerated: 0, hermesOK: nil) != nil,
                       "unreadable installed root was reported as success")
            try expect(TokenAggregator.sourceError(installed: 0, enumerated: 0, hermesOK: nil) == nil,
                       "not-installed source was reported as failure")
            try expect(TokenAggregator.sourceError(installed: 2, enumerated: 1, hermesOK: nil) != nil,
                       "partially readable sources were reported as total failure")
            try expect(TokenAggregator.sourceError(installed: 0, enumerated: 0, hermesOK: false) != nil,
                       "corrupt hermes db was reported as success")
            try expect(TokenAggregator.sourceError(installed: 1, enumerated: 0, hermesOK: true) != nil,
                       "healthy hermes source did not clear the failure")
            try expect(TokenAggregator.sourceError(installed: 0, enumerated: 0, hermesOK: nil, zcodeOK: false) != nil,
                       "corrupt ZCode db was reported as success")
            try expect(TokenAggregator.sourceError(installed: 0, enumerated: 0, hermesOK: false, zcodeOK: true) != nil,
                       "partial failure was not reported")
            try expect(TokenAggregator.sourceError(installed: 0, enumerated: 0, hermesOK: nil, zcodeOK: nil) == nil,
                       "not-installed sqlite sources were reported as failure")
            // 窗口口径：含今天共 7/30 个日历日（Calendar 运算；固定 86400 秒在 DST 日界会漂移一天）
            let cutNow = Date(timeIntervalSince1970: 1_800_000_000)
            let cuts = TokenAggregator.windowCutoffs(now: cutNow)
            try expect(cuts.d7 == TokenAggregator.dayKey(-6, from: cutNow)
                       && cuts.d30 == TokenAggregator.dayKey(-29, from: cutNow),
                       "7/30 calendar-day window cutoffs drifted")
            // DST 回归：America/New_York 2026-03-09 00:30（EDT）前推 6 个日历日应为 03-03；
            // 固定 86400 秒会落到 03-02 23:30（EST）导致日界漂移一天。
            var dstCalendar = Calendar(identifier: .gregorian)
            dstCalendar.timeZone = TimeZone(identifier: "America/New_York")!
            var dstComponents = DateComponents()
            dstComponents.year = 2026; dstComponents.month = 3; dstComponents.day = 9
            dstComponents.hour = 0; dstComponents.minute = 30
            let dstNow = dstCalendar.date(from: dstComponents)!
            let dstCuts = TokenAggregator.windowCutoffs(now: dstNow, calendar: dstCalendar)
            try expect(dstCuts.d7 == "2026-03-03" && dstCuts.d30 == "2026-02-08",
                       "calendar-day window drifted across DST boundary")

            // v1.5 用量洞察：statWindows 边界与模型闭合
            var windowDays: TokenAggregator.ModelDays = [:]
            windowDays[TokenAggregator.dayKey(0, from: cutNow)] = ["k3": [10, 2]]
            windowDays[TokenAggregator.dayKey(-5, from: cutNow)] = ["k3": [1, 1]]
            windowDays[TokenAggregator.dayKey(-7, from: cutNow)] = ["k3": [5, 5]]
            windowDays[TokenAggregator.dayKey(-29, from: cutNow)] = ["k3": [7, 1]]
            windowDays[TokenAggregator.dayKey(-31, from: cutNow)] = ["k3": [100, 100]]
            let windowStats = TokenAggregator.statWindows(windowDays, now: cutNow)
            try expect(windowStats.today.total == 12 && windowStats.week.total == 14 && windowStats.month.total == 32,
                       "statWindows day-window boundaries drifted")
            try expect(windowStats.month.models["k3"]?.total == 32, "statWindows model sum drifted")

            // 逐工具窗口之和 = 合并总量（原始精度）
            let toolA = TokenAggregator.ToolStats(id: .work, modelDays: windowDays, installed: true, ok: true)
            let toolB = TokenAggregator.ToolStats(id: .hermes, modelDays: windowDays, installed: true, ok: true)
            var mergedDays: TokenAggregator.ModelDays = [:]
            for tool in [toolA, toolB] {
                mergedDays = TokenAggregator.mergeSourceModelDays(mergedDays, tool.modelDays)
            }
            let mergedWindows = TokenAggregator.statWindows(mergedDays, now: cutNow)
            try expect(mergedWindows.month.total == toolA.windows(now: cutNow).month.total + toolB.windows(now: cutNow).month.total,
                       "tool windows did not sum to merged total")
            let dailyFold = TokenAggregator.dailyTotals(windowDays)
            try expect(dailyFold[TokenAggregator.dayKey(0, from: cutNow)] == [10, 2], "dailyTotals fold drifted")

            // 比较条：百分比 / 持平 / 新增 / 数据不足
            var daily: [String: [Double]] = [:]
            daily[TokenAggregator.dayKey(0, from: cutNow)] = [12, 0]
            daily[TokenAggregator.dayKey(-1, from: cutNow)] = [10, 0]
            daily[TokenAggregator.dayKey(-2, from: cutNow)] = [0, 0]
            daily[TokenAggregator.dayKey(-6, from: cutNow)] = [4, 0]
            daily[TokenAggregator.dayKey(-13, from: cutNow)] = [20, 0]
            let comp = TokenAggregator.comparisons(daily: daily, staleTokensInWindow: 0, now: cutNow)
            if case .percent(let dayPct) = comp.day {
                try expect(abs(dayPct - 20) < 0.001, "较昨日 percent drifted")
            } else { try expect(false, "较昨日 should be percent") }
            if case .percent(let weekPct) = comp.week {
                try expect(abs(weekPct - 30) < 0.001, "较前7天 percent drifted")
            } else { try expect(false, "较前7天 should be percent") }
            let zeroComp = TokenAggregator.comparisons(daily: [:], staleTokensInWindow: 0, now: cutNow)
            if case .flat = zeroComp.day {} else { try expect(false, "empty coverage day should be flat") }
            if case .flat = zeroComp.week {} else { try expect(false, "empty coverage week should be flat") }
            var addedDaily: [String: [Double]] = [:]
            addedDaily[TokenAggregator.dayKey(0, from: cutNow)] = [5, 5]
            let addedComp = TokenAggregator.comparisons(daily: addedDaily, staleTokensInWindow: 0, now: cutNow)
            if case .added = addedComp.day {} else { try expect(false, "base-zero day should be added") }
            // GLM 同款持平阈值：|pct| < 0.05 归持平（防 ±0.0%）
            let flatThresholdDaily: [String: [Double]] = [
                TokenAggregator.dayKey(0, from: cutNow): [1_000_000, 0],
                TokenAggregator.dayKey(-1, from: cutNow): [1_000_001, 0]
            ]
            let flatThresholdComp = TokenAggregator.comparisons(daily: flatThresholdDaily, staleTokensInWindow: 0, now: cutNow)
            if case .flat = flatThresholdComp.day {} else { try expect(false, "|pct|<0.05 should be flat") }
            let staleComp = TokenAggregator.comparisons(daily: daily, staleTokensInWindow: 0.5, now: cutNow)
            if case .insufficient = staleComp.day {} else { try expect(false, "stale day must be insufficient") }
            if case .insufficient = staleComp.week {} else { try expect(false, "stale week must be insufficient") }

            // 陈旧贡献只在失败来源上统计，且只看 [D-13, D]
            let staleTool = TokenAggregator.ToolStats(id: .proma, modelDays: windowDays, installed: true, ok: false)
            try expect(TokenAggregator.staleTokensInWindow(tools: [staleTool], now: cutNow) == 24,
                       "stale contribution window mismatch")
            let okTool = TokenAggregator.ToolStats(id: .proma, modelDays: windowDays, installed: true, ok: true)
            try expect(TokenAggregator.staleTokensInWindow(tools: [okTool], now: cutNow) == 0,
                       "ok tool counted as stale contribution")

            // 逐工具归属：realpath 前缀匹配（临时目录模拟 CLI 根）
            let cliRoot = root.appendingPathComponent("cli-roots/cli")
            let promaRoot = root.appendingPathComponent("cli-roots/proma")
            let claudeRoot = root.appendingPathComponent("cli-roots/claude")
            let otherRoot = root.appendingPathComponent("cli-roots/other")
            for dir in [cliRoot, promaRoot, claudeRoot, otherRoot] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            for (dir, name) in [(cliRoot, "a.jsonl"), (promaRoot, "b.jsonl"),
                                (claudeRoot, "c.jsonl"), (otherRoot, "d.jsonl")] {
                try Data().write(to: dir.appendingPathComponent(name))
            }
            let attributionRoots = [cliRoot.path, promaRoot.path, promaRoot.path, claudeRoot.path]
            try expect(TokenAggregator.toolID(forSessionPath: cliRoot.appendingPathComponent("a.jsonl").path,
                                              roots: attributionRoots) == .cli, "cli attribution drifted")
            try expect(TokenAggregator.toolID(forSessionPath: promaRoot.appendingPathComponent("b.jsonl").path,
                                              roots: attributionRoots) == .proma, "proma attribution drifted")
            try expect(TokenAggregator.toolID(forSessionPath: claudeRoot.appendingPathComponent("c.jsonl").path,
                                              roots: attributionRoots) == .claude, "claude attribution drifted")
            try expect(TokenAggregator.toolID(forSessionPath: otherRoot.appendingPathComponent("d.jsonl").path,
                                              roots: attributionRoots) == .cli, "unknown path fell back unexpectedly")

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

            // API 逐调用行回归：Kimi Code 双写只计 usage.record；Proma result 汇总整行跳过。
            func jsonLine(_ object: [String: Any]) throws -> String {
                let data = try JSONSerialization.data(withJSONObject: object)
                return String(data: data, encoding: .utf8)!
            }
            func totals(_ state: TokenAggregator.FileScanState) -> [Double] {
                state.days.values.reduce([0, 0]) { [$0[0] + $1[0], $0[1] + $1[1]] }
            }
            let eventMS = Date().timeIntervalSince1970 * 1000
            let kimiUsage: [String: Any] = ["inputOther": 10, "inputCacheRead": 20,
                                            "inputCacheCreation": 5, "output": 2]
            let usageRecord: [String: Any] = ["type": "usage.record", "time": eventMS,
                                              "model": "k3.1-pro", "usage": kimiUsage]
            let loopMirror: [String: Any] = ["type": "context.append_loop_event", "time": eventMS,
                                             "event": ["usage": kimiUsage]]
            let otherRecord: [String: Any] = ["type": "usage.record", "time": eventMS,
                                              "model": "glm-5.3", "usage": kimiUsage]
            var apiFile = TokenAggregator.FileScanState()
            try TokenAggregator.parseLines([jsonLine(usageRecord), jsonLine(loopMirror),
                                            jsonLine(otherRecord)].joined(separator: "\n"),
                                           kimiOnly: true, cutoffKey: "0000-00-00", into: &apiFile)
            try expect(totals(apiFile) == [35, 2], "Kimi Code mirror row or other model was counted")
            var workFile = TokenAggregator.FileScanState()
            try TokenAggregator.parseLines(jsonLine(loopMirror), kimiOnly: false,
                                           cutoffKey: "0000-00-00", into: &workFile)
            try expect(totals(workFile) == [35, 2], "legacy Kimi Work loop event was lost")
            var workMixed = TokenAggregator.FileScanState()
            try TokenAggregator.parseLines([jsonLine(usageRecord), jsonLine(loopMirror)].joined(separator: "\n"),
                                           kimiOnly: false, cutoffKey: "0000-00-00",
                                           preferUsageRecord: true, into: &workMixed)
            try expect(totals(workMixed) == [35, 2], "Kimi Work record + loop mirror was double-counted")
            let modelDayKey = TokenAggregator.dayFmt.string(from: Date())
            try expect(apiFile.modelDays[modelDayKey]?["k3.1-pro"] == [35, 2]
                       && workMixed.modelDays[modelDayKey]?["k3.1-pro"] == [35, 2]
                       && workFile.modelDays[modelDayKey]?["未知模型"] == [35, 2],
                       "model attribution or legacy unknown-model fallback is wrong")
            let switchedRecord = try jsonLine(["type": "usage.record", "time": eventMS + 1,
                                               "model": "k3-256k", "usage": kimiUsage])
            TokenAggregator.parseLines(switchedRecord, kimiOnly: true, cutoffKey: "0000-00-00", into: &apiFile)
            try expect(totals(apiFile) == [70, 4]
                       && apiFile.modelDays[modelDayKey]?["k3.1-pro"] == [35, 2]
                       && apiFile.modelDays[modelDayKey]?["k3-256k"] == [35, 2],
                       "model switching mixed or dropped token contributions")

            // 增量格式升级：先只有 loop，追加 record 后同轮重扫，只留一份镜像。
            let workRoot = root.appendingPathComponent("work-scan").path
            try FileManager.default.createDirectory(atPath: workRoot, withIntermediateDirectories: true)
            let workPath = workRoot + "/wire.jsonl"
            try (try jsonLine(loopMirror) + "\n").write(toFile: workPath, atomically: true, encoding: .utf8)
            var workFiles: [String: TokenAggregator.FileScanState] = [:]
            _ = TokenAggregator.scan(roots: [workRoot], kimiOnly: false, into: &workFiles)
            try expect(workFiles.values.first.map(totals) == [35, 2], "initial loop-only work scan is wrong")
            let append = try FileHandle(forWritingTo: URL(fileURLWithPath: workPath))
            append.seekToEndOfFile()
            append.write(Data((try jsonLine(usageRecord) + "\n").utf8))
            try append.close()
            _ = TokenAggregator.scan(roots: [workRoot], kimiOnly: false, into: &workFiles)
            try expect(workFiles.values.first?.preferUsageRecord == true && workFiles.values.first.map(totals) == [35, 2],
                       "work format upgrade lost or doubled contributions")
            _ = TokenAggregator.scan(roots: [workRoot], kimiOnly: false, into: &workFiles)
            try expect(workFiles.values.first.map(totals) == [35, 2], "work record-only rescan is wrong")

            // 同一文件中的历史独有 loop 保留，镜像只计一次。
            let uniqueLoop: [String: Any] = ["type": "context.append_loop_event", "time": eventMS,
                                              "event": ["usage": ["inputOther": 7, "output": 1]]]
            var mixedHistory = TokenAggregator.FileScanState()
            try TokenAggregator.parseWorkLines([jsonLine(uniqueLoop), jsonLine(loopMirror), jsonLine(usageRecord)].joined(separator: "\n"), cutoffKey: "0000-00-00", into: &mixedHistory)
            try expect(totals(mixedHistory) == [42, 3], "unmirrored work history lost or mirror duplicated")
            var missingMixed = TokenAggregator.FileScanState()
            var missingTrusted = TokenAggregator.FileScanState()
            let missing = try jsonLine(["type": "usage.record", "time": eventMS, "usage": kimiUsage])
            TokenAggregator.parseLines(missing, kimiOnly: true, cutoffKey: "0000-00-00", into: &missingMixed)
            TokenAggregator.parseLines(missing, kimiOnly: true, cutoffKey: "0000-00-00", allowMissingModel: true, into: &missingTrusted)
            try expect(totals(missingMixed) == [0, 0] && totals(missingTrusted) == [35, 2]
                       && missingTrusted.modelDays[modelDayKey]?["未知模型"] == [35, 2],
                       "missing model source attribution wrong")
            try expect(mixedHistory.modelDays[modelDayKey]?["k3.1-pro"] == [35, 2]
                       && mixedHistory.modelDays[modelDayKey]?["未知模型"] == [7, 1],
                       "mirrored and legacy Work models were not reconciled")

            // 真实 Work 格式：请求带模型，step.end 不带模型，工具执行可让镜像延迟数分钟。
            func requestRow(_ model: String, _ step: String, _ ms: Double, kind: String = "loop") -> [String: Any] {
                ["type": "llm.request", "agentId": "main", "model": model,
                 "kind": kind, "turnStep": step, "time": ms]
            }
            func stepRow(_ step: Int, _ ms: Double) -> [String: Any] {
                ["type": "context.append_loop_event", "agentId": "main", "time": ms,
                 "event": ["type": "step.end", "turnId": "0", "step": step, "usage": kimiUsage]]
            }
            func parseWork(_ rows: [[String: Any]]) throws -> TokenAggregator.FileScanState {
                var result = TokenAggregator.FileScanState()
                try TokenAggregator.parseWorkLines(rows.map(jsonLine).joined(separator: "\n"), cutoffKey: "0000-00-00", into: &result)
                return result
            }
            let scopedRecord: [String: Any] = ["type": "usage.record", "agentId": "main",
                                               "time": eventMS, "usage": kimiUsage]
            let delayedRows = [requestRow("k3d1-agent", "0.1", eventMS - 1000), scopedRecord]
                + Array(repeating: ["type": "tool.finished", "agentId": "main"], count: 30)
                + [stepRow(1, eventMS + 480_000)]
            let delayedWork = try parseWork(delayedRows)
            try expect(totals(delayedWork) == [35, 2]
                       && delayedWork.modelDays[modelDayKey]?["k3d1-agent"] == [35, 2]
                       && delayedWork.modelDays[modelDayKey]?["未知模型"] == nil,
                       "request-scoped delayed mirror lost its model or was double-counted")
            let switchedWork = try parseWork([
                requestRow("k2d8-preview", "0.1", eventMS - 1000), stepRow(1, eventMS),
                requestRow("k3d1-agent", "0.2", eventMS + 1000), stepRow(2, eventMS + 2000)])
            try expect(totals(switchedWork) == [70, 4]
                       && switchedWork.modelDays[modelDayKey]?["k2d8-preview"] == [35, 2]
                       && switchedWork.modelDays[modelDayKey]?["k3d1-agent"] == [35, 2],
                       "loop-only model switching used a session-wide model")
            let subagentSummary: [String: Any] = ["type": "subagent.completed", "time": eventMS,
                                                  "usage": ["inputOther": 9999, "output": 999]]
            let summaryWork = try parseWork(delayedRows + [subagentSummary])
            try expect(totals(summaryWork) == [35, 2], "subagent summary was added to per-call Work usage")
            let differentStepWork = try parseWork([
                requestRow("k3d1-agent", "0.2", eventMS - 1000), scopedRecord, stepRow(1, eventMS + 480_000)])
            try expect(totals(differentStepWork) == [70, 4]
                       && differentStepWork.modelDays[modelDayKey]?["未知模型"] == [35, 2],
                       "different turn/step was attributed to the active request")
            let closeDifferentStep = try parseWork([
                requestRow("k3d1-agent", "0.2", eventMS - 1000), scopedRecord, stepRow(1, eventMS + 1)])
            try expect(totals(closeDifferentStep) == [70, 4], "nearby different steps were merged by legacy fallback")
            var otherAgentLoop = stepRow(1, eventMS + 1)
            otherAgentLoop["agentId"] = "agent-0"
            let otherAgentWork = try parseWork([
                requestRow("k3d1-agent", "0.1", eventMS - 1000), scopedRecord, otherAgentLoop])
            try expect(totals(otherAgentWork) == [70, 4]
                       && otherAgentWork.modelDays[modelDayKey]?["未知模型"] == [35, 2],
                       "different agents shared a model or mirror pairing")
            let compactionWork = try parseWork([
                requestRow("k3d1-agent", "", eventMS - 1000, kind: "compaction"), scopedRecord])
            try expect(totals(compactionWork) == [35, 2]
                       && compactionWork.modelDays[modelDayKey]?["k3d1-agent"] == [35, 2],
                       "unmirrored compaction usage was lost")
            // loop-only 文件的请求上下文跨两次刷新仍能用于归属，并替换旧模型缓存。
            let loopOnlyPath = workRoot + "/loop-only.jsonl"
            try (try jsonLine(requestRow("k2d8-preview", "0.1", eventMS - 1000)) + "\n")
                .write(toFile: loopOnlyPath, atomically: true, encoding: .utf8)
            _ = TokenAggregator.scan(roots: [workRoot], kimiOnly: false, into: &workFiles)
            let loopAppend = try FileHandle(forWritingTo: URL(fileURLWithPath: loopOnlyPath))
            loopAppend.seekToEndOfFile()
            loopAppend.write(Data((try jsonLine(stepRow(1, eventMS)) + "\n").utf8))
            try loopAppend.close()
            _ = TokenAggregator.scan(roots: [workRoot], kimiOnly: false, into: &workFiles)
            // 枚举器会将 /var 规范化为 /private/var。
            let loopOnlyKey = workFiles.keys.first { $0.hasSuffix("/loop-only.jsonl") }
            try expect(loopOnlyKey.flatMap { workFiles[$0]?.modelDays[modelDayKey]?["k2d8-preview"] } == [35, 2],
                       "request model context was lost across loop-only refreshes")
            try FileManager.default.removeItem(atPath: loopOnlyPath)
            if let loopOnlyKey { workFiles.removeValue(forKey: loopOnlyKey) }
            let oldJSON = Data("{\"work\":{},\"cli\":{}}".utf8)
            try expect((try? JSONDecoder().decode(TokenAggregator.ScanState.self, from: oldJSON)) != nil, "old cache cannot decode")

            // 三个窗口与模型明细共用数据源：今日 < 7 天 < 30 天，模型之和严格等于汇总。
            func offsetDay(_ days: Int) -> String {
                TokenAggregator.dayFmt.string(from: Date().addingTimeInterval(TimeInterval(days * 86400)))
            }
            var windowFile = TokenAggregator.FileScanState()
            windowFile.modelDays = [
                offsetDay(0): ["k3.1-pro": [60, 6], "未知模型": [40, 4]],
                offsetDay(-2): ["k3-256k": [20, 2]],
                offsetDay(-8): ["k3.1-pro": [30, 3]],
            ]
            let windows = TokenAggregator.buckets(["fixture": windowFile])
            try expect(windows.0.input == 100 && windows.0.output == 10
                       && windows.0.models["k3.1-pro"]?.total == 66 && windows.0.models["未知模型"]?.total == 44,
                       "today model breakdown does not reconcile")
            try expect(windows.1.input == 120 && windows.1.output == 12
                       && windows.1.models["k3-256k"]?.total == 22,
                       "seven-day model breakdown does not reconcile")
            try expect(windows.2.input == 150 && windows.2.output == 15
                       && windows.2.models["k3.1-pro"]?.input == 90 && windows.2.models["k3.1-pro"]?.output == 9,
                       "thirty-day model breakdown does not reconcile")

            // API 别名跨来源/旧缓存合并为四类，各窗口输入输出保持一致。
            var aliasFile = TokenAggregator.FileScanState()
            aliasFile.modelDays = [
                offsetDay(0): ["kimi-code/k3.1-pro": [10, 1], "k3.1-pro": [20, 2],
                               "kimi-code/k3-256k": [30, 3], "k3-256k": [40, 4],
                               "k3": [50, 5], "kimi-code/kimi-for-coding": [60, 6]],
                offsetDay(-2): ["kimi-code/k3.1-pro": [7, 1]],
                offsetDay(-8): ["kimi-code/kimi-for-coding": [3, 1]]
            ]
            let aliasWindows = TokenAggregator.buckets(["legacy-cache": aliasFile],
                extraModelDays: [offsetDay(0): ["kimi-code/k3.1-pro": [1, 1]]])
            try expect(aliasWindows.0.input == 211 && aliasWindows.0.output == 22
                       && aliasWindows.1.input == 218 && aliasWindows.1.output == 23
                       && aliasWindows.2.input == 221 && aliasWindows.2.output == 24,
                       "model alias merging changed window totals")
            for stat in [aliasWindows.0, aliasWindows.1, aliasWindows.2] {
                try expect(Set(stat.models.keys) == Set(["k3.1-pro", "k3-256k", "k3", "kimi-for-coding"])
                           && stat.models.values.reduce(0, { $0 + $1.input }) == stat.input
                           && stat.models.values.reduce(0, { $0 + $1.output }) == stat.output,
                           "model alias tree does not reconcile or distinct model IDs were merged")
            }
            try expect(aliasWindows.0.models["k3.1-pro"]?.input == 31
                       && aliasWindows.0.models["k3-256k"]?.input == 70
                       && TokenAggregator.normalizedModel(" KIMI-CODE/K3.1-PRO ") == "k3.1-pro"
                       && TokenAggregator.normalizedModel("kimi-code/k3.1-pro-highspeed") == "k3.1-pro-highspeed"
                       && TokenAggregator.modelDisplayName("kimi-code/k3.1-pro") == "K3.1 Pro"
                       && TokenAggregator.modelDisplayName("k3-256k") == "K3-256k"
                       && TokenAggregator.modelDisplayName("k3") == "K3"
                       && TokenAggregator.modelDisplayName("kimi-for-coding") == "Kimi for Coding",
                       "canonical model names or display names are wrong")

            // 相同用量隔数小时是两次调用；午夜附近的镜像仍能配对。
            func workRow(_ kind: String, _ ms: Double, _ id: String? = nil) -> [String: Any] {
                var row: [String: Any] = ["type": kind, "time": ms]
                if kind == "usage.record" { row["usage"] = kimiUsage }
                else { row["event"] = ["usage": kimiUsage] }
                if let id { row["request_id"] = id }
                return row
            }
            func workTotals(_ rows: [[String: Any]]) throws -> [Double] {
                var state = TokenAggregator.FileScanState()
                try TokenAggregator.parseWorkLines(rows.map(jsonLine).joined(separator: "\n"), cutoffKey: "0000-00-00", into: &state)
                return totals(state)
            }
            try expect((try? workTotals([workRow("context.append_loop_event", eventMS), workRow("usage.record", eventMS + 3 * 3600_000)])) == [70, 4], "distant independent calls were merged")
            let midnight = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000
            try expect((try? workTotals([workRow("context.append_loop_event", midnight - 1000), workRow("usage.record", midnight + 1000)])) == [35, 2], "cross-midnight mirror was not paired")
            try expect((try? workTotals([workRow("context.append_loop_event", eventMS, "request-1"), workRow("usage.record", eventMS + 3 * 3600_000, "request-1")])) == [35, 2], "matching request ID did not pair")
            try expect((try? workTotals([workRow("context.append_loop_event", eventMS, "request-1"), workRow("usage.record", eventMS + 1, "request-2")])) == [70, 4], "conflicting request IDs were paired")
            try expect((try? workTotals([workRow("context.append_loop_event", eventMS), workRow("usage.record", eventMS), workRow("usage.record", eventMS)])) == [70, 4], "one loop matched multiple records")
            // v6 旧修订的错误结果在文件未改变时也要重建，保留其他来源快照。
            var legacyWork = workFiles
            for key in legacyWork.keys {
                legacyWork[key]?.scanRevision = 2
                legacyWork[key]?.days = [TokenAggregator.dayFmt.string(from: Date()): [999, 999]]
                legacyWork[key]?.modelDays = [TokenAggregator.dayFmt.string(from: Date()): ["旧模型": [999, 999]]]
            }
            _ = TokenAggregator.scan(roots: [workRoot], kimiOnly: false, into: &legacyWork)
            try expect(legacyWork.values.first?.scanRevision == 4 && legacyWork.values.first.map(totals) == [35, 2]
                       && legacyWork.values.first?.modelDays.values.first?["旧模型"] == nil,
                       "v6 old revision was not rebuilt")

            let promaUsage: [String: Any] = ["input_tokens": 10, "cache_read_input_tokens": 20,
                                             "cache_creation_input_tokens": 5, "output_tokens": 3]
            let promaAssistant: [String: Any] = ["type": "assistant", "_createdAt": eventMS,
                                                 "message": ["model": "k3-256k", "usage": promaUsage]]
            let promaResult: [String: Any] = ["type": "result", "_createdAt": eventMS,
                                              "usage": ["input_tokens": 1000, "cache_read_input_tokens": 2000,
                                                        "cache_creation_input_tokens": 3000, "output_tokens": 400]]
            var promaFile = TokenAggregator.FileScanState()
            try TokenAggregator.parseLines([jsonLine(promaAssistant), jsonLine(promaResult)].joined(separator: "\n"),
                                           kimiOnly: true, cutoffKey: "0000-00-00", into: &promaFile)
            try expect(totals(promaFile) == [35, 3], "Proma result summary was counted as per-call usage")

            // SQLite 假库：ZCode 输入已含 cache，不能重复加；Hermes 换 key 不得重复回填。
            let sqlitePath = root.appendingPathComponent("client-usage.sqlite").path
            var testDB: OpaquePointer?
            try expect(sqlite3_open(sqlitePath, &testDB) == SQLITE_OK, "failed to create temporary usage db")
            defer { sqlite3_close(testDB) }
            func exec(_ sql: String) throws {
                try expect(sqlite3_exec(testDB, sql, nil, nil, nil) == SQLITE_OK, "temporary db SQL failed: \(sql)")
            }
            try exec("CREATE TABLE model_usage (model_id TEXT, input_tokens INTEGER, output_tokens INTEGER, started_at INTEGER)")
            let usageNow = Date()
            let nowSeconds = usageNow.timeIntervalSince1970
            let nowMS = Int64(nowSeconds * 1000)
            let oldMS = nowMS - Int64(40 * 86400 * 1000)
            try exec("INSERT INTO model_usage VALUES ('k3.1-pro', 100, 5, \(nowMS)), ('glm-5.3', 1000, 50, \(nowMS)), (NULL, 500, 50, \(nowMS)), ('k3-256k', 7, 1, \(oldMS))")
            let zcodeDays = TokenAggregator.scanZCode(at: sqlitePath, now: usageNow)
            let todayKey = TokenAggregator.dayFmt.string(from: usageNow)
            try expect(zcodeDays != nil && zcodeDays?[todayKey] == [100, 5],
                       "ZCode model filtering, cache accounting, or retention is wrong")
            var zState = TokenAggregator.ScanState()
            try expect(TokenAggregator.updateZCode(into: &zState, at: sqlitePath, now: usageNow), "initial ZCode read failed")
            try expect(!TokenAggregator.updateZCode(into: &zState, at: sqlitePath + ".missing", now: usageNow), "missing ZCode read succeeded")
            try expect(zState.zcodeDays?[todayKey] == [100, 5], "failed ZCode read lost snapshot")
            let beforeOther = [todayKey: [20.0, 0.0]]
            let afterOther = [todayKey: [30.0, 0.0]]
            try expect(TokenAggregator.mergeSourceDays(beforeOther, zState.zcodeDays ?? [:])[todayKey] == [120, 5] &&
                       TokenAggregator.mergeSourceDays(afterOther, zState.zcodeDays ?? [:])[todayKey] == [130, 5], "healthy source increment lost during ZCode failure")
            try exec("INSERT INTO model_usage VALUES ('k3.1-pro', 8, 2, \(nowMS))")
            try expect(TokenAggregator.updateZCode(into: &zState, at: sqlitePath, now: usageNow), "ZCode recovery failed")
            try expect(zState.zcodeDays?[todayKey] == [108, 7], "ZCode recovery double counted")
            try exec("INSERT INTO model_usage VALUES ('k3-256k', 7, 1, \(nowMS))")
            try expect(TokenAggregator.updateZCode(into: &zState, at: sqlitePath, now: usageNow), "ZCode model refresh failed")
            try expect(zState.zcodeDays?[todayKey] == [115, 8]
                       && zState.zcodeModelDays?[todayKey]?["k3.1-pro"] == [108, 7]
                       && zState.zcodeModelDays?[todayKey]?["k3-256k"] == [7, 1],
                       "ZCode model breakdown does not reconcile")
            let encodedZState = try ScanStateFile.encoded(zState)
            let decodedZState = try JSONDecoder().decode(TokenAggregator.ScanState.self, from: encodedZState)
            try expect(decodedZState.zcodeModelDays == zState.zcodeModelDays,
                       "model scan cache did not survive persistence")

            try exec("""
                CREATE TABLE session_model_usage (
                    session_id TEXT, model TEXT, billing_provider TEXT, billing_base_url TEXT,
                    billing_mode TEXT, task TEXT, input_tokens INTEGER, output_tokens INTEGER,
                    cache_read_tokens INTEGER, cache_write_tokens INTEGER, last_seen REAL
                )
                """)
            try exec("INSERT INTO session_model_usage VALUES ('s1', 'k3.1-pro', 'old', 'https://api.kimi.com/coding', '', 'main', 10, 1, 20, 0, \(nowSeconds))")
            var hermesScan = TokenAggregator.ScanState()
            try expect(TokenAggregator.scanHermes(into: &hermesScan, at: sqlitePath), "temporary hermes db was rejected")
            try expect(hermesScan.hermes?.days[todayKey] == [30, 1], "Hermes initial backfill is wrong")
            try exec("UPDATE session_model_usage SET billing_provider = 'new' WHERE session_id = 's1'")
            try expect(TokenAggregator.scanHermes(into: &hermesScan, at: sqlitePath), "Hermes rekey scan failed")
            try expect(hermesScan.hermes?.days[todayKey] == [30, 1], "Hermes rekey double-counted old contributions")
            try exec("UPDATE session_model_usage SET input_tokens = 15, output_tokens = 2 WHERE session_id = 's1'")
            try expect(TokenAggregator.scanHermes(into: &hermesScan, at: sqlitePath), "Hermes delta scan failed")
            try expect(hermesScan.hermes?.days[todayKey] == [35, 2], "Hermes cumulative delta is wrong")
            try exec("DELETE FROM session_model_usage WHERE session_id = 's1'")
            try expect(TokenAggregator.scanHermes(into: &hermesScan, at: sqlitePath), "Hermes delete scan failed")
            try expect(hermesScan.hermes?.days[todayKey] == nil, "deleted Hermes row left stale contributions")
            try exec("INSERT INTO session_model_usage VALUES ('s1', 'k3.1-pro', 'p', 'https://api.kimi.com/coding', '', 'main', 10, 1, 20, 0, \(nowSeconds))")
            try exec("INSERT INTO session_model_usage VALUES ('s2', 'k3-256k', 'p', 'https://api.kimi.com/coding', '', 'main', 5, 2, 5, 0, \(nowSeconds))")
            var hermesModels = TokenAggregator.ScanState()
            try expect(TokenAggregator.scanHermes(into: &hermesModels, at: sqlitePath), "Hermes model scan failed")
            try expect(hermesModels.hermes?.days[todayKey] == [40, 3]
                       && hermesModels.hermes?.modelDays[todayKey]?["k3.1-pro"] == [30, 1]
                       && hermesModels.hermes?.modelDays[todayKey]?["k3-256k"] == [10, 2],
                       "Hermes model breakdown does not reconcile")
            try exec("UPDATE session_model_usage SET model = 'k3.1-pro' WHERE session_id = 's2'")
            try expect(TokenAggregator.scanHermes(into: &hermesModels, at: sqlitePath), "Hermes model switch scan failed")
            try expect(hermesModels.hermes?.days[todayKey] == [40, 3]
                       && hermesModels.hermes?.modelDays[todayKey]?["k3.1-pro"] == [40, 3]
                       && hermesModels.hermes?.modelDays[todayKey]?["k3-256k"] == nil,
                       "Hermes model switch double-counted or retained stale model usage")

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

            // 更新检查与脚本都只认附件完整的 Release；最新空 Release 不遮挡最近可安装版本
            let completeRelease: [String: Any] = [
                "tag_name": "v1.4.0", "draft": false, "prerelease": false,
                "assets": [["name": "KimiUsage.zip"], ["name": "KimiUsage.zip.sha256"]],
            ]
            let emptyRelease: [String: Any] = [
                "tag_name": "v1.4.1", "draft": false, "prerelease": false, "assets": [],
            ]
            let zipOnlyRelease: [String: Any] = [
                "tag_name": "v1.4.2", "draft": false, "prerelease": false,
                "assets": [["name": "KimiUsage.zip"]],
            ]
            try expect(UpdateCheck.latestDownloadableTag(in: [emptyRelease, completeRelease]) == "v1.4.0",
                       "empty latest release hid downloadable release")
            try expect(UpdateCheck.latestDownloadableTag(in: [zipOnlyRelease]) == nil,
                       "release without SHA256 accepted")
            try expect(UpdateCheck.latestDownloadableTag(in: [emptyRelease]) == nil,
                       "release without assets accepted")
            var prerelease = completeRelease
            prerelease["prerelease"] = true
            try expect(UpdateCheck.latestDownloadableTag(in: [prerelease, completeRelease]) == "v1.4.0",
                       "prerelease not skipped")

            print("KimiUsage --self-test: PASS (strict quota parsing, per-window partial success, Kimi Work/Kimi Code/Proma dedup, ZCode/Hermes sqlite accounting, token window tree lines, refresh gate/schedule, credential merge/permissions/failure, kimi account line parsing, cache no-op, update check release version compare/assets)")
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

if CommandLine.arguments.contains("--tokens-once") {
    // 纯本地验收：不读凭据、不联网、不写扫描状态，只打印两类 token 统计。
    let detailed = TokenAggregator.aggregateBothDetailed(persist: false)
    if let e = detailed.workError { print("work tokens error: \(e)") }
    if let e = detailed.cliError { print("api tokens error: \(e)") }
    func printTokens(_ label: String, _ stats: (TokenStat, TokenStat, TokenStat)) {
        for (window, stat) in zip(["today", "7d", "30d"], [stats.0, stats.1, stats.2]) {
            print("\(label) \(window): in=\(Fmt.tokens(stat.input)) out=\(Fmt.tokens(stat.output)) total=\(Fmt.tokens(stat.total))")
        }
    }
    printTokens("work", detailed.work)
    printTokens("api", detailed.cli)
    exit(detailed.workError == nil && detailed.cliError == nil ? 0 : 1)
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
                                current.planName = r2.planName
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
                    current.planName = r.planName
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
    print("plan: \(snapshot.planName ?? "none")")
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
