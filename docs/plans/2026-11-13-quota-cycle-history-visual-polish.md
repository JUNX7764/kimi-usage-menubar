# 额度周期回顾视觉对齐 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在不改变额度历史数据、状态机和浏览逻辑的前提下，将「额度周期回顾」重做为 CodexUsage「用量简析」同构的紧凑原生卡片，解决图例与控件割裂、柱体粗方、选中态过重及短历史布局失衡。

**Architecture:** 只重构 `Sources/QuotaCycleHistoryView.swift` 的展示模型和 AppKit 绘制，并更新 `KimiUsage.swift` 中现有预览守门。沿用 `QuotaCycleSnapshot`、`QuotaCycleBrowser`、持久化与控制器回调；图表内部采用 CodexUsage 已验证的“固定图高、图内浮层、底部分区状态条”模式，不引入新数据请求或 UI 框架。

**Tech Stack:** Swift / AppKit / Foundation，现有 `--self-test` 与 `--visual-preview*` 固定夹具，Python unittest，@cua-driver-cli 原生视觉与交互验收。

---

> **2026-11-13 本机验收修订：** 用户明确要求当前轮始终靠右，并在每轮日期正下方直接显示该轮已用百分比。最终图布由 61pt 调整为 76pt，短历史由居中改为固定六列槽宽右对齐；只有一页时隐藏翻页按钮和页码。下文原计划的 61pt/居中描述由本修订覆盖，其他设计不变。

## 0. 执行边界与证据

- 执行 Worktree：`/Users/Chester/.proma/agent-workspaces/kimi-usage-menubar/6dbc7f17-5d58-4e45-9d80-7b4ae5326d99/plan-worktree`；分支 `plan/quota-cycle-history-20261112`；本计划基线 `1fd046d`。
- 参考实现：CodexUsage `b1b11f2`，重点读取 `Sources/DailyUsageView.swift` 的 `DailyUsageChart`，以及 `CodexUsage.swift` 的 `makeDailySection`、`PanelComparisonStack`、`PanelSectionHeading`。
- 模板中的 `superpowers:*` 是 Skill 固定头部；本工作区实际使用 `@executing-plans`。原生 App 验收使用 `@cua-driver-cli`，不以网页或静态模型代替。
- 本文是待执行计划，不代表改动或验收已经完成。执行前运行 `git status --short`；每个 Task 的 commit 是未来检查点，用户不要求提交时只保留工作区改动。不得加入 Proma 归因。
- **不改**：7 天窗口口径、样本 gate、周期拆分、百分比与剩余语义、历史存储、账号隔离、每屏 6 轮、首批 12 轮及扩展、翻页/固定选择/键盘跨页、折叠状态、卡片顺序。
- **不改其他卡片**：KimiUsage 外层 330/300pt 面板、14pt 卡片圆角、10pt 内容边距和现有色系保持不变。本轮对齐的是 CodexUsage 板块内部结构，不把整张 Kimi 面板改成 Codex 配色或全局尺寸。
- 单一事实源仍是源码与测试。文档中的目标尺寸必须落实为几何断言和真实截图，不能只写“更美观”。

## 1. 差距与目标设计

### 1.1 当前实现的具体问题

| 项目 | 当前实现 | CodexUsage 参考 | 本轮处理 |
|---|---|---|---|
| 信息结构 | 标题、独立图例/翻页行、72pt 图、独立日期行、36pt 详情卡 | 标题、28pt 主数值行、61pt 图、32pt 比较条 | 改为同构四层，减少一行独立控件和一层“卡中卡” |
| 翻页 | 与图例同处图表上方 | 工具周期等附件位于标题行 | 翻页移入标题行，折叠箭头保持最右 |
| 柱体 | 单柱最宽 13pt，直角 `NSRect.fill` | 6pt 宽、46pt 高、1pt 微圆角 | 固定 6pt、46pt、1pt；同组间隙 3pt |
| 柱体层级 | 灰柱 0.28/0.40、已用 0.78/1，选中同时改多组透明度 | 选中只加 0.07 列底，柱体本身稳定 | 全部柱体透明度稳定，选中只保留列底和日期字色 |
| 当前轮 | 依赖额外卖点/文案 | 今日用描边空心柱 | 当前轮已用柱改空心，其他轮实心，不新增“当前”图例 |
| 图表装饰 | 全宽基线、独立日期视图；实际截图还暴露额外纵轴信息 | 无额外线性装饰，日期直接画入 61pt 画布 | 删除基线/纵轴，日期并入画布 |
| 详情 | 图下固定双行灰底详情 | 图内即时双行浮层 | 完整详情进图内浮层；底部仅保留状态与剩余 |
| 短历史 | 列宽随实际条数变化，视觉节奏不一致 | 固定列几何 | 以 6 列计算固定槽宽，实际列整体居中，不画假柱/假日期 |

### 1.2 目标线框

```text
[chart.bar.fill] 额度周期回顾          ‹ 最近 6 个 ›  [折叠]
89% 已用                              [细灰柱] 上限 100%
┌──────────────── 61pt 图布，内含浮层 ────────────────┐
│       6pt 灰上限 + 3pt 间隔 + 6pt 蓝已用；柱区 46pt      │
│       当前轮已用柱为空心；选中列仅有 0.07 浅底             │
│ 10/02       10/09       10/16  ……       11/13（9pt）    │
└──────────────────────────────────────────────────┘
[       进行中        |        当前剩余 11%       ] 32pt
```

- 顶部主数值为当前展示轮次的已用百分比：19pt semibold、等宽数字、Kimi 动态蓝；“已用”为 10pt secondary。右侧只保留“上限 100%”图例，图例色块使用与真实柱相同的 6×10pt、1pt 圆角，不再使用第三套圆点。
- 底部左栏为状态：`进行中` / `窗口变化待确认` / `正常到期` / `窗口变化` / `观测缺口`；右栏为既有剩余语义：`当前剩余 11%` / `到期未用约 11%` / `变化前剩余约 11%` / `剩余无法判定`。完整日期区间、开始精度和最后观测仍由浮层、tooltip 与 VoiceOver 提供。
- 浮层复刻 CodexUsage 的两行 10pt 样式：第一行 `detailTitle`，第二行 `detailValue`；圆角 6、0.5pt 描边、水平/垂直内边距 8/6、行距 2，`hitTest` 返回 nil。浮层优先放在选中柱另一侧，不增加卡片高度。
- 默认/固定选择更新顶部数值与底部状态条；悬停时额外显示浮层。移出后隐藏浮层并恢复固定选择；点击固定、键盘跨页、刷新保持等现有行为不变。
- 不足 6 轮时仍用 `画布宽 / 6` 作为槽宽，实际分组整体水平居中。1 轮不再贴右或拉满全宽；4 轮与 6 轮的柱距一致；不生成占位柱、占位日期或不可命中的前导空列。

### 1.3 固定尺寸契约

在 `QuotaCycleHistoryView.swift` 建立唯一尺寸入口，绘制、布局和测试均引用它，不散落魔法数：

```swift
enum QuotaCycleVisualMetrics {
    static let summaryHeight: CGFloat = 28
    static let canvasHeight: CGFloat = 61
    static let barAreaHeight: CGFloat = 46
    static let barWidth: CGFloat = 6
    static let barGap: CGFloat = 3
    static let barCornerRadius: CGFloat = 1
    static let stripHeight: CGFloat = 32
    static let stripCornerRadius: CGFloat = 6
    static let selectionFillAlpha: CGFloat = 0.07
    static let capFillAlpha: CGFloat = 0.16
}
```

## 2. 文件地图

| 文件 / 符号 | 修改内容 |
|---|---|
| `Sources/QuotaCycleHistoryView.swift` / `QuotaCycleItem` | 增加已格式化的 `usedText`、`statusText`、`remainingText`；不改原始 `usedPercent` |
| `Sources/QuotaCycleHistoryView.swift` / `QuotaCyclePresentation` | 从现有 natural/windowChanged/gap/current/pending 分支生成新文案，不新增业务状态 |
| `Sources/QuotaCycleHistoryView.swift` / `QuotaCycleChartCanvas` | 固定柱几何、微圆角、空心当前柱、图内日期、短历史居中、浮层 |
| `Sources/QuotaCycleHistoryView.swift` / `QuotaCycleDetailView` | 替换为 32pt 双栏 `QuotaCycleStatusStrip`，不再显示双行“卡中卡” |
| `Sources/QuotaCycleHistoryView.swift` / `QuotaCycleHistorySectionView` | 标题行翻页、主数值行、61pt 画布和状态条；保留现有回调 |
| `KimiUsage.swift` / `verifyQuotaHistoryGeometryForPreview` | 更新尺寸、居中、柱宽、柱高、状态条与无旧详情视图断言 |
| `KimiUsage.swift` / `verifyQuotaHistoryInteractionsForPreview` | 保留原事件链，新增浮层显隐/边界和顶部/底部随选择更新断言 |
| `KimiUsage.swift` / `--self-test` 历史卡片段 | 更新 330/300pt、1/4/6/13/25 轮和状态文案断言 |
| `docs/project/17-quota-cycle-history.md` | 只更新视觉结构、浮层、当前空心柱和短历史居中事实 |
| `docs/DEVELOPMENT.md` | 更新该板块的展示尺寸和预览验证说明；构建与数据口径不动 |
| `CHANGELOG.md` / `Unreleased` | 在“优化”记录本轮视觉重构，不改既有“新增”历史口径 |
| `docs/images/kimi-usage.png` | 所有原生验收通过后，用固定假数据重新生成当前面板截图 |

不修改 `Sources/QuotaCycleHistory.swift`、`QuotaCycleStore.swift`、`QuotaCycleCoordinator.swift`、`build.sh`、脚本协议或发布文件。

## Task 1：锁定展示文案与视觉尺寸

**Files:**
- Modify: `Sources/QuotaCycleHistoryView.swift`
- Modify: `KimiUsage.swift`

**Step 1：写失败的纯展示断言。**

在 `--self-test` 的「额度周期回顾卡片」段、现有 fixture 检查之后加入：

```swift
let previewItems = QuotaCyclePresentation.items(from: .previewFixture)
guard let currentItem = previewItems.last else {
    throw Failure(description: "preview fixture must include a current cycle")
}
try expect(currentItem.usedText == "36%", "current primary value must use observed percent")
try expect(currentItem.statusText == "进行中", "current status must be concise")
try expect(currentItem.remainingText == "当前剩余 64%", "current remaining semantics changed")
try expect(QuotaCycleVisualMetrics.canvasHeight == 61
           && QuotaCycleVisualMetrics.barAreaHeight == 46
           && QuotaCycleVisualMetrics.barWidth == 6
           && QuotaCycleVisualMetrics.barCornerRadius == 1,
           "quota chart must use CodexUsage chart metrics")
```

直接使用现有 `Failure` 与 `expect` 断言，不为 UI 预览引入 XCTest 依赖。

再对 `previewPendingFixture` 生成的最后一项断言 `statusText == "窗口变化待确认"`；从 `previewFixture` 找 natural、windowChanged、gap 项，分别断言 `正常到期` / `窗口变化` / `观测缺口`，gap 的 `remainingText == "剩余无法判定"`。

**Step 2：运行并确认失败。**

Run:

```bash
./build.sh
./KimiUsage.app/Contents/MacOS/KimiUsage --self-test
```

Expected: 编译失败，提示缺少 `usedText/statusText/remainingText/QuotaCycleVisualMetrics`；不能通过先注释测试取得 PASS。

**Step 3：实现展示字段与尺寸枚举。**

在 `QuotaCycleItem` 增加：

```swift
let usedText: String
let statusText: String
let remainingText: String
```

在 `makeClosedItem` 各现有分支同时设置简洁字段，保留 `detailTitle/detailValue/accessibilityText` 原文：

```swift
// natural
let statusText = "正常到期"
let remainingText = record.wasObservedFull
    ? "已用满"
    : "到期未用约 \(percent(remaining))"
// windowChanged
let statusText = "窗口变化"
let remainingText = "变化前剩余约 \(percent(remaining))"
// gap
let statusText = "观测缺口"
let remainingText = "剩余无法判定"
```

Swift switch 不允许在不同分支重复隐式声明同名局部量时，将 `statusText/remainingText` 与现有 `title/value/spokenEnd` 一起声明为 `var`，在各分支赋值。当前轮：

```swift
let statusText = pending ? "窗口变化待确认" : "进行中"
let remainingText = "当前剩余 \(percent(remaining))"
let usedText = percent(used)
```

所有构造器调用补 `usedText: percent(used)`、`statusText`、`remainingText`。加入 §1.3 的完整 `QuotaCycleVisualMetrics`。不得改 `usedPercent` 或状态机。

**Step 4：运行测试并确认通过。**

Run:

```bash
./build.sh && ./KimiUsage.app/Contents/MacOS/KimiUsage --self-test
```

Expected: build 无 warning，`KimiUsage self-test: PASS`。

**Step 5：Commit。**

```bash
git add Sources/QuotaCycleHistoryView.swift KimiUsage.swift
git commit -m "test: 锁定额度周期回顾视觉与文案契约"
```

## Task 2：重排为 CodexUsage 同构板块

**Files:**
- Modify: `Sources/QuotaCycleHistoryView.swift`
- Modify: `KimiUsage.swift`

**Step 1：写失败的布局几何断言。**

在 `verifyQuotaHistoryGeometryForPreview()` 中，将查找 `QuotaCycleDetailView` 的旧断言替换为以下目标断言；此时类型尚未创建，预期编译失败：

```swift
guard let summary = descendants(card).compactMap({ $0 as? QuotaCycleSummaryView }).first,
      let strip = descendants(card).compactMap({ $0 as? QuotaCycleStatusStrip }).first else {
    return fail("summary or status strip missing")
}
guard abs(summary.frame.height - QuotaCycleVisualMetrics.summaryHeight) < 1,
      abs(canvas.frame.height - QuotaCycleVisualMetrics.canvasHeight) < 1,
      abs(strip.frame.height - QuotaCycleVisualMetrics.stripHeight) < 1 else {
    return fail("Codex-style row heights changed: summary=\(summary.frame.height) "
        + "canvas=\(canvas.frame.height) strip=\(strip.frame.height)")
}
let visibleTexts = descendants(card).compactMap { ($0 as? NSTextField)?.stringValue }
if let latest = expectedItems.last {
    guard !visibleTexts.contains(latest.detailTitle),
          !visibleTexts.contains(latest.detailValue) else {
        return fail("legacy two-line detail text still rendered")
    }
}
```

在 330 和 300pt 的 `--self-test` 循环同步使用上述三类视图和尺寸；保留卡片顺序、宽度、六组和短历史等高断言。

**Step 2：运行并确认失败。**

Run:

```bash
./build.sh
```

Expected: 找不到 `QuotaCycleSummaryView` / `QuotaCycleStatusStrip`，或旧布局不满足新尺寸。

**Step 3：实现主数值行和双栏状态条。**

新增 `QuotaCycleSummaryView`：28pt 高、horizontal stack、`.firstBaseline`、spacing 7。左侧为 19pt semibold 等宽数字的 `usedText`（`PanelAccent.codex.color`）和 10pt secondary 的“已用”；弹性间隔后放 6×10pt 灰色图例与 10pt“上限 100%”。暴露：

```swift
final class QuotaCycleSummaryView: NSView {
    private let valueLabel: NSTextField
    // init 按上述约束完整建立 28pt summaryRow
    func configure(item: QuotaCycleItem) {
        valueLabel.stringValue = item.usedText
        toolTip = "最后观测已用 \(item.usedText)"
        setAccessibilityLabel("已用 \(item.usedText)")
    }
}
```

将 `QuotaCycleDetailView` 替换为 `QuotaCycleStatusStrip`：32pt 高、6pt 圆角、`labelColor@0.06`；horizontal row 左右等宽，中间 1×18pt `NSBox` 分隔线。左右标签均 11pt、居中、单行尾截断，左为 `statusText`，右为 semibold 等宽数字 `remainingText`：

```swift
func configure(item: QuotaCycleItem) {
    statusLabel.stringValue = item.statusText
    remainingLabel.stringValue = item.remainingText
    toolTip = "\(item.detailTitle)\n\(item.detailValue)"
    setAccessibilityLabel(item.accessibilityText)
}
```

标签必须设置低 horizontal compression resistance，并为整个 strip 保留完整 tooltip；长状态只能截断视觉文本，不能撑高或丢 VoiceOver 全文。

**Step 4：改 section 组装顺序并把翻页收进标题行。**

根 stack spacing 改为 6。仅在 expanded、loaded 且有可见轮次时建立 `pagerStack`，标题 trailing 顺序为 `[pagerStack, toggle]`；折叠或无数据时只显示 toggle。删除独立 legend/controls 行和 `datesRow`。

展开内容严格按以下顺序：

```swift
PanelUI 等价的自有工厂仍使用 QuotaCycleWidget，不扩大主文件 private 访问级别：
header
summary                 // 28pt
canvas                  // 61pt
statusStrip             // 32pt
earlierRow              // 仅原有“更早记录”条件满足时出现
persistence notice      // 仅写失败时出现
```

`canvas.heightAnchor` 改为 `QuotaCycleVisualMetrics.canvasHeight`。`updateSelectionDisplay` 同时调用 `summary.configure(item:)` 与 `statusStrip.configure(item:)`；保留 `displayedItem`、日期选中颜色和全部 onPin/onPage/onStep/onExtendWindow 回调。页码算法 `pageLabelText` 不变。

**Step 5：构建、运行几何测试并检查默认画面。**

Run:

```bash
./build.sh
./KimiUsage.app/Contents/MacOS/KimiUsage --visual-preview --visual-preview-quota-geometry
./KimiUsage.app/Contents/MacOS/KimiUsage --visual-preview-narrow --visual-preview-quota-geometry
```

Expected: 两个几何入口均 PASS；330/300pt 标题、页码和折叠箭头不截断，卡片高度约 180–190pt（异常提示和“更早记录”允许自然增高）。

**Step 6：Commit。**

```bash
git add Sources/QuotaCycleHistoryView.swift KimiUsage.swift
git commit -m "refactor: 对齐额度周期回顾板块信息层级"
```

## Task 3：重做立柱、日期和短历史几何

**Files:**
- Modify: `Sources/QuotaCycleHistoryView.swift`
- Modify: `KimiUsage.swift`

**Step 1：写失败的柱体与短历史断言。**

在现有逐组 geometry 断言中加入：

```swift
try expect(abs(group.cap.width - QuotaCycleVisualMetrics.barWidth) < 0.01
           && abs(group.used.width - QuotaCycleVisualMetrics.barWidth) < 0.01,
           "bars must stay 6pt at every panel width")
try expect(abs(group.cap.height - QuotaCycleVisualMetrics.barAreaHeight) < 0.01,
           "cap must represent the full 46pt 100% range")
try expect(abs(group.used.minX - group.cap.maxX - QuotaCycleVisualMetrics.barGap) < 0.01,
           "paired bars must have a stable 3pt gap")
```

为当前轮增加纯展示断言：`QuotaCycleChartCanvas.usedBarStyle(for: currentItem) == .outlined`，已结束项为 `.filled`。

短历史断言不再只检查“等高”：分别取得 6 轮和 4 轮画布的 `groupFramesForTest`，断言二者 `slot.width` 相等；4 轮首尾 slot 的中心连线中点等于画布 `midX`（容差 0.5）；1 轮唯一 slot 的 `midX == canvas.bounds.midX`。断言总数仍为实际记录数，不得为居中补 2 个空组。

**Step 2：运行并确认失败。**

Run:

```bash
./build.sh && ./KimiUsage.app/Contents/MacOS/KimiUsage --self-test
```

Expected: 旧的 13pt 上限、随条数变化的槽宽或缺失的 barStyle 导致 FAIL。

**Step 3：实现固定六列几何和居中短历史。**

让 canvas `isFlipped == true`，与 CodexUsage 坐标一致。`GroupFrame.slot` 仍覆盖 61pt 整列用于命中，cap/used 只在顶部 46pt 柱区。完整替换 `groupFrames(in:)` 的核心计算：

```swift
enum UsedBarStyle { case filled, outlined }
static func usedBarStyle(for item: QuotaCycleItem) -> UsedBarStyle {
    item.isCurrent ? .outlined : .filled
}

private func groupFrames(in rect: CGRect) -> [GroupFrame] {
    guard !items.isEmpty else { return [] }
    let slotWidth = rect.width / CGFloat(QuotaCyclePresentation.pageSize)
    let contentWidth = slotWidth * CGFloat(items.count)
    let originX = rect.minX + (rect.width - contentWidth) / 2
    let pairWidth = QuotaCycleVisualMetrics.barWidth * 2 + QuotaCycleVisualMetrics.barGap
    return items.enumerated().map { index, item in
        let slot = CGRect(x: originX + CGFloat(index) * slotWidth, y: 0,
                          width: slotWidth, height: QuotaCycleVisualMetrics.canvasHeight)
        let pairX = slot.midX - pairWidth / 2
        let minimum: CGFloat = item.isCurrent ? 3 : 2
        let usedHeight = max(minimum,
            QuotaCycleVisualMetrics.barAreaHeight * CGFloat(item.usedPercent / 100))
        return GroupFrame(
            slot: slot,
            cap: CGRect(x: pairX, y: 0,
                        width: QuotaCycleVisualMetrics.barWidth,
                        height: QuotaCycleVisualMetrics.barAreaHeight),
            used: CGRect(x: pairX + QuotaCycleVisualMetrics.barWidth
                             + QuotaCycleVisualMetrics.barGap,
                         y: QuotaCycleVisualMetrics.barAreaHeight
                             - min(QuotaCycleVisualMetrics.barAreaHeight, usedHeight),
                         width: QuotaCycleVisualMetrics.barWidth,
                         height: min(QuotaCycleVisualMetrics.barAreaHeight, usedHeight)))
    }
}
```

`usedPercent` 已由模型保证 0...100；保留 min/max 守门，但不把非法值变成新业务数据。

**Step 4：实现微圆角、稳定透明度和图内日期。**

删除全宽基线与独立日期行。绘制规则：

```swift
if item.id == effective {
    NSColor.labelColor.withAlphaComponent(QuotaCycleVisualMetrics.selectionFillAlpha).setFill()
    NSRect(x: frame.slot.minX, y: 0,
           width: frame.slot.width,
           height: QuotaCycleVisualMetrics.barAreaHeight).fill()
}
let capPath = NSBezierPath(roundedRect: frame.cap,
    xRadius: QuotaCycleVisualMetrics.barCornerRadius,
    yRadius: QuotaCycleVisualMetrics.barCornerRadius)
NSColor.secondaryLabelColor.withAlphaComponent(QuotaCycleVisualMetrics.capFillAlpha).setFill()
capPath.fill()
let usedPath = NSBezierPath(roundedRect: frame.used,
    xRadius: QuotaCycleVisualMetrics.barCornerRadius,
    yRadius: QuotaCycleVisualMetrics.barCornerRadius)
switch Self.usedBarStyle(for: item) {
case .filled:
    PanelAccent.codex.color.setFill(); usedPath.fill()
case .outlined:
    PanelAccent.codex.color.setStroke(); usedPath.lineWidth = 1; usedPath.stroke()
}
```

随后在同一 `draw` 中以 9pt 绘制每组 `startLabel`，基线区域 y=49；选中日期 `.labelColor`，其余 `.secondaryLabelColor`，使用等宽数字。按文字实测宽度在 slot 内居中并 clamp 到画布左右界，不再创建六个 NSTextField。

`updateSelectionDisplay` 删除对 `datesRow.arrangedSubviews` 的遍历，改为 `canvas.needsDisplay = true`，让日期颜色跟随 effectiveID。灰柱和已用柱不再随选中改透明度。

**Step 5：运行全部几何/模型测试。**

Run:

```bash
./build.sh
./KimiUsage.app/Contents/MacOS/KimiUsage --self-test
./KimiUsage.app/Contents/MacOS/KimiUsage --visual-preview --visual-preview-quota-geometry
./KimiUsage.app/Contents/MacOS/KimiUsage --visual-preview-narrow --visual-preview-quota-geometry
```

Expected: 全部 PASS；0% 仍有低基线、100% 不越界、当前柱空心、短历史居中且无假记录。

**Step 6：Commit。**

```bash
git add Sources/QuotaCycleHistoryView.swift KimiUsage.swift
git commit -m "feat: 优化额度周期立柱与短历史布局"
```

## Task 4：把完整详情迁入图内浮层并回归交互

**Files:**
- Modify: `Sources/QuotaCycleHistoryView.swift`
- Modify: `KimiUsage.swift`

**Step 1：写失败的浮层交互断言。**

在 `verifyQuotaHistoryInteractionsForPreview()` 保留原 A–H 事件顺序和选择 ID 断言，只做以下目标更新：

- 所有旧 `QuotaCycleDetailView` 查找改为 `QuotaCycleStatusStrip`；初始、点击、跨页后同时断言 `displayedItem`、summary 的 `usedText` 和 strip 的完整 accessibility label。
- B 段进入第 0 列后新增：

```swift
guard initialCanvas.hoverVisibleForPreview,
      initialCanvas.hoverWithinBoundsForPreview,
      initialCanvas.hoverHitTestsForPreview == false else {
    return fail("hover bubble must be visible, inside canvas and hit-transparent")
}
```

- 移出后断言 `hoverVisibleForPreview == false`，并恢复 newestID；点击固定后浮层不常驻，固定值仍在 summary/strip。
- 浮层文字必须同时含选中项 `detailTitle` 与 `detailValue`，VoiceOver 仍含“最后观测时间”。

为测试暴露只读计算属性，不提供修改浮层状态的测试后门：

```swift
var hoverVisibleForPreview: Bool { !hover.isHidden }
var hoverTextForPreview: String { hover.stringValue }
var hoverWithinBoundsForPreview: Bool { bounds.contains(hover.frame) }
var hoverHitTestsForPreview: Bool { hover.hitTest(.zero) != nil }
```

`bounds.contains(hover.frame)` 对浮层完整四边均成立时才为 true；不要使用仅中心点命中冒充不越界。

**Step 2：运行并确认失败。**

Run:

```bash
./build.sh
```

Expected: 缺少 hover 实现或旧画布无浮层，编译/测试失败。

**Step 3：实现 CodexUsage 同款浮层。**

新增私有 `QuotaCycleHoverLabel`，完整复用参考版的绘制参数：`horizontalInset=8`、`verticalInset=6`、`lineSpacing=2`、两行 10pt（第二行 medium）、6pt 圆角、0.5pt `labelColor@0.10` 描边；浅色底 `calibratedWhite 0.92 alpha 0.96`，深色 `0.20 alpha 0.96`。实现 `setText(date:value:)`、`fitToContent()`、`stringValue`、`isFlipped=true` 和 `hitTest(_) -> nil`。不能 import 或跨仓库引用 CodexUsage 文件。

canvas 初始化时加入 hover，默认 hidden。`updateHover(at:)` 在设置 `hoveredID` 后：

```swift
let item = items[index]
let frame = groupFrames(in: bounds)[index]
hover.setText(date: item.detailTitle, value: item.detailValue)
hover.fitToContent()
hover.frame.size.width = min(hover.frame.width, bounds.width)
let selectedX = frame.slot.midX
hover.frame.origin = NSPoint(
    x: selectedX < bounds.midX ? bounds.width - hover.frame.width : 0,
    y: 0)
hover.isHidden = false
setAccessibilityValue(item.accessibilityText)
```

浮层最长文案在 300pt 下可截断单行，但完整内容进入 `hover.toolTip` 和 accessibility。`mouseExited`、点击固定前、视图移出窗口时隐藏浮层并恢复 fallback accessibility；`setFallback` 不主动显示浮层。所有变化只改内存视图，不发请求、不写历史。

**Step 4：运行真实 AppKit 合成事件和既有关闭重开回归。**

Run:

```bash
./build.sh
./KimiUsage.app/Contents/MacOS/KimiUsage --visual-preview --visual-preview-quota-history --visual-preview-test
./KimiUsage.app/Contents/MacOS/KimiUsage --visual-preview --visual-preview-test
./KimiUsage.app/Contents/MacOS/KimiUsage --visual-preview --visual-preview-key-test
```

Expected: 三项 PASS；悬停/移出、点击固定、左右键跨页、12→24 扩展、翻页、折叠重开、刷新保持、作用域重置、Esc 和背景菜单均不退化。

**Step 5：Commit。**

```bash
git add Sources/QuotaCycleHistoryView.swift KimiUsage.swift
git commit -m "feat: 将额度周期详情迁入图内浮层"
```

## Task 5：完成视觉矩阵、真实原生验收和文档

**Files:**
- Modify: `KimiUsage.swift`（仅预览需要补夹具时）
- Modify: `docs/project/17-quota-cycle-history.md`
- Modify: `docs/DEVELOPMENT.md`
- Modify: `CHANGELOG.md`
- Modify: `docs/images/kimi-usage.png`
- Create: `docs/verification/2026-11-13-quota-cycle-history-visual-polish.md`（实际验收日不同时使用真实日期）

**Step 1：生成固定数据视觉矩阵。**

将截图目录放在会话工作台，不把审查中间图提交仓库：

```bash
ARTIFACTS=/Users/Chester/.proma/agent-workspaces/kimi-usage-menubar/018b3726-abcb-4ff8-8817-47921e080223/verification/quota-history-visual-polish
mkdir -p "$ARTIFACTS"
./KimiUsage.app/Contents/MacOS/KimiUsage --visual-preview --visual-preview-quota-history --visual-preview-output="$ARTIFACTS/full-light.png"
./KimiUsage.app/Contents/MacOS/KimiUsage --visual-preview --visual-preview-quota-history --visual-preview-dark --visual-preview-output="$ARTIFACTS/full-dark.png"
./KimiUsage.app/Contents/MacOS/KimiUsage --visual-preview --visual-preview-quota-one --visual-preview-output="$ARTIFACTS/one-light.png"
./KimiUsage.app/Contents/MacOS/KimiUsage --visual-preview --visual-preview-quota-short --visual-preview-output="$ARTIFACTS/short-light.png"
./KimiUsage.app/Contents/MacOS/KimiUsage --visual-preview-narrow --visual-preview-quota-pending --visual-preview-output="$ARTIFACTS/pending-narrow.png"
./KimiUsage.app/Contents/MacOS/KimiUsage --visual-preview --visual-preview-quota-cross-year --visual-preview-output="$ARTIFACTS/cross-year.png"
./KimiUsage.app/Contents/MacOS/KimiUsage --visual-preview --visual-preview-background-test="$ARTIFACTS/backgrounds"
```

Expected: 所有命令退出 0 且 PNG 非空。逐张打开检查：顶部数值、上限图例、柱图和状态条形成同一层级；无 y 轴/第三图例/旧详情卡；柱宽和间距一致；当前空心柱清晰；1/4 轮居中；长状态只截断视觉文本且有全文提示；深色与三种背景均有足够对比。

**Step 2：按 @cua-driver-cli 验收真实 Popover。**

用本 worktree 二进制启动固定数据预览，不替换原项目或安装目录 App。通过 Cua `list_windows` 确认目标窗口后展示预览，再检查：

1. 真实鼠标从柱间空隙进入每列，浮层即时更新且不抢命中；移出恢复固定选择。
2. 点击第 4 列固定，左右键逐组并跨页；翻页按钮与“更早记录”仍可用。
3. 1 轮、4 轮、6 轮切换时布局不跳动；折叠/展开、关闭重开和刷新保持状态。
4. 浅色、深色、300/330pt 下无文字/柱体越界；VoiceOver 或 AX 树读取完整详情。

若 Cua 前台输入权限仍不可用，必须记录“合成事件通过、真实物理输入未验收”，不得写成全部通过。

**Step 3：运行完整离线回归。**

Run:

```bash
./KimiUsage.app/Contents/MacOS/KimiUsage --self-test
python3 -m unittest discover -s tests -p '*_test.py' -v
bash -n build.sh scripts/update.sh scripts/release.sh
codesign --verify --deep --strict KimiUsage.app
```

Expected: self-test PASS，Python 全量 OK，Shell 与签名检查通过。不得运行 `--once`、真实更新或 release。

**Step 4：更新当前事实文档和变更记录。**

- `17-quota-cycle-history.md`：主数值 19pt、画布 61pt/柱区 46pt、柱宽 6pt/间隙 3pt/圆角 1pt、当前空心、短历史居中、图内浮层和 32pt 状态条；保留全部历史语义与交互约束。
- `DEVELOPMENT.md`：同步板块展示和预览矩阵；不得改变既有构建、存储或权限描述。
- `CHANGELOG.md`：在 `Unreleased` 新增“优化”条目，说明视觉对齐，不改原新增功能的事实。
- `docs/images/kimi-usage.png`：仅在验收满意后用固定假数据更新；不提交工作台审查图。
- 验收文档记录基线/最终 commit、每项命令结果、截图清单、Cua 实际覆盖和未验证边界，区分离线测试与真实账号长期观测。

**Step 5：回读差异并确认没有越界改动。**

Run:

```bash
git status --short
git diff --stat
git diff -- Sources/QuotaCycleHistory.swift Sources/QuotaCycleStore.swift Sources/QuotaCycleCoordinator.swift build.sh scripts tests/script_test.py
```

Expected: 最后一条 diff 为空；改动仅限本计划允许的视图、预览守门、文档与截图。若数据/持久化文件出现改动，停止并说明原因，不得借视觉任务夹带模型修改。

**Step 6：Commit。**

```bash
git add KimiUsage.swift docs/project/17-quota-cycle-history.md docs/DEVELOPMENT.md CHANGELOG.md docs/images/kimi-usage.png docs/verification/2026-11-13-quota-cycle-history-visual-polish.md
git commit -m "docs: 记录额度周期回顾视觉优化验收"
```

若 `KimiUsage.swift` 在本 Task 未改，commit 前从暂存列表删除它，避免空泛提交说明。

## 3. 最终验收清单

| 编号 | 必须满足 |
|---|---|
| V1 | 结构为标题/主数值/61pt 图/32pt 状态条；翻页在标题行，无独立图例行、纵轴、旧双行详情卡。 |
| V2 | 每组灰柱和已用柱均 6pt、间距 3pt、圆角 1pt；上限柱高 46pt，已用不超上限。 |
| V3 | 选中只改变 0.07 列底与日期字色；柱体透明度稳定；当前轮为空心已用柱，无第三图例。 |
| V4 | 1/4/6/13/25 轮在 300/330pt 不越界；短历史按固定六列槽宽居中，不伪造记录。 |
| V5 | 顶部已用与底部状态/剩余来自同一 `displayedItem`；自然到期、窗口变化、gap、pending 语义不回退。 |
| V6 | 浮层完整显示 detailTitle/detailValue，位于画布内、hit-transparent；移出隐藏并恢复固定选择。 |
| V7 | 原有点击固定、方向键跨页、翻页、扩展、折叠、刷新/关开保持、作用域重置、VoiceOver 全部通过回归。 |
| V8 | 数据模型、状态机、存储、凭据、网络请求、构建脚本和其他卡片无功能改动。 |
| V9 | 浅色/深色、三种背景、降低透明度、300/330pt 有真实原生截图；Cua 未覆盖项明确保留。 |

## 4. 不做事项

- 不为了“更高级”增加渐变、阴影、玻璃小卡、动画或额外图标。
- 不把灰柱改成第二个高饱和系列，不使用 CodexUsage 暖橙色。
- 不用 Token 数、平均值、浪费量或虚构纵轴丰富画面。
- 不为短历史画空柱、斜线占位或填充假日期。
- 不借本轮修改全局卡片尺寸、面板宽度、其他板块交互或历史存储格式。
