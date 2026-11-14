# 面板设置（「···」）与 GLM 精修适配计划（v2）

> 状态：**提案，待用户确认后实施**。本文只梳理与规划，不表示任何功能已实现。
> 日期：2026-11-13；参考基线：GlmUsage `d02ef22`（卡片设置）+ `plan/ui-refinements-20261113`（五项 UI 精修，已离线验证、原生验收待做）。
>
> **v2 修订**：用户确认采纳「单根额度槽」与「涨跌胶囊」；修正 v1 两处事实错误——KimiUsage 已移植 GLM 每日图区+比较条（`KimiUsage.swift:4174`/`4266`），环比数据链路已存在（`TokenAggregator.comparisons`）。

## 一、GLM 侧现状梳理

### 1. 「···」统一面板设置（v1.5.0–v1.5.2，已发布）
- 头部按钮从单一「背景样式」升级为 `ellipsis`「面板设置」，`NSMenu` 两项：`卡片显示与排序…` + `背景样式 ▸` 子菜单（背景选择即时生效，旧系统禁用液态玻璃并标注）。
- 卡片布局模型 `GLMPanelLayout`（独立文件 `PanelCustomization.swift`）：稳定卡片 ID + order/hidden，JSON 持久化（`panelCardLayout.v1`）。
- 迁移规则：旧配置缺新卡时按默认顺序的**相对位置插入**（不追加末尾、不静默丢弃）；未知 ID 丢弃、hidden 与已知集求交。
- 原位设置页（面板内替换内容区）：`NSTableView` 七行，复选框显隐 + 拖拽 + 上/下按钮 + 恢复默认 + 完成；修改即时生效并保存，无「取消」。
- 已踩过的坑（直接抄作业）：
  - 打开设置页必须把 firstResponder 交给编辑器，否则焦点残留「···」按钮，Space 再弹菜单导致 transient popover 被 key 变化关闭。
  - 额度 10s 刷新会 `rebuildPanel()`：内容高度变化后 scroll offset 需钳制在界内；设置页进出、显隐后都要校验。
  - 允许全部隐藏：显示明确空态 + 恢复按钮；v1.5.2 修复了「历史卡未纳入独立配置、被 MCP 连带隐藏」的回归。
  - 首行上移/末行下移按钮禁用；拖放只接受本表来源与卡片 ID 文本。
  - 重开设置页重建视图但保留内存布局；「恢复默认」只重置布局，不动背景样式与折叠状态。

### 2. 五项 UI 精修 → KimiUsage 适用性（v2 修正后）
| 项 | GLM 做法 | KimiUsage 落点 | 结论 |
|---|---|---|---|
| 每日柱顶圆角 | 普通柱仅顶 1.5pt 圆角，零值 2pt 直线、缺失留空 | 用量简析 `DailyBarChartCanvas`（`KimiUsage.swift:4046–4116`）现为直角 `NSRect.fill()`，零日/缺失语义已有 | 可选（Phase G） |
| 数字 320ms 过渡 | 选中日 Token 数 0.320s ease-out，重定向不归零、尊重减少动态、AX 即时 | 用量简析选中行 `valueLabel`（`kimi-brief-value`） | 可选（Phase G） |
| 涨跌胶囊 | 比较值 soft chip + 窄版两行回退 | `ComparisonRowView`（`KimiUsage.swift:4266`）现为纯文本值；数据侧 `TokenAggregator.comparisons` 四种 Outcome 全在 | **采纳**（Phase F） |
| 单根额度槽 | 每轮一根 12pt 灰色上限槽，绿色底部填充已用比例 | `QuotaCycleHistoryView.swift:330–377` cap+used 双柱 | **采纳**（Phase E） |
| 周期回顾独立图标 | `clock.arrow.circlepath` | `QuotaCycleHistoryView.swift:582`，与用量简析同用 `chart.bar.fill` | 采纳（Phase D） |

### 3. 工程方法（同样借鉴）
- 每项先写独立 Swift fixture（RED）再实现（GREEN），`tests/*_test.py` 编译驱动；显式维护测试编译文件清单。
- 原生 GUI 回归串行执行、间隔 ≥5s；`docs/verification/` 留执行记录；离线通过不声称为原生验收。
- 文档同步：project 文档、DEVELOPMENT.md、CHANGELOG 分头更新；圆角/动画细节不塞进 AGENTS.md。

## 二、KimiUsage 落点与语义边界

### 必须保留的既有语义
- **比较条**：方向语义色是 Kimi 体系——增 = `PanelAccent.codex` 蓝、减 = `RemainingColorTier.green` 绿、持平/数据不足 = secondaryLabel（不照抄 GLM 的绿增橙减）；tooltip 含比较区间与公式 detail；AX 单条完整读出。
- **周期图**：整列命中（slot）、选中/悬停浅底高亮、当前轮「待确认」描边（`usedBarStyle .outlined`）、`usedText` 文案规则、一页六轮、短历史右对齐、摘要行与翻页不变；不因像素接近满槽就标「用满」。
- **隐藏 ≠ 收起**：隐藏卡数据照常获取与统计；允许全隐藏但给空态 + 恢复入口；恢复默认只重置布局，不动背景样式与折叠状态。
- 预览/离线测试不写生产 UserDefaults、不读真实凭据。

### 可配置卡片（实施时以实际组装确认）
用量进度（额度）、用量情况、用量简析、工具明细、额度周期回顾；头部（标题/套餐/账号行）、footer（刷新/登录项/退出）、更新横幅不参与。

### 明确不做
全界面变淡/缩字号、嵌套圆角（已废弃勿重提）、每卡片独立背景、任意坐标拖拽布局。

## 三、实施计划

建议拆两轮串行，各自独立可发布：**设置轮 A–D**（「···」+ 卡片配置）、**视觉轮 E–G**（周期槽 + 胶囊 + 可选精修）。

### Phase A：卡片布局模型（TDD，设置轮）
- 新建 `Sources/PanelLayout.swift`（纯 Foundation）：`KimiPanelCardID`（CaseIterable+Codable）+ `KimiPanelLayout`（order/hidden/visibleOrder/move/normalized/decode/encode/load/save），defaults key `panelCardLayout.v1`。
- 迁移断言：旧配置缺新卡按默认相对位置插入；未知 ID 丢弃；损坏 JSON 回退默认；UserDefaults suite 往返。
- 新增 `tests/panel_layout_test.py`；新增生产文件加入 `build.sh`。

### Phase B：头部「···」统一菜单
- `PanelHeaderView`：`paintpalette` → `ellipsis`，tooltip/AX「面板设置」；`NSMenu` = `卡片显示与排序…` + `背景样式 ▸`。
- 背景子菜单复用 `makeBackgroundStyleMenu()`（现有菜单结构离线断言保持，追加新项断言）；菜单跟踪期间挂起 local/global click monitor（沿用现有约定）。
- 无布局配置时全部可见、顺序即默认；首次写入不改变现有视觉。

### Phase C：原位卡片设置页
- 面板内容区切换为设置视图：每行 显隐复选框 + 上/下按钮（首末行禁用）+ 卡片名；底部「恢复默认卡片布局」「完成」。拖拽排序列为二期，先保证按钮路径完整。
- 焦点：打开设置页 `makeFirstResponder` 编辑器；进出设置页与显隐后校验 scroll offset 钳制；10s 重建后设置页焦点不丢。
- 全隐藏空态：说明文案 + 「恢复卡片布局」按钮。
- 事件回归：显隐/排序/完成/重开保留状态/全隐藏/滚动钳制，全部走真实按钮事件。

### Phase D：额度周期回顾独立图标
- `QuotaCycleHistoryView.swift:582` `chart.bar.fill` → `clock.arrow.circlepath`（14pt 常规字重、主题绿不变）；与用量简析同屏可区分。
- macOS 13 符号可用性按资料确认并在原生预览确认非空白 fallback。

### Phase E：周期双柱 → 单根额度槽（视觉轮）
- `QuotaCycleHistoryView.swift`：`GroupFrame` 的 `cap`/`used` 改为 `track` + `fill`——每轮一根居中 12pt 灰色上限槽（`secondaryLabel` 0.25 alpha 量级沿用现 cap 观感），已用比例从底部填充、按该轮自身上限归一化；0% 不画填充，100% 填满。
- 当前轮待确认沿用描边语义：`outlined` 时填充改描边（不做虚线框柱组）；选中/悬停浅底不变；日期、百分比标签、一页六轮、右对齐、翻页全部不动。
- `QuotaCycleVisualMetrics` 相应收缩（`barWidth/barGap/pairWidth` → 单槽宽度）；摘要行、悬停详情、VoiceOver 文案零改动。
- fixture 同步：现「双柱几何」断言（`KimiUsage.swift:6127` 一带 + 对应 Python）改单槽断言——槽居中于列、不越界、fill 与 track 同基线同宽、0%/近 0%/近 100%/100% 比例真实。
- 图例/说明文案若有「上限/已用」表述改为「已用/距上限」口径。

### Phase F：比较条涨跌胶囊
- 新增 chip 原语（`Sources/KimiDeltaChip.swift`）：`size(for:font:)`、`requiresTwoRows(halfWidth:captionWidth:chipWidth:)`、自适应明暗底色（前景色同色系 alpha，dark 0.16 / light 0.10 量级）、`setAccessibilityElement(false)` 不重复读数。
- `ComparisonRowView`：caption 保持 10pt；值改 chip，**沿用 Kimi 方向色**（增蓝/减绿/持平与数据不足灰）；`monospacedDigits` 保留在 chip 内 label；tooltip 与 AX 结构原样。
- 窄版回退：`requiresTwoRows` 触发时每半行转两行、条高 30 → 44（对齐 GLM），280pt 窄面板长值（如「新增 9.99B」）不截断数字。
- 数据侧零改动：`TokenAggregator.comparisons` 的 percent/flat/added/insufficient 原样透传，不重算口径。

### Phase G（可选，用户未点名，待确认是否并入）：每日柱顶圆角 + 数字 320ms 过渡
- `DailyBarChartCanvas`：普通柱顶 1.5pt 圆角、底部齐平；零日 2pt 直柱、缺失缺口语义保持；柱宽/高度换算不变。
- 选中行 `valueLabel` 320ms ease-out 数值过渡：重定向从当前值续走、首显/重开/无变化不播、缺数与恢复即时、尊重减少动态、AX 即时报目标值、重建时 timer 收尾。
- 需同步升级每日图交互断言为「日期即时 + 数值轮询等待最终值」，不允许测试模式绕过动画。

### 验证与交付（每 Phase 后跑门禁，收尾留档）
- 离线门禁：`./build.sh`、`--self-test`、`python3 -m unittest discover -s tests -p '*_test.py'`；`--visual-preview` 用例覆盖 正常/窄版/明暗/全隐藏空态/设置页进出/单槽近端点。
- 原生 GUI 回归串行执行并留 `docs/verification/2026-11-xx-*.md`（实际命令、退出码、截图）。
- 文档同步：`docs/DEVELOPMENT.md`、`docs/project/` 对应篇目、`CHANGELOG.md`；版本 patch +1（设置轮 v1.7.10、视觉轮 v1.7.11），用户确认后才部署/发布。

## 四、完成判据
- [ ] 「···」菜单含卡片设置与背景子菜单，背景选择即时生效，离线菜单结构断言通过。
- [ ] 卡片显隐与排序持久化；旧配置迁移不丢卡不静默追加；全隐藏有空态与恢复入口。
- [ ] 设置页焦点/滚动/重建三条坑均有回归锁定；Space 不会关闭面板。
- [ ] 额度周期回顾与用量简析图标同屏可区分。
- [ ] 周期图每轮单根额度槽：0%/近端点/100% 比例真实、待确认描边保留、摘要与详情口径不变。
- [ ] 比较条 chip：四种 Outcome 方向色沿用 Kimi 语义，窄面板不截断数字，AX/tooltip 原样。
- [ ] （若做 Phase G）圆角/320ms 符合规格，快速重定向与减少动态行为已验证。
- [ ] 完整离线门禁通过并留验证记录；未做变淡/嵌套圆角；未未经确认部署。
