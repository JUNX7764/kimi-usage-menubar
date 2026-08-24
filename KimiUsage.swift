import Cocoa
import Foundation

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

// MARK: - 本地会话 token 统计（扫描 daimon wire.jsonl）

enum TokenAggregator {
    static let sessionsRoot = NSHomeDirectory()
        + "/Library/Application Support/kimi-desktop/daimon-share/daimon/runtime/kimi-code/home/sessions"
    // API 客户端会话目录：独立 Kimi Code CLI + Proma / Claude Code（Claude SDK 可混接多家 API）
    // 注意：Proma 新版（≈2026-07）把 SDK 级会话日志从 sdk-config/projects 移到 sdk-config/sessions
    static let apiSessionsRoots = [
        NSHomeDirectory() + "/.kimi-code/sessions",
        NSHomeDirectory() + "/.proma/sdk-config/projects",
        NSHomeDirectory() + "/.proma/sdk-config/sessions",
        NSHomeDirectory() + "/.claude/projects"
    ]

    /// Claude SDK 客户端可经 ccswitch 接多家 API，按 model 字段甄别 Kimi；
    /// 无 model 字段的行默认计入（kimi-code 自有格式部分行无 model，且该客户端只接 Kimi）
    static func isKimiModel(_ model: String?) -> Bool {
        guard let m = model?.lowercased(), !m.isEmpty else { return true }
        if m.contains("kimi") || m.contains("moonshot") { return true }
        return m.hasPrefix("k") && m.count > 1 && m[m.index(after: m.startIndex)].isNumber
    }

    /// Kimi Work 本地会话统计
    static func aggregate() -> (TokenStat, TokenStat, TokenStat) {
        aggregate(roots: [sessionsRoot])
    }

    /// API 客户端（CLI / Proma / Claude Code）中的 Kimi 用量统计
    static func aggregateCLI() -> (TokenStat, TokenStat, TokenStat) {
        aggregate(roots: apiSessionsRoots, kimiOnly: true)
    }

    /// 返回 (今日, 近7天, 近30天)；无数据时各桶为 0
    static func aggregate(roots: [String], kimiOnly: Bool = false) -> (TokenStat, TokenStat, TokenStat) {
        var today = TokenStat(), week = TokenStat(), month = TokenStat()
        let now = Date()
        let todayStart = Calendar.current.startOfDay(for: now)
        let d7 = now.addingTimeInterval(-7 * 86400)
        let d30 = now.addingTimeInterval(-30 * 86400)

        for root in roots {
            let rootURL = URL(fileURLWithPath: root)
            guard let enumerator = FileManager.default.enumerator(
                at: rootURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            else { continue }

            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for line in text.split(separator: "\n", omittingEmptySubsequences: true)
                where line.contains("\"usage\"") {
                    guard let data = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    else { continue }
                    // 时间：kimi 系为 time(ms epoch)；Claude SDK 为 timestamp(ISO8601)
                    let t: Date
                    if let ms = obj["time"] as? Double {
                        t = Date(timeIntervalSince1970: ms / 1000)
                    } else if let ts = ISO.parse(obj["timestamp"] as? String) {
                        t = ts
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

                    if t >= d30 { month.input += input; month.output += output }
                    if t >= d7 { week.input += input; week.output += output }
                    if t >= todayStart { today.input += input; today.output += output }
                }
            }
        }
        return (today, week, month)
    }
}

enum ISO {
    static func parse(_ s: String?) -> Date? {
        guard let s = s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

// MARK: - 网络请求

enum Fetcher {

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
    // 月度接口的 accessToken 只有 ~15 分钟寿命，靠 Kimi 桌面端刷新；
    // 桌面端没在跑时接口会 401，此时静默保留旧值会把数据"冻"住（曾冻在 99.95% 一周）。
    // 记录最后一次月度拉取成功时间，用于菜单标注 + 触发自动恢复。
    private var lastMonthSuccessAt: Date?
    private var lastKimiRelaunchAt: Date?
    private var monthFailCount = 0   // 月度拉取连续失败次数（Kimi.app 续 token 有约 1 分钟空窗，偶发失败不算故障）

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
                merged.monthUsed = r.monthUsed
                merged.monthReset = r.monthReset
                merged.monthError = r.monthError
                group.leave()
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
            if merged.monthError == nil && merged.monthUsed != nil {
                self.lastMonthSuccessAt = Date()
                self.monthFailCount = 0
            } else if merged.monthError != nil {
                self.monthFailCount += 1
            }
            self.renderBar()
            self.rebuildMenu()
            // 月度接口 401 = accessToken 过期。Kimi.app 在跑时它会自动续 token（有 ~1 分钟空窗），
            // 只有桌面端没在跑才拉起它重试；连续失败 ≥3 次才认为是真故障
            if let err = merged.monthError, err.contains("401"), self.monthFailCount >= 3 {
                self.relaunchKimiDesktopAndRetry()
            }
        }
    }

    // 自动恢复：后台唤起 Kimi.app（其 daimon 会刷新 config.json 里的 token），25 秒后重试
    private func relaunchKimiDesktopAndRetry() {
        let now = Date()
        // 10 分钟内不重复唤起，避免每分钟的轮询把桌面端反复拉起
        if let last = lastKimiRelaunchAt, now.timeIntervalSince(last) < 600 { return }
        lastKimiRelaunchAt = now
        let url = URL(fileURLWithPath: "/Applications/Kimi.app")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        // Kimi.app 已在运行时它自己会续 token（过期后 ~1 分钟内），无需重复唤起
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.moonshot.kimichat").isEmpty {
            NSLog("[KimiUsage] Kimi.app already running, skip relaunch")
            return
        }
        NSLog("[KimiUsage] month token 401, relaunching Kimi.app to refresh token")
        let conf = NSWorkspace.OpenConfiguration()
        conf.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: conf) { _, err in
            if let err = err { NSLog("[KimiUsage] relaunch Kimi.app failed: \(err)") }
        }
        Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak self] _ in
            self?.refresh()
        }
    }

    // 已用量 → 余额（剩余比例）
    private func remaining(_ used: Double?) -> Double? {
        guard let used = used else { return nil }
        return max(0, min(1, 1 - used))
    }

    // 菜单栏显示：5H / 7D 两行堆叠（显示余额）
    private func renderBar() {
        let line1 = "5H \(Fmt.pct(remaining(usage.fiveHourUsed)))"
        let line2 = "7D \(Fmt.pct(remaining(usage.sevenDayUsed)))"
        statusItem.button?.image = StackImage.make(line1: line1, line2: line2)
        statusItem.button?.title = ""
        statusItem.button?.toolTip = "Kimi 余额 · 更新于 \(Fmt.time(usage.updatedAt))"
        writeStatus(line1: line1, line2: line2)
    }

    // 自诊断：把渲染内容和状态项可见性写到本地，便于排查
    private func writeStatus(line1: String, line2: String) {
        let dir = NSHomeDirectory() + "/Library/Application Support/KimiUsage"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var info: [String: Any] = [
            "line1": line1,
            "line2": line2,
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
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

        // Token 用量（API 客户端：Kimi Code CLI / Proma 等，API key 直连）
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
            merged.monthUsed = r.monthUsed
            merged.monthReset = r.monthReset
            merged.monthError = r.monthError
            group.leave()
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
