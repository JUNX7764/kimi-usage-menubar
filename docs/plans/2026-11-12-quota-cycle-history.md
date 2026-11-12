# 额度周期回顾 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在「用量简析」下方新增「额度周期回顾」原生卡片，按真实观测到的 Kimi 7 天额度窗口比较 100% 上限与已用比例，回看是否用满、到期未用及异常窗口变化前的剩余。

**Architecture:** 新增独立的额度周期模型/纯状态机、凭据作用域隔离的持久化仓库和 AppKit 图表模块；`KimiUsage.swift` 只接入现有额度刷新与面板组装，不堆叠周期算法。复用现有 10 秒额度刷新，不新增轮询、不从本地 Token 数反推额度；保存可核对的观测证据，无法判定的起止时间、窗口变化原因和观测缺口明确标为未知。

**Tech Stack:** Swift / Foundation / CryptoKit / AppKit，现有 `AtomicJSONFile`，macOS 13+ arm64 构建（macOS 26+ SDK），Python unittest 驱动独立 Swift 夹具及原有 `--self-test`，@cua-driver-cli 原生交互验收。

---

## 0. 执行说明与边界

- 本文为待执行计划，不表示功能已经实现或测试已经通过。
- 基线：`16f2c7a`，2026-11-12 核对；实际实施前检查后续变动，使用下面的符号锚点而非机械依赖行号。
- 本计划位于独立 worktree，分支 `plan/quota-cycle-history-20261112`。当前只写计划，不构建、不安装、不提交、不推送或发布。
- 模板中的 `superpowers:*` 名称是原 Skill 约定；本工作区实际提供 `@executing-plans`，后续按该 Skill 分批执行，不安装或假装存在其他 Skill。
- 每个编号 Step 是一次 2–5 分钟动作；测试矩阵按一条用例一次推进。不得将整个 Task 当成一次未经验证的大修改。
- 各 Task 的 commit 命令是将来的检查点，只包含本任务文件。执行会话先运行 `git status --short`；用户要求不提交时保留检查点，不运行 commit。不得加入 Proma 归因。
- 本功能没有充值卡、主动用卡或已确认的被动提前重置业务。不得引入用卡请求、消费响应、operation ID 或自动重试。
- 首版只记录 **7 天额度窗口**；5 小时与月度额度不混入该历史。

### 0.1 已确认的产品方向

1. 新卡片顺序：用量进度 → 用量情况 → 用量简析 → **额度周期回顾** → 工具明细，共五张常规卡片。
2. 每轮两根柱：中性灰为额度上限 100%，`PanelAccent.codex.color` 为已用比例。虽然枚举名沿用 `codex`，Kimi 当前颜色是动态深蓝：浅色 `#204B80`、深色 `#85B5ED`；不得复制 CodexUsage 的暖橙色。
3. 结束原因只区分「正常到期」「窗口变化（原因未知）」「观测缺口」；进行中另有「窗口变化待确认」。不显示「主动用卡」「被动重置」或「提前重置」。
4. 正常到期显示「到期未用」；异常窗口变化显示「窗口变化前剩余」；进行中显示「当前剩余」。观测缺口不计算确定浪费。
5. 历史只展示观测百分比。接口虽有 `limit/remaining`，当前未验证其业务单位为 Token，不提供绝对 Token 上限或跨周期浪费总量。

### 0.2 交互默认值

- 每屏 **6 个周期**，默认最新一屏，当前轮次在最右；不足 6 个按实际数量显示，不填假历史。
- 首批浏览最近 **12 个周期**；「更早记录」继续扩展，不设置 12 个周期的存储上限。
- 使用左右翻页按钮，不在已有纵向滚动面板内新增横向滚动区域。
- 图内只显示精简开始日期，如 `11/06`；选中组的两行固定详情展示完整信息。
- 默认选中当前或最新轮次；悬停临时查看，点击固定选择，左右键逐组查看并跨页，移出恢复固定选择。
- 独立折叠，默认展开；刷新和关闭重开保留本进程选择/页位置，重启恢复最新页；凭据作用域切换立即清空旧展示。
- 卡片展开高度目标 **190pt，上限 210pt**；在真实 330pt 与窄屏 300pt 面板实测，不为达标压缩现有字号或其他卡片。

## 1. 当前代码地图

| 文件 / 符号 | 当前事实与修改目的 |
|---|---|
| `KimiUsage.swift:220` / `UsageData` | 7 天额度是 `0...1` 比例与可选 `reset`；没有历史，也没有已验证的绝对 Token 单位。 |
| `KimiUsage.swift:1230` / `Fetcher.parseCodeUsagePayload` | 从 `usage.limit/remaining/resetTime` 解析 7 天额度；无须扩大接口权限。 |
| `KimiUsage.swift:1282` / `Fetcher.fetchCodeUsage` | completion 给出来自本次请求的独立 `UsageData`；在这里捕获真实响应观测时刻。 |
| `KimiUsage.swift:26` / `AtomicJSONFile` | 可复用原子替换，文件默认 0600；新 Store 不另写通用原子保存算法。 |
| `KimiUsage.swift:71` / `RefreshGate` | 防止刷新轮次重叠，但没有账号代际；历史仍需自己的 scope + generation 防止迟到回调覆盖 UI。 |
| `KimiUsage.swift:1938` / `UsagePanelModel` | 增加已构造的历史快照，视图不得读磁盘、网络或凭据。 |
| `KimiUsage.swift:2030` / `PanelAccent` | 复用现有 Kimi 动态深蓝，不新增第二套主题。 |
| `KimiUsage.swift:2281` / `PanelCardView` | 当前圆角 14pt、水平/垂直内容边距 10pt，不是 Codex 的 12pt/8pt。 |
| `KimiUsage.swift:2543` / `UsagePanelController` | 面板宽 330pt、窄预览 300pt；新卡片状态加入现有控制器。 |
| `KimiUsage.swift:2763` / `rebuildContent` | 在 `DailyBriefSectionView` 与 `ToolBreakdownView` 之间插入历史卡片。 |
| `KimiUsage.swift:2984` / `verifyPreviewInteractions` | 扩展折叠和异步重建回归，不能破坏原有用量简析及滚动位置。 |
| `KimiUsage.swift:3600` 附近 / `DailyBarChartCanvas` | 参考整列命中、跟踪区、键盘与 VoiceOver；不要改造现有 30 日日图。 |
| `KimiUsage.swift:4057` / `AppDelegate` | 持有历史协调器；预览只能使用固定内存快照，不能创建真实历史仓库。 |
| `KimiUsage.swift:4140` / `performRefresh` | 捕获请求时间、凭据作用域和 generation；只将本次合法 7 天响应送入历史。 |
| `KimiUsage.swift:4658` / `configureVisualPreview` | 新增历史假数据、空态和事件测试；现有预览均不得读真实 UserDefaults 或写历史。 |
| `KimiUsage.swift:6294` 起 / 顶层入口 | 多文件编译前必须移到根目录 `main.swift`；不得留下第二个可执行入口。 |
| `build.sh` | 当前只编译 `KimiUsage.swift` 且 target 为 arm64；新增模块需显式列入，不做 universal/x86_64 改动。 |
| `tests/script_test.py` | PATH mock 脚本回归，不是原生图表验收。 |
| `docs/DEVELOPMENT.md`、`docs/project/02-architecture.md`、`07-standards.md` | 当前构建、权限、面板与验证边界。 |

## 2. 数据口径与状态机

### 2.1 轮次不是日历周

- “7 天”是接口窗口类别，不保证每个展示轮次都完整持续七天。
- 首次启动时，`resetAt - 604800` 只是**推算开始时间**；视图标记「开始时间推算」或「首次观测」。
- 事件发生在两次成功请求之间时只记录边界区间，不能把约四天写成精确四天。
- 关机跨过一个或多个周期，不生成未观测的零用量柱；旧段记观测缺口，新段标记缺口后的首次观测。
- API 返回过去的 reset 且尚未给出新窗口时显示「等待窗口更新」，不按本机时钟自动生成新周期。

### 2.2 用量与剩余

业务字段必须使用 `lastObservedUsedPercent` / `remainingAtLastObservation`，不能命名为 `finalUsed` / `wastedTokens`。

- 进行中：`已用 36% · 当前剩余 64%`。
- 正常到期但未采到终点：`最后观测已用 81% · 到期未用约 19%`，详情带最后成功时刻。
- 异常窗口变化：`最后观测已用 72% · 窗口变化前剩余约 28%`，不解释变化原因。
- 已观测原始值等于 100 才可标「已用满」；展示四舍五入到 100 的 99.6 不算真正用满。
- 首次观测发生在中途仍可展示接口累计百分比，但标记记录不完整。
- 时间回拨、百分比回修、reset 缺失或变化不能默默解释为正常到期。
- 不提供跨周期百分比相加、平均利用率或绝对浪费 KPI。

### 2.3 本地启发式参数

```swift
struct QuotaCyclePolicy {
    var resetJitter: TimeInterval = 120
    var meaningfulDrop: Double = 1            // 个百分点，仅作候选信号
    var confirmationMinDelay: TimeInterval = 10
    var confirmationMaxDelay: TimeInterval = 180
    var maximumContinuousGap: TimeInterval = 15 * 60
    var heartbeatInterval: TimeInterval = 5 * 60
}
```

参数通过实例注入，测试不依赖真实 `Date()` 或 `sleep`。这些是本地判定参数，不是 Kimi 服务端保证；上线文案不得宣称能百分之百识别窗口变化。

### 2.4 状态转移决策表

| 前后观测 | 处理 |
|---|---|
| 同一 reset、比例不减 | 更新当前轮次，重复请求不加轮次。 |
| reset 仅漂移 ≤120s | 同轮，保留原始时刻和轮次 ID。 |
| 比例下降但 reset 未明显变化 | 保留异常候选，不立刻拆段；详情「额度回修／窗口变化待确认」。 |
| reset 明显变化但比例不降 | 记时间变化候选；不直接判正常或异常结束。 |
| 原截止尚未到，reset 明显变化且比例下降 ≥1pp | 第一笔为候选；下一独立请求在 10–180s 内确认同一新窗口且不回到旧值，才拆段，原因「窗口变化（原因未知）」。 |
| 候选下一笔回到旧窗口 | 撤销候选，保留异常证据，不留下伪造的已结束轮次。 |
| 正常越过旧截止，新 reset 明显向后、采样间隔 ≤15 分钟 | 用第二笔新窗口样本确认自然轮换；即使 0→0 也可判正常到期，边界保留观测区间。 |
| 两笔间隔 >15 分钟且窗口已变化 | 旧段为 gap，新段开始未知；不推断漏过几轮。 |
| 时间回拨、非有限值、越界百分比、缺 reset、请求失败 | 不进入已确认状态机，不制造 0%/100% 记录。 |
| 凭据作用域变化、旧 generation、乱序 requestStartedAt | 拒绝样本或旧 UI 回调，不写入新作用域。 |

没有重置卡事件分支。窗口变化只是接口观测事实，不归因于官方、用户或第三方操作。

## 3. 文件与接口契约

### 新文件

- `Sources/QuotaCycleHistory.swift`：Foundation 模型、参数、候选/确认状态机、浏览窗口和详情语义。
- `Sources/QuotaCycleStore.swift`：凭据作用域派生、分区路径、版本校验、原子保存和失败回退。
- `Sources/QuotaCycleCoordinator.swift`：串行队列、作用域代际、读写协调和 UI 快照回调。
- `Sources/QuotaCycleHistoryView.swift`：AppKit 绘制与交互；不依赖磁盘、URLSession 或凭据。
- `main.swift`：从 `KimiUsage.swift` 移出的唯一顶层可执行入口。
- `tests/quota_cycle_history_test.py`：编译一次轻量 Swift runner，按 case 名执行。
- `tests/fixtures/quota-cycle-history/main.swift`：纯模型/持久化 runner 与假数据。
- `docs/project/17-quota-cycle-history.md`：实施后的现行功能口径。
- `docs/verification/2026-11-12-quota-cycle-history.md`：实际验收日期不同时使用真实日期。

### 核心值类型

```swift
import Foundation

struct QuotaObservation: Codable, Equatable {
    let requestStartedAt: Date
    let observedAt: Date
    let usedPercent: Double
    let resetAt: Date

    var isValid: Bool {
        requestStartedAt <= observedAt && usedPercent.isFinite
            && (0...100).contains(usedPercent)
            && resetAt.timeIntervalSince1970.isFinite
            && observedAt.timeIntervalSince1970.isFinite
            && requestStartedAt.timeIntervalSince1970.isFinite
    }
}

enum QuotaCycleEnd: String, Codable {
    case natural, windowChanged, gap
}

enum QuotaCycleStart: String, Codable {
    case inferred, observedTransition, afterGap
}

struct QuotaCycleRecord: Codable, Equatable, Identifiable {
    let id: UUID
    var startKind: QuotaCycleStart
    var inferredStartAt: Date?
    var firstObservedAt: Date
    var expectedResetAt: Date
    var lastObservedAt: Date
    var lastObservedUsedPercent: Double
    var boundaryLower: Date?
    var boundaryUpper: Date?
    var end: QuotaCycleEnd?
    var incomplete: Bool
    var evidence: [QuotaObservation]

    var remainingAtLastObservation: Double {
        max(0, min(100, 100 - lastObservedUsedPercent))
    }
    var wasObservedFull: Bool { lastObservedUsedPercent == 100 }
}
```

`QuotaCycleState` 包含 `schemaVersion=1`、已结束记录、current、上一有效观测、pendingTransition 和最近接收的 requestStartedAt。候选包含原轮次 ID、第一笔新样本、候选原因和待确认标记。首版不增加数据库、云同步、重置事件或通用事件总线。

### 生产接口

```swift
struct QuotaCycleReducer {
    init(policy: QuotaCyclePolicy)
    func ingest(_ sample: QuotaObservation, into state: inout QuotaCycleState)
}

final class QuotaCycleStore {
    typealias Writer = (Data, URL) throws -> Void
    init(root: URL, writer: @escaping Writer)
    func scopeKey(apiKey: String) throws -> String
    func load(scopeKey: String) throws -> QuotaCycleState
    func save(_ state: QuotaCycleState, scopeKey: String) throws
}

final class QuotaCycleCoordinator {
    init(root: URL, writer: @escaping QuotaCycleStore.Writer,
         deliver: @escaping (QuotaCycleSnapshot) -> Void)
    func activate(apiKey: String, generation: Int)
    func observe(_ sample: QuotaObservation, apiKey: String, generation: Int)
}
```

## Task 1：建立模型、轻量 runner 与同窗口逻辑

**Files:**
- Create: `Sources/QuotaCycleHistory.swift`
- Create: `tests/quota_cycle_history_test.py`
- Create: `tests/fixtures/quota-cycle-history/main.swift`

**Step 1: 写首个失败测试。** Python `setUpClass` 在 `TemporaryDirectory()` 编译一次 runner，各测试启动 `runner firstObservation`；非零退出即失败，不读取 HOME。

```bash
swiftc Sources/QuotaCycleHistory.swift tests/fixtures/quota-cycle-history/main.swift -o "$TEMP_RUNNER"
```

Swift runner 使用固定 epoch 和自定义 `check`：

```swift
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
var state = QuotaCycleState()
let reducer = QuotaCycleReducer(policy: QuotaCyclePolicy())
reducer.ingest(sample(0, 43), into: &state)
check(state.current != nil, "first sample must create current")
check(state.current?.lastObservedUsedPercent == 43, "used percentage must survive")
check(state.current?.remainingAtLastObservation == 57, "remaining is percentage")
check(state.current?.startKind == .inferred, "first start is inferred")
check(state.closed.isEmpty, "must not fabricate old cycles")
print("PASS: firstObservation")
```

runner 用 `switch CommandLine.arguments[1]` 分派，每个 case 独立初始化。

**Step 2: 运行并确认因模块尚不存在而失败。**

```bash
python3 -m unittest discover -s tests -p 'quota_cycle_history_test.py' -v
```

预期：编译失败；不得涉及真实凭据或网络。

**Step 3: 实现值类型和最小 ingest。** 首样本创建 current，同窗口更新最后观测；保留首次推算标记，不实现窗口拆分。

**Step 4: 逐条加入测试并运行。** 覆盖同轮增长、完全重复、reset ±30s/±120s、NaN/无穷、-1/101、缺 reset 的接入层拒绝、乱序 requestStartedAt；记录 ID 稳定且 closed 不增加。原始下降不得用 `max(used)` 掩盖。

**Step 5: Commit。**

```bash
git add Sources/QuotaCycleHistory.swift tests/quota_cycle_history_test.py tests/fixtures/quota-cycle-history/main.swift
git commit -m "feat: model Kimi quota cycle observations"
```

## Task 2：实现自然轮换、异常窗口变化与观测缺口

**Files:**
- Modify: `Sources/QuotaCycleHistory.swift`
- Modify: `tests/quota_cycle_history_test.py`
- Modify: `tests/fixtures/quota-cycle-history/main.swift`

**Step 1: 写自然到期和异常变化失败用例。** 至少包含：

```swift
var changed = QuotaCycleState()
reducer.ingest(sample(0, 72), into: &changed)
reducer.ingest(sample(100, 2, 605800), into: &changed)
check(changed.closed.isEmpty && changed.pendingTransition != nil,
      "new window needs independent confirmation")
reducer.ingest(sample(120, 3, 605800), into: &changed)
check(changed.closed.count == 1, "stable new window splits once")
check(changed.closed[0].end == .windowChanged, "reason remains unknown")
check(changed.closed[0].lastObservedUsedPercent == 72,
      "do not overwrite old use with new-window value")
check(changed.current?.lastObservedUsedPercent == 3,
      "new current uses new window")
```

另写 reset 仅移动 100s 不拆段、自然到期后 0→0 可确认两个独立 case。

**Step 2: 运行新增 case，确认当前实现不能正确拆分。**

```bash
python3 -m unittest discover -s tests -p 'quota_cycle_history_test.py' -v
```

**Step 3: 按 §2.4 实现候选状态机。** 确认样本必须有不同 requestStartedAt；同笔重放不充当第二次确认。旧段在第一笔新窗口样本之前封存，不能累计新窗口百分比。

**Step 4: 一次补一条矩阵测试。** 必测：自然到期 0→0、reset 回拨、仅比例回修、仅 reset 移动、候选回滚、超过 180s、同笔重放、跨三周只产生 gap、首次安装中途、99.6 不算用满。断言 UI 文案只有自然到期、窗口变化原因未知和 gap，不出现用卡或被动重置。

**Step 5: Commit。**

```bash
git add Sources/QuotaCycleHistory.swift tests/quota_cycle_history_test.py tests/fixtures/quota-cycle-history/main.swift
git commit -m "feat: detect Kimi quota transitions conservatively"
```

## Task 3：凭据作用域隔离与版本化持久化

**Files:**
- Create: `Sources/QuotaCycleStore.swift`
- Modify: `tests/quota_cycle_history_test.py`
- Modify: `tests/fixtures/quota-cycle-history/main.swift`

**Step 1: 写 round-trip、作用域隔离和写入失败测试。** 所有 I/O 在 `TemporaryDirectory()`；writer 注入失败，不读真实 Application Support 或 Kimi 配置。

**Step 2: 运行并确认 Store 尚不存在而失败。**

```bash
python3 -m unittest discover -s tests -p 'quota_cycle_history_test.py' -v
```

**Step 3: 实现凭据作用域派生。** Kimi 当前没有可靠的服务端稳定用户 ID，且账号接口是 5 分钟慢轮；历史分区直接使用本次 7 天额度请求对应的 Kimi Code API Key 派生，不依赖昵称或打码手机号：

- root 下创建 32 字节随机 `scope-salt`，权限 0600；salt 不是凭据，但不能提交到仓库。
- `scopeKey = SHA256("kimi-quota-cycle-v1\0" + salt + UTF8(apiKey))` 的固定长度 hex；使用 CryptoKit，不保存原始 key，也不保存无盐哈希。
- 路径为 `<root>/<scopeKey>/history-v1.json`；创建后显式校验/修正 root 与分区目录为 0700、文件为 0600（不能依赖 `AtomicJSONFile` 的默认目录权限），只接受固定长度 hex，拒绝 `../`。
- API Key 轮换或切换账号会进入新分区并从头记录，宁可暂时看不到旧历史，也不能串账号；该限制写入用户文档。
- 派生失败只禁用历史，不阻断现有额度展示。

**Step 4: 实现版本化 JSON 和原子保存。** 生产根目录为 `~/Library/Application Support/KimiUsage/quota-history/`，生产 writer 调用 `AtomicJSONFile.replace(data, at: path, mode: 0o600)`。JSON 不含 API Key、salt、token、昵称、手机号、URL header 或原始响应。校验 schemaVersion、有限数值、UUID、时间顺序和重复 ID；不存在返回空状态，损坏/未来 schema 保留原文件且不得自动覆盖。

**Step 5: 实现去重和写入频率。** 仅在首次、百分比/状态变化、有效窗口变化或五分钟心跳保存；重复样本不增长 evidence，心跳不追加等值记录。候选/确认/回滚不得被心跳压缩掉。写失败保留最后成功磁盘状态，本进程继续观测，UI 显示「历史未保存」，下次成功清除。

**Step 6: 运行测试并检查权限。** 断言 writer 次数、重启恢复候选、损坏文件不变、未来版本不降级覆盖、两个假 API Key 分区互斥、salt/key 不出现在 JSON、文件权限正确。

**Step 7: Commit。**

```bash
git add Sources/QuotaCycleStore.swift tests/quota_cycle_history_test.py tests/fixtures/quota-cycle-history/main.swift
git commit -m "feat: persist credential-scoped Kimi quota history"
```

## Task 4：串行协调器与稳定浏览模型

**Files:**
- Create: `Sources/QuotaCycleCoordinator.swift`
- Modify: `Sources/QuotaCycleHistory.swift`
- Modify: `tests/quota_cycle_history_test.py`
- Modify: `tests/fixtures/quota-cycle-history/main.swift`

**Step 1: 写作用域切换、迟到加载和翻页测试。** 用 expectation/semaphore 等明确完成信号，不靠 sleep；浏览输入覆盖 0/1/5/6/7/12/13/25 个稳定 ID。

**Step 2: 运行并确认协调器/浏览模型缺失而失败。**

```bash
python3 -m unittest discover -s tests -p 'quota_cycle_history_test.py' -v
```

**Step 3: 实现串行队列和代际。** load → reduce → persist 在单一 utility 串行队列；交付主线程前核对 scopeKey 与 generation。旧作用域可以保存到自己的分区，但绝不覆盖新作用域 UI。AppDelegate 在本进程比较当前 API Key 与上一轮 key，变化时递增 generation 并立即清空旧快照；原始 key 只在内存比较，不写日志或磁盘。

**Step 4: 实现 `QuotaCycleBrowser`。** newest 页含最新 `min(6,n)` 条，按旧到新排列；翻页每次 6 条，首批上限 12，`loadEarlier()` 每次扩展 12。使用 selectedCycleID 与页锚点，不持有易过期下标。

```swift
func visibleRange(total: Int, olderPage: Int, pageSize: Int = 6) -> Range<Int> {
    let safeTotal = max(0, total)
    let safeSize = max(1, pageSize)
    let maxPage = max(0, (safeTotal - 1) / safeSize)
    let page = min(max(0, olderPage), maxPage)
    let upper = max(0, safeTotal - page * safeSize)
    return max(0, upper - safeSize)..<upper
}
```

25 条默认索引 19..<25，前一页 13..<19。查看历史页时新记录到达不跳回最新；切换凭据作用域才重置。

**Step 5: Commit。**

```bash
git add Sources/QuotaCycleCoordinator.swift Sources/QuotaCycleHistory.swift tests/quota_cycle_history_test.py tests/fixtures/quota-cycle-history/main.swift
git commit -m "feat: coordinate scoped history updates and cycle paging"
```

## Task 5：拆分唯一入口并接入现有额度刷新

**Files:**
- Create: `main.swift`
- Modify: `KimiUsage.swift` / 顶层入口、`UsagePanelModel`、`AppDelegate`、`performRefresh`、`configureVisualPreview`、`KimiOfflineRegression`
- Modify: `build.sh`

**Step 1: 写离线集成失败断言。** 在临时 root 注入协调器与假 `UsageData`：本次 7 天为 nil 但旧 usage 存在时不入账；缺 reset 不入账；旧 generation 拒绝；A/B key 不串历史；预览不创建真实 history 目录。

**Step 2: 移动顶层入口并更新构建。** 将 `KimiUsage.swift` 底部从 `let cliArgs = ...` 到 `app.run()` 的完整块原样移到根目录 `main.swift`，从原文件删除。`build.sh` 显式编译三个非 UI 新模块、`KimiUsage.swift` 和 `main.swift`：

```bash
swiftc -O -target arm64-apple-macos13.0 -o "$DIR/KimiUsage-bin" \
  "$DIR/Sources/QuotaCycleHistory.swift" \
  "$DIR/Sources/QuotaCycleStore.swift" \
  "$DIR/Sources/QuotaCycleCoordinator.swift" \
  "$DIR/KimiUsage.swift" \
  "$DIR/main.swift"
```

不得使用全目录通配符，不改变 arm64、macOS 13 部署目标或 macOS 26+ SDK 门禁。

**Step 3: 构建并运行自检，确认新增历史断言按预期失败。**

```bash
./build.sh
./KimiUsage.app/Contents/MacOS/KimiUsage --self-test
```

**Step 4: 接入协调器与样本 gate。** 非预览 AppDelegate 创建协调器；预览只注入固定内存快照。每轮 `performRefresh` 在请求前记录 `requestStartedAt`、本轮 API Key 的内存代际；在 `fetchCodeUsage` completion 内记录 `observedAt = Date()`，仅当本次 `r.sevenDayUsed`、`r.sevenDayReset` 合法且 `sevenDayError == nil` 时构造 `usedPercent = ratio * 100`。不得从 `group.notify` 的 merged 旧值补样本，不等待月度、套餐、账号或本地扫描。

历史回调在主线程只更新 typed snapshot 并调用 `rebuildMenu()`；不要调用 `renderBar()` 或 `writeStatus()`，避免无关诊断写入。作用域变化立即显示中性「读取历史」，不得短暂显示上一账号数据。

**Step 5: 运行完整离线回归。**

```bash
./build.sh
./KimiUsage.app/Contents/MacOS/KimiUsage --self-test
python3 -m unittest discover -s tests -p '*_test.py' -v
bash -n build.sh scripts/update.sh scripts/release.sh
```

预期全部通过；不得运行 `--once` 或读取真实凭据。

**Step 6: Commit。**

```bash
git add KimiUsage.swift main.swift build.sh Sources/QuotaCycleHistory.swift Sources/QuotaCycleStore.swift Sources/QuotaCycleCoordinator.swift
git commit -m "feat: capture Kimi quota history from accepted refreshes"
```

## Task 6：实现 Kimi 窄面板双柱卡片

**Files:**
- Create: `Sources/QuotaCycleHistoryView.swift`
- Modify: `KimiUsage.swift` / `UsagePanelModel`、`UsagePanelController.rebuildContent`、预览几何断言
- Modify: `build.sh`

**Step 1: 添加固定数据和失败几何断言。** 固定 13+ 轮次，包含 natural/full、natural/81%、windowChanged/72%、gap、current/36% 和 pending；在 330pt/300pt 面板断言六组不重叠、不超边、每组两柱、详情固定高度、卡片位于用量简析之后。

**Step 2: 构建预览并确认卡片缺失/断言失败。** 此时允许新增断言 FAIL，不得把文字检查当作画面通过。

**Step 3: 实现 AppKit 视图。** 以 `QuotaCycleHistorySectionView` 为根，包含图表、分页按钮、固定详情和 notices；主文件用现有 `PanelCardView(containing:)` 包装。`PanelUI` 为 private，新模块使用自己的少量 NSStackView/NSTextField 布局，不为复用扩大整个主文件访问权限。

```text
额度周期回顾                       折叠箭头
上限 / 已用的小图例       ‹  最近 6 个  ›
[6 组 × 灰上限柱 + Kimi 蓝已用柱，纵轴 0–100%]
[6 个精简开始日期，当前组浅色高亮]
11/06–11/10（约） · 窗口变化（原因未知）
最后观测已用 72% · 窗口变化前剩余约 28%
```

- 图高建议 96pt（含日期），详情两行 32–36pt；按实际 bounds 计算列宽，不用宽幅示意图坐标。
- 上限轴统一标 100%，灰柱用动态 `.secondaryLabelColor` 适当透明度；已用柱及选择底色复用 `PanelAccent.codex.color`。
- 零值显示低基线；缺失显示占位/斜线，不画成零柱。
- 候选未确认时不新增已确认历史柱；当前详情显示「窗口变化待确认」。
- gap 不展示确定到期未用百分比；写盘失败显示「历史未保存」；空态显示「从首次成功读取 7 天额度后开始记录」。
- 不足六条仍保持固定卡片高度。保持现有 14pt 圆角、10pt 边距、无阴影，并确保三种背景样式与降低透明度下可读。

**Step 4: 将 UI 文件加入 `build.sh`，运行预览几何和原有自检。** 检查浅/深色、空态、短/长历史、330/300 宽度不溢出；固定数据预览不等于真实账号历史正确。

**Step 5: Commit。**

```bash
git add Sources/QuotaCycleHistoryView.swift KimiUsage.swift build.sh
git commit -m "feat: add Kimi quota cycle history card"
```

## Task 7：选择、翻页、折叠与辅助功能

**Files:**
- Modify: `Sources/QuotaCycleHistoryView.swift`
- Modify: `KimiUsage.swift` / `UsagePanelController` 状态、`verifyPreviewInteractions`、预览事件测试
- Modify: `tests/fixtures/quota-cycle-history/main.swift`

**Step 1: 写交互失败断言。** 覆盖鼠标跨六列（含柱间空白）、点击固定、移出恢复、方向键边界/跨页、13 条更早记录、折叠重开、刷新保持 selectedID、作用域切换重置。直接调用 handler 不能冒充真实点击验收。

**Step 2: 运行 `--visual-preview --visual-preview-quota-history --visual-preview-test`，确认新增断言失败。** 该旗标由本任务实现，不是当前已有能力。

**Step 3: 实现交互。** 命中按整列；悬停和选择不发网络、不写盘。页码/展开状态存于 `UsagePanelController` 或独立 UI state，以稳定 ID 保存，不能藏进每次重建即销毁的 view。VoiceOver 提供开始精度、结束状态、已用、剩余和最后观测时间。

**Step 4: 回归异步重建。** 历史页刷新不跳最新；关闭重开保留本进程选择；作用域切换不留旧详情；原日图悬停、工具周期、模型行、Esc、外点关闭、滚动位置和背景菜单 monitor 均不退化。

**Step 5: Commit。**

```bash
git add Sources/QuotaCycleHistoryView.swift KimiUsage.swift tests/fixtures/quota-cycle-history/main.swift
git commit -m "feat: support accessible Kimi cycle navigation"
```

## Task 8：完整回归与真实原生窗口验收

**Files:**
- Modify: `KimiUsage.swift` / 仅必要测试修复
- Create after verification: `docs/verification/2026-11-12-quota-cycle-history.md`（按实际验收日期命名）

**Step 1: 跑全部离线回归并保存摘要。** 在此 worktree 运行，不替换用户原目录构建。

```bash
./build.sh
./KimiUsage.app/Contents/MacOS/KimiUsage --self-test
python3 -m unittest discover -s tests -p '*_test.py' -v
bash -n build.sh scripts/update.sh scripts/release.sh
file KimiUsage.app/Contents/MacOS/KimiUsage
codesign --verify --deep --strict KimiUsage.app
```

预期全部通过，二进制为 arm64 Mach-O，签名验证成功；不要求 x86_64、universal 或 Rosetta。

**Step 2: 执行专用假数据预览。** 新增旗标覆盖固定 epoch、假凭据作用域和 1/6/13/25 轮、候选、写失败、损坏版本、跨年、本地时区；不得创建真实历史目录。

```bash
./KimiUsage.app/Contents/MacOS/KimiUsage --visual-preview --visual-preview-quota-history
./KimiUsage.app/Contents/MacOS/KimiUsage --visual-preview-dark --visual-preview-quota-history
./KimiUsage.app/Contents/MacOS/KimiUsage --visual-preview-narrow --visual-preview-quota-history
./KimiUsage.app/Contents/MacOS/KimiUsage --visual-preview-empty --visual-preview-quota-history
./KimiUsage.app/Contents/MacOS/KimiUsage --visual-preview --visual-preview-quota-history --visual-preview-test
```

另跑现有背景矩阵，确认第五张卡没有破坏 solid/liquidGlass/classicMaterial 和降低透明度：

```bash
./KimiUsage.app/Contents/MacOS/KimiUsage --visual-preview --visual-preview-background-test=/tmp/kimi-quota-history-bg
```

**Step 3: 用 @cua-driver-cli 验收真实 AppKit 窗口。** 先列窗口并展示预览，再实际点击折叠、翻页、第六组、移出、键盘跨页、关闭重开、滚动到工具明细并截图。不能用 HTML 或截图工具成功代替布局结论。

**Step 4: 回读隔离证据并写验收报告。** 用临时目录模拟保存→退出→恢复、A/B key、损坏文件、不可写目录；断言 fixture 外无历史写入。报告分别列明纯状态机、磁盘失败、原生 UI 已测范围，以及真实账号长期采样尚未验证。不得访问真实 auth、运行 `--once`、执行真实 update/release。

**Step 5: Commit。** 若发现代码问题，回到对应 Task 补失败用例并修复，再重新验收；不要把修复藏进报告提交。

```bash
git add docs/verification/2026-11-12-quota-cycle-history.md
git commit -m "test: record Kimi quota history verification"
```

## Task 9：同步现行文档与交付

**Files:**
- Create: `docs/project/17-quota-cycle-history.md`
- Modify: `README.md`
- Modify: `docs/DEVELOPMENT.md`
- Modify: `docs/project/02-architecture.md`
- Modify: `AGENTS.md` / 只更新已变化的模块入口和五卡片顺序
- Modify: `CHANGELOG.md` / 若仓库已有则补 Unreleased；没有则在本次新建并只记实际变化

**Step 1: 写文档验收清单。** 必须找到：位置、6/12 翻页、7 天窗口、首次采样起记、正常到期/窗口变化未知/gap、百分比非 Token、最后观测、凭据分区及轮换后重新记录、本地目录、预览与测试命令。

**Step 2: 先核对代码实际行为。** 与计划有分歧时修正实现或记录执行偏差，不把计划照抄成已实现事实。

**Step 3: 写用户说明、维护说明与变更记录。** README 只写用户需要的几句话；`17-quota-cycle-history.md` 保留完整状态机与不确定性；DEVELOPMENT 补模块、预览命令和验证边界；不顺手修改版本号或执行发布。

**Step 4: 最后核验改动范围。**

```bash
git diff --check
git status --short
git diff --stat
```

不得出现真实历史 JSON、salt、API Key、截图草稿或构建缓存。合并、替换运行中的 App 与公开发布不属于本计划授权。

**Step 5: Commit 并交付。**

```bash
git add README.md docs/DEVELOPMENT.md docs/project/02-architecture.md docs/project/17-quota-cycle-history.md docs/verification/2026-11-12-quota-cycle-history.md AGENTS.md CHANGELOG.md
git commit -m "docs: document Kimi quota cycle history"
```

## 4. 最终验收矩阵

| 编号 | 必须满足 |
|---|---|
| A1 | 卡片在用量简析之后、工具明细之前；五张常规卡片，14pt 圆角、10pt 边距和原字体层级不变。 |
| A2 | 330/300pt 面板每屏最多六组，每组两柱，纵轴百分比、上限 100%；没有假 Token 上限。 |
| A3 | 最近 12 轮并可继续更早；当前轮在最新页右侧，不足六轮不伪造历史。 |
| A4 | 正常到期、窗口变化原因未知、待确认、缺口可区分；没有用卡或被动重置文案。 |
| A5 | 缺口不补零，首轮推算开始和最后观测误差明确展示。 |
| A6 | 重放、网络错误、缺 reset 不多造轮次，不发额外请求，不读取慢轮账号接口来 gate 历史。 |
| A7 | 凭据作用域隔离、代际、异步切换、原子写和 0700/0600 权限有自动化用例；API Key/salt 不落历史 JSON。 |
| A8 | 历史可恢复候选；损坏、未来版本、写失败不覆盖旧数据且状态可见。 |
| A9 | 翻页、选择、键盘、折叠、刷新稳定，原日图、工具、背景菜单和 Popover 交互不退化。 |
| A10 | 自动化测试、arm64 构建、签名、浅深色及三种背景原生预览通过；真实长期观测未做则明确未验证。 |

## 5. 风险与停止条件

1. **接口不可识别性：** 同截止时间的比例回落、reset 缺失或时间回拨无法可靠判定时保留待确认，不能为好看强制拆段。
2. **凭据轮换：** 本地分区以 API Key 为作用域，轮换后看不到旧历史是刻意安全降级；不得为延续历史而改存原始凭据或无盐哈希。
3. **窄面板可读性：** 六组溢出时先减少重复标签、优化详情；若实际只能容纳四组，把截图和尺寸交用户决定，不暗中改验收数。
4. **磁盘格式与容量：** 首版去重和心跳控制增长，不删除旧历史；出现实际性能问题再提出分年归档，不提前引入数据库。
5. **权限边界：** 若必须更换认证、读取额外账号资料、写原始会话、替换运行中 App 或公开发布，停止并请求确认。

## 6. 执行交接

- 推荐检查点：Task 1–2（判定正确性）→ Task 3–5（落盘与接入）→ Task 6–7（原生 UI）→ Task 8–9（验收与文档）。
- 方式 A：当前会话逐任务执行，每个检查点审阅；独立对抗审查可委派，但互相依赖的接入/UI 任务不并行写同一主文件。
- 方式 B：另开会话使用 `@executing-plans`，绑定同一 worktree，读取本计划后分批执行。
- 无论哪种方式，都先完成失败测试再改生产逻辑；不得仅凭源码检查或示意图宣称上线完成。
