import AppKit
import Foundation

// MARK: - 入口（支持 --once 命令行自检）

let cliArgs = CommandLine.arguments.dropFirst()
if cliArgs.contains("--help") {
    print("""
    KimiUsage — Kimi 用量菜单栏工具（无参数启动常驻应用）

    用法:
      --self-test        离线回归自检（只用临时数据，不读凭据、不联网）
      --tokens-once      只统计本地 token（不读凭据、不联网、不写缓存）
      --once             拉一次线上额度 + 本地统计后退出（读凭据、联网、可能续期并写缓存）
      --visual-preview…  原生面板离线预览（子选项见 docs/DEVELOPMENT.md）
      --help             显示本说明
    """)
    exit(0)
}
// 未知旗标一律拒绝：静默拉起常驻 GUI 会让用户无从察觉拼写错误
let knownLongFlags: Set<String> = ["--self-test", "--tokens-once", "--once", "--help"]
if let unknown = cliArgs.first(where: {
    $0.hasPrefix("--") && !knownLongFlags.contains($0) && !$0.hasPrefix("--visual-preview")
}) {
    fputs("KimiUsage: 未知参数 \(unknown)（--help 查看用法）\n", stderr)
    exit(2)
}

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
        Fetcher.fetchMonthUsageWithRetry(webToken: token) { r in
            applyResult { current in
                current.monthUsed = r.monthUsed
                current.monthReset = r.monthReset
                current.planName = r.planName
                current.monthError = r.monthError
            }
        }
    } else { print("no kimiWeb token found") }
    // 月度 401 时存在 刷新→重试 串行链（每段最长 15s），45s 内应全部返回
    let timedOut = group.wait(timeout: .now() + 45) == .timedOut
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
    if let e = snapshot.sevenDayError { print("7d error: \(e)") }
    if let e = snapshot.monthError { print("month error: \(e)") }
    if timedOut { fputs("KimiUsage --once: 等待网络结果超时（45s），以上为部分数据\n", stderr) }
    exit(timedOut ? 1 : 0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // 不显示 Dock 图标
let delegate = AppDelegate()
app.delegate = delegate
app.run()
