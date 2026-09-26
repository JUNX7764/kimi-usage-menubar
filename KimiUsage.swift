import Cocoa
import Foundation
import SQLite3

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
    var monthError: String?
    var updatedAt: Date = Date()
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
    static let apiSessionsRoots = [
        NSHomeDirectory() + "/.kimi-code/sessions",
        NSHomeDirectory() + "/.proma/sdk-config/projects",
        NSHomeDirectory() + "/.proma/sdk-config/sessions",
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

    static let statePath = NSHomeDirectory()
        + "/Library/Application Support/KimiUsage/scan-state.json"
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

    private static func saveState() {
        guard let s = state,
              let data = try? JSONEncoder().encode(s) else { return }
        try? FileManager.default.createDirectory(
            atPath: (statePath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: statePath), options: [.atomic])
    }

    /// Kimi Work 本地会话统计
    static func aggregate() -> (TokenStat, TokenStat, TokenStat) {
        lock.lock(); defer { lock.unlock() }
        var st = loadState()
        scan(roots: [sessionsRoot], kimiOnly: false, into: &st.work)
        state = st
        saveState()
        return buckets(st.work)
    }

    /// API 客户端（CLI / Proma / Claude Code / hermes）中的 Kimi 用量统计
    static func aggregateCLI() -> (TokenStat, TokenStat, TokenStat) {
        lock.lock(); defer { lock.unlock() }
        var st = loadState()
        scan(roots: apiSessionsRoots, kimiOnly: true, into: &st.cli)
        scanHermes(into: &st)
        state = st
        saveState()
        return buckets(st.cli, extraDays: st.hermes?.days)
    }

    /// 增量扫描 roots 下的 jsonl：未变化文件只 stat，追加文件只读新增字节；
    /// 已被删除的文件从状态中剔除（旧全量逻辑下删除即不再计入，保持一致）
    private static func scan(roots: [String], kimiOnly: Bool,
                             into files: inout [String: FileScanState]) {
        let now = Date()
        let cutoff = now.addingTimeInterval(-retainSeconds)
        let cutoffKey = dayFmt.string(from: cutoff)
        var seen = Set<String>()
        var enumedRoots: [String] = []

        for root in roots {
            let rootURL = URL(fileURLWithPath: root)
            guard let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles])
            else { continue }
            enumedRoots.append(root)

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
        // （枚举失败的 root 不动，避免目录临时不可用时误清状态）
        for path in files.keys where !seen.contains(path)
            && enumedRoots.contains(where: { path.hasPrefix($0 + "/") }) {
            files.removeValue(forKey: path)
        }
    }

    // hermes 用量库（sqlite，只读打开，绝不写入）
    private static let hermesDBPath = NSHomeDirectory() + "/.hermes/state.db"

    /// hermes 的 Kimi 用量：只读查询 billing_base_url 指向 kimi.com / moonshot 的累计行
    /// （全表仅千余行、命中百余行，每次刷新一次查询开销可忽略，不新增定时器）；
    /// 与持久化的上次快照做差，delta 按 last_seen 归日。首次运行会把存量行的累计值
    /// 归入各自 last_seen 当天，相当于自动回填近 30 天窗口。
    private static func scanHermes(into st: inout ScanState) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(hermesDBPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
        else { return }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT session_id, model, billing_provider, billing_base_url, billing_mode, task,
                   input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, last_seen
            FROM session_model_usage
            WHERE billing_base_url LIKE '%kimi.com%' OR billing_base_url LIKE '%moonshot%'
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
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
        let d7Key = dayFmt.string(from: now.addingTimeInterval(-7 * 86400))
        let d30Key = dayFmt.string(from: now.addingTimeInterval(-30 * 86400))
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
        guard let data = FileManager.default.contents(atPath: path),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var cred = obj["credentials"] as? [String: Any],
              var web = cred["kimiWeb"] as? [String: Any],
              let rt = web["refreshToken"] as? String, !rt.isEmpty else {
            completion(nil); return
        }
        guard let url = URL(string: "https://www.kimi.com/api/auth/token/refresh") else {
            completion(nil); return
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "GET"
        req.setValue("Bearer \(rt)", forHTTPHeaderField: "Authorization")
        req.setValue("mac", forHTTPHeaderField: "x-msh-platform")
        req.setValue("3.1.2", forHTTPHeaderField: "x-msh-version")
        req.setValue("KimiUsage-Menubar/1.0", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            guard err == nil, let data = data,
                  let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let at = body["access_token"] as? String else {
                completion(nil); return
            }
            web["accessToken"] = at
            if let newRt = body["refresh_token"] as? String { web["refreshToken"] = newRt }
            web["updatedAt"] = ISO8601DateFormatter().string(from: Date())
            cred["kimiWeb"] = web
            obj["credentials"] = cred
            if let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
                try? out.write(to: URL(fileURLWithPath: path))
            }
            NSLog("[KimiUsage] web token self-refresh OK")
            completion(at)
        }.resume()
    }

    /// 5 小时 + 7 天窗口：kimi-code 用量接口
    static func fetchCodeUsage(apiKey: String, completion: @escaping (UsageData) -> Void) {
        var result = UsageData()
        guard let url = URL(string: "https://api.kimi.com/coding/v1/usages") else { return }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("KimiUsage-Menubar/1.0", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { completion(result) }
            guard err == nil, let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                result.fiveHourError = err?.localizedDescription ?? "bad response"
                return
            }
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                result.fiveHourError = "HTTP \(http.statusCode)"
                return
            }
            // 7 天窗口：usage.limit / remaining
            if let usage = obj["usage"] as? [String: Any] {
                let limit = Double(usage["limit"] as? String ?? "") ?? 0
                let remaining = Double(usage["remaining"] as? String ?? "") ?? 0
                if limit > 0 {
                    result.sevenDayUsed = max(0, min(1, (limit - remaining) / limit))
                    result.sevenDayReset = ISO.parse(usage["resetTime"] as? String)
                }
            }
            // 5 小时窗口：limits[] 中 window.duration == 300 分钟
            if let limits = obj["limits"] as? [[String: Any]] {
                for entry in limits {
                    guard let window = entry["window"] as? [String: Any],
                          let detail = entry["detail"] as? [String: Any] else { continue }
                    let dur = window["duration"] as? Int ?? 0
                    let unit = window["timeUnit"] as? String ?? ""
                    let isFiveHour = (unit == "TIME_UNIT_MINUTE" && dur == 300)
                        || (unit == "TIME_UNIT_HOUR" && dur == 5)
                    guard isFiveHour else { continue }
                    let limit = Double(detail["limit"] as? String ?? "") ?? 0
                    let used = Double(detail["used"] as? String ?? "") ?? 0
                    let remaining = Double(detail["remaining"] as? String ?? "") ?? 0
                    if limit > 0 {
                        let ratio = used > 0 ? used / limit : max(0, (limit - remaining) / limit)
                        result.fiveHourUsed = max(0, min(1, ratio))
                        result.fiveHourReset = ISO.parse(detail["resetTime"] as? String)
                    }
                }
            }
            if result.fiveHourUsed == nil && result.sevenDayUsed == nil {
                result.fiveHourError = "unexpected payload"
            }
        }.resume()
    }

    /// 本月总额度：Kimi 订阅接口（OMNI 余额）
    static func fetchMonthUsage(webToken: String, completion: @escaping (UsageData) -> Void) {
        var result = UsageData()
        let urlStr = "https://www.kimi.com/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscription"
        guard let url = URL(string: urlStr) else { return }
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
            if let balances = obj["balances"] as? [[String: Any]] {
                for b in balances where (b["feature"] as? String) == "FEATURE_OMNI" {
                    result.monthUsed = b["amountUsedRatio"] as? Double
                    result.monthReset = ISO.parse(b["expireTime"] as? String)
                }
            }
            if result.monthUsed == nil {
                result.monthError = "no omni balance"
            }
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
    static func time(_ d: Date?) -> String {
        guard let d = d else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f.string(from: d)
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
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }
    // token 数量缩写：999 / 12.3K / 1.23M
    static func tokens(_ v: Double) -> String {
        if v >= 1_000_000 { return String(format: "%.2fM", v / 1_000_000) }
        if v >= 10_000 { return String(format: "%.1fK", v / 1_000) }
        if v >= 1_000 { return String(format: "%.2fK", v / 1_000) }
        return String(format: "%.0f", v)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var usage = UsageData()
    private let launchAgentLabel = "com.local.kimi-usage"
    // 月度接口的 accessToken 寿命短，过期后由 KimiUsage 自己用 refreshToken 续期
    // （GET /api/auth/token/refresh，会轮换 refresh_token 并写回 config.json）。
    // 记录最后一次月度拉取成功时间，用于菜单标注过期数据。
    private var lastMonthSuccessAt: Date?
    private var monthFailCount = 0   // 月度拉取连续失败次数（偶发网络抖动不算故障）
    // 数据过期阈值：额度 10 分钟、token 统计 30 分钟——超过该时长未成功刷新即在 UI 标 ⚠️
    private let quotaStaleAfter: TimeInterval = 600
    private let tokensStaleAfter: TimeInterval = 1800
    // 两组数据各自的最后成功时间（5H/7D 服务端额度共用 quotaLastOK；token 统计本地扫描共用 tokensLastOK）
    private var quotaLastOK: Date?
    private var tokensLastOK: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[KimiUsage] launched, creating status item")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true
        rebuildMenu()
        renderBar()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // 拉取数据
    private func refresh() {
        let cred = CredStore.load()
        var merged = UsageData()
        let group = DispatchGroup()

        if let key = cred.codeApiKey, !key.isEmpty {
            group.enter()
            Fetcher.fetchCodeUsage(apiKey: key) { r in
                merged.fiveHourUsed = r.fiveHourUsed
                merged.fiveHourReset = r.fiveHourReset
                merged.sevenDayUsed = r.sevenDayUsed
                merged.sevenDayReset = r.sevenDayReset
                merged.fiveHourError = r.fiveHourError
                group.leave()
            }
        } else {
            merged.fiveHourError = "no api key"
        }

        if let token = cred.webToken, !token.isEmpty {
            group.enter()
            Fetcher.fetchMonthUsage(webToken: token) { r in
                if let err = r.monthError, err.contains("401") {
                    // accessToken 过期：自己用 refreshToken 续期后重试，不再唤起 Kimi 桌面端
                    Fetcher.refreshWebToken { newToken in
                        if let newToken = newToken {
                            Fetcher.fetchMonthUsage(webToken: newToken) { r2 in
                                merged.monthUsed = r2.monthUsed
                                merged.monthReset = r2.monthReset
                                merged.monthError = r2.monthError
                                group.leave()
                            }
                        } else {
                            merged.monthError = "HTTP 401（自刷新失败，请打开一次 Kimi 桌面端重新登录）"
                            group.leave()
                        }
                    }
                } else {
                    merged.monthUsed = r.monthUsed
                    merged.monthReset = r.monthReset
                    merged.monthError = r.monthError
                    group.leave()
                }
            }
        } else {
            merged.monthError = "no web token"
        }

        // 本地会话 token 统计（后台线程扫描 wire.jsonl）：Kimi Work + 独立 CLI
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let (t, w, m) = TokenAggregator.aggregate()
            merged.tokensToday = t
            merged.tokens7d = w
            merged.tokens30d = m
            let (ct, cw, cm) = TokenAggregator.aggregateCLI()
            merged.cliTokensToday = ct
            merged.cliTokens7d = cw
            merged.cliTokens30d = cm
            group.leave()
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            // 必须在旧值回填之前判定：本次新拉/新算到的值非 nil 才算成功、才推进 lastOK，
            // 由旧值回填得来的数据绝不更新 lastOK（否则断网时过期数据会被误标为新鲜）
            if merged.fiveHourUsed != nil || merged.sevenDayUsed != nil {
                self.quotaLastOK = Date()
            }
            // 会员月额度同样走网络拉取，lastMonthSuccessAt 即其 lastOK（口径同前，仅对齐到回填前）
            if merged.monthError == nil && merged.monthUsed != nil {
                self.lastMonthSuccessAt = Date()
                self.monthFailCount = 0
            } else if merged.monthError != nil {
                self.monthFailCount += 1
            }
            // token 统计为本地计算：后台扫描块每次刷新必回填，tokensToday 非 nil 即本次新算成功
            if merged.tokensToday != nil {
                self.tokensLastOK = Date()
            }
            // 网络瞬断（如睡眠唤醒）导致本次拉取失败时，保留上次成功的数据，
            // 避免菜单栏闪 "--"；错误提示逻辑已判断值为 nil 才显示，无需另清。
            let old = self.usage
            if merged.fiveHourUsed == nil {
                merged.fiveHourUsed = old.fiveHourUsed
                merged.fiveHourReset = old.fiveHourReset
            }
            if merged.sevenDayUsed == nil {
                merged.sevenDayUsed = old.sevenDayUsed
                merged.sevenDayReset = old.sevenDayReset
            }
            if merged.monthUsed == nil {
                merged.monthUsed = old.monthUsed
                merged.monthReset = old.monthReset
            }
            self.usage = merged
            self.renderBar()
            self.rebuildMenu()
        }
    }

    // 过期判定：距最后成功超过阈值即过期；有数据但 lastOK 为 nil（异常情况）也视为过期。
    // 无数据不算过期——菜单里本就显示"暂无数据"，无需再标注。
    private func isStale(_ lastOK: Date?, hasData: Bool, after: TimeInterval) -> Bool {
        guard hasData else { return false }
        guard let t = lastOK else { return true }
        return Date().timeIntervalSince(t) > after
    }
    private var quotaStale: Bool {
        isStale(quotaLastOK, hasData: usage.fiveHourUsed != nil || usage.sevenDayUsed != nil,
                after: quotaStaleAfter)
    }
    private var tokensStale: Bool {
        isStale(tokensLastOK, hasData: usage.tokensToday != nil || usage.tokens7d != nil
            || usage.tokens30d != nil || usage.cliTokensToday != nil
            || usage.cliTokens7d != nil || usage.cliTokens30d != nil, after: tokensStaleAfter)
    }

    // 已用量 → 余额（剩余比例）
    private func remaining(_ used: Double?) -> Double? {
        guard let used = used else { return nil }
        return max(0, min(1, 1 - used))
    }

    // 菜单栏显示：5H / 7D 两行堆叠（显示余额）；额度过期时两行加 ⚠️ 前缀
    // （5H/7D 同属服务端额度组，整组标注；token 组无菜单栏行，仅在下拉菜单标注）
    private func renderBar() {
        let staleQuota = quotaStale
        let line1 = (staleQuota ? "⚠️ " : "") + "5H \(Fmt.pct(remaining(usage.fiveHourUsed)))"
        let line2 = (staleQuota ? "⚠️ " : "") + "7D \(Fmt.pct(remaining(usage.sevenDayUsed)))"
        statusItem.button?.image = StackImage.make(line1: line1, line2: line2)
        statusItem.button?.title = ""
        // toolTip 显示最后成功时间而非渲染时间：断网时能直接看出数据有多旧
        statusItem.button?.toolTip = "Kimi 余额 · 额度最后成功 \(Fmt.lastOK(quotaLastOK))"
            + " · Token 最后成功 \(Fmt.lastOK(tokensLastOK))"
        writeStatus(line1: line1, line2: line2)
    }

    // 自诊断：把渲染内容和状态项可见性写到本地，便于排查
    private func writeStatus(line1: String, line2: String) {
        let dir = NSHomeDirectory() + "/Library/Application Support/KimiUsage"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var info: [String: Any] = [
            "line1": line1,
            "line2": line2,
            "updatedAt": Fmt.iso8601.string(from: Date()),
            // 两组数据的最后成功时间（ISO8601，无则空串）与过期标记
            "quotaLastOK": quotaLastOK.map { Fmt.iso8601.string(from: $0) } ?? "",
            "tokensLastOK": tokensLastOK.map { Fmt.iso8601.string(from: $0) } ?? "",
            "quotaStale": quotaStale,
            "tokensStale": tokensStale,
            "month": [
                "remaining": remaining(usage.monthUsed) ?? -1,
                "error": usage.monthError ?? "",
                "failCount": monthFailCount,
                "lastSuccessAt": lastMonthSuccessAt.map { ISO8601DateFormatter().string(from: $0) } ?? ""
            ],
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
        if let data = try? JSONSerialization.data(withJSONObject: info, options: .prettyPrinted) {
            try? data.write(to: URL(fileURLWithPath: dir + "/status.json"))
        }
        NSLog("[KimiUsage] rendered %@ / %@", line1, line2)
    }

    // 下拉面板
    private func rebuildMenu() {
        let menu = NSMenu()

        func info(_ title: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        }

        menu.addItem(info("Kimi 余额"))
        menu.addItem(.separator())

        let h5 = "5 小时余额：\(Fmt.pctLong(remaining(usage.fiveHourUsed)))"
            + (usage.fiveHourReset != nil ? "（\(Fmt.time(usage.fiveHourReset)) 重置）" : "")
        let d7 = "7 天余额：\(Fmt.pctLong(remaining(usage.sevenDayUsed)))"
            + (usage.sevenDayReset != nil ? "（\(Fmt.dayTime(usage.sevenDayReset)) 重置）" : "")
        var m30 = "本月总额度余额：\(Fmt.pctLong(remaining(usage.monthUsed)))"
            + (usage.monthReset != nil ? "（\(Fmt.dayTime(usage.monthReset)) 重置）" : "")
        // 月度值是拉取失败时保留的旧值：连续失败 ≥3 次才标注，避免续 token 空窗期抖动
        if usage.monthUsed != nil, let err = usage.monthError, monthFailCount >= 3 {
            let at = lastMonthSuccessAt.map { Fmt.dayTime($0) } ?? "更早"
            m30 += " ⚠️ 刷新失败（\(err)），数据停留在 \(at)"
        }
        menu.addItem(info(h5))
        menu.addItem(info(d7))
        menu.addItem(info(m30))

        // Token 用量（本地会话统计）
        menu.addItem(.separator())
        menu.addItem(info("Token 用量（Kimi Work 本地会话）"))
        func tokenLine(_ label: String, _ s: TokenStat?) -> String {
            guard let s = s, !s.isEmpty else { return "\(label)：暂无记录" }
            return "\(label)：入 \(Fmt.tokens(s.input)) · 出 \(Fmt.tokens(s.output)) · 计 \(Fmt.tokens(s.total))"
        }
        menu.addItem(info(tokenLine("今日", usage.tokensToday)))
        menu.addItem(info(tokenLine("近 7 天", usage.tokens7d)))
        menu.addItem(info(tokenLine("近 30 天", usage.tokens30d)))

        // Token 用量（API 客户端：Kimi Code CLI / Proma / Claude Code / hermes 中的 Kimi 用量）
        menu.addItem(.separator())
        menu.addItem(info("Token 用量（API 客户端 · 仅 Kimi 模型）"))
        menu.addItem(info(tokenLine("今日", usage.cliTokensToday)))
        menu.addItem(info(tokenLine("近 7 天", usage.cliTokens7d)))
        menu.addItem(info(tokenLine("近 30 天", usage.cliTokens30d)))

        if let e = usage.fiveHourError, usage.fiveHourUsed == nil {
            menu.addItem(info("5H/7D 获取失败：\(e)"))
        }
        if let e = usage.monthError, usage.monthUsed == nil {
            menu.addItem(info("月度获取失败：\(e)"))
        }

        // 数据过期提示：仅对应组过期时显示，紧贴更新时间行（两组独立判定）
        if quotaStale {
            menu.addItem(info("⚠️ 额度数据已过期 · 最后成功 \(Fmt.lastOK(quotaLastOK))"))
        }
        if tokensStale {
            menu.addItem(info("⚠️ Token 数据已过期 · 最后成功 \(Fmt.lastOK(tokensLastOK))"))
        }

        menu.addItem(.separator())
        menu.addItem(info("更新于 \(Fmt.time(usage.updatedAt))"))
        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "立即刷新", action: #selector(onRefresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let loginItem = NSMenuItem(title: "开机自启", action: #selector(onToggleLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = isLoginItemEnabled() ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(onQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: 开机自启（LaunchAgent）

    private var launchAgentPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(launchAgentLabel).plist"
    }

    private func isLoginItemEnabled() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentPath)
    }

    @objc private func onToggleLogin() {
        if isLoginItemEnabled() {
            try? FileManager.default.removeItem(atPath: launchAgentPath)
        } else {
            let exec = Bundle.main.executablePath ?? ""
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key><string>\(launchAgentLabel)</string>
                <key>ProgramArguments</key>
                <array><string>\(exec)</string></array>
                <key>RunAtLoad</key><true/>
                <key>KeepAlive</key><true/>
            </dict>
            </plist>
            """
            try? plist.write(toFile: launchAgentPath, atomically: true, encoding: .utf8)
        }
        rebuildMenu()
    }

    @objc private func onRefresh() { refresh() }

    @objc private func onQuit() { NSApp.terminate(nil) }
}

// MARK: - 入口（支持 --once 命令行自检）

if CommandLine.arguments.contains("--once") {
    // 命令行自检模式：拉一次数据打印后退出
    let cred = CredStore.load()
    let group = DispatchGroup()
    var merged = UsageData()
    if let key = cred.codeApiKey {
        group.enter()
        Fetcher.fetchCodeUsage(apiKey: key) { r in
            merged.fiveHourUsed = r.fiveHourUsed
            merged.fiveHourReset = r.fiveHourReset
            merged.sevenDayUsed = r.sevenDayUsed
            merged.sevenDayReset = r.sevenDayReset
            merged.fiveHourError = r.fiveHourError
            group.leave()
        }
    } else { print("no kimiCode apiKey found") }
    if let token = cred.webToken {
        group.enter()
        Fetcher.fetchMonthUsage(webToken: token) { r in
            if let err = r.monthError, err.contains("401") {
                Fetcher.refreshWebToken { newToken in
                    if let newToken = newToken {
                        Fetcher.fetchMonthUsage(webToken: newToken) { r2 in
                            merged.monthUsed = r2.monthUsed
                            merged.monthReset = r2.monthReset
                            merged.monthError = r2.monthError
                            group.leave()
                        }
                    } else {
                        merged.monthError = "HTTP 401（自刷新失败）"
                        group.leave()
                    }
                }
            } else {
                merged.monthUsed = r.monthUsed
                merged.monthReset = r.monthReset
                merged.monthError = r.monthError
                group.leave()
            }
        }
    } else { print("no kimiWeb token found") }
    _ = group.wait(timeout: .now() + 20)
    func rem(_ used: Double?) -> Double? { used.map { max(0, min(1, 1 - $0)) } }
    let (tt, tw, tm) = TokenAggregator.aggregate()
    print("menubar: 5H \(Fmt.pct(rem(merged.fiveHourUsed))) / 7D \(Fmt.pct(rem(merged.sevenDayUsed)))")
    print("5h remaining=\(Fmt.pctLong(rem(merged.fiveHourUsed))) reset=\(Fmt.dayTime(merged.fiveHourReset))")
    print("7d remaining=\(Fmt.pctLong(rem(merged.sevenDayUsed))) reset=\(Fmt.dayTime(merged.sevenDayReset))")
    print("month remaining=\(Fmt.pctLong(rem(merged.monthUsed))) reset=\(Fmt.dayTime(merged.monthReset))")
    print("tokens today: in=\(Fmt.tokens(tt.input)) out=\(Fmt.tokens(tt.output)) total=\(Fmt.tokens(tt.total))")
    print("tokens 7d:    in=\(Fmt.tokens(tw.input)) out=\(Fmt.tokens(tw.output)) total=\(Fmt.tokens(tw.total))")
    print("tokens 30d:   in=\(Fmt.tokens(tm.input)) out=\(Fmt.tokens(tm.output)) total=\(Fmt.tokens(tm.total))")
    let (ct, cw, cm) = TokenAggregator.aggregateCLI()
    print("api tokens today: in=\(Fmt.tokens(ct.input)) out=\(Fmt.tokens(ct.output)) total=\(Fmt.tokens(ct.total))")
    print("api tokens 7d:    in=\(Fmt.tokens(cw.input)) out=\(Fmt.tokens(cw.output)) total=\(Fmt.tokens(cw.total))")
    print("api tokens 30d:   in=\(Fmt.tokens(cm.input)) out=\(Fmt.tokens(cm.output)) total=\(Fmt.tokens(cm.total))")
    if let e = merged.fiveHourError { print("5h error: \(e)") }
    if let e = merged.monthError { print("month error: \(e)") }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // 不显示 Dock 图标
let delegate = AppDelegate()
app.delegate = delegate
app.run()
