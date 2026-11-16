# 缓存命中卡（全 harness）Implementation Plan

> 单卡方案。速度卡（decode 口径）经 2026-11-15 核实后**搁置**：全机 decode 数据仅 ZCode `model_usage` 存在；Kimi 自家两端 wire 日志无任何首字/时长事件（CLI 真实文件 1465 行、Work 2332 行事件词表全量清点，`llm.request` 仅起点 `time`、`usage.record` 仅完成时刻 `time`，无 delta/stream/chunk/first 类事件）。用户最终决策：速度卡不做、缓存卡按全 harness 实施。若未来 Kimi 客户端日志记录流式时间字段，速度卡可重启立项。口径部分继承 GlmUsage `2026-11-15-speed-cache-cards.md` 与 Codexusage `2026-11-15-model-response-cache-cards.md`。

**Goal:** 新增一张可选卡「缓存命中」：按周期（今日/近 7 天/近 30 天）展示整体（置顶汇总行）与各 Kimi 模型的缓存命中率与输入量，**覆盖本机全部 harness**（Work / kimi CLI / Proma / Claude / Hermes / ZCode 六源），回答「同样的事为什么今天费额度、明天省」。

**Architecture:** TokenAggregator 扫描趟内新增**并行缓存明细聚合**（对齐 Codex `recordDaysByModel` 模式）：`FileScanState` 增平行 `cacheDays`，各 parser 在现有累加点同步累加 cache_read/creation（现有 input/output 数字**零改动**）；Hermes 行结构扩缓存列（本地缓存表已有列，骑既有扫描趟，天然一致）；ZCode 新增独立只读 sibling reader（**不动 token 扫描 SQL**，规避主线回归）。CLI/Proma/Claude 的字节游标增量经 `scanRevision` bump 一次性重建窗口内文件（Work 本就每趟全量重建，无此问题）。`KimiPanelCardID` 新增 `.cache`（默认顺序 = allCases 自动进设置列表，`normalized()` 旧配置自动补末尾，零改动）；视图复用 `ToolPeriodButton` 周期行与 `PanelUI` 明细行样式；`--self-test` fixture 先行写失败断言。

**Tech Stack:** Swift、AppKit、SQLite3（只读）、现有 `build.sh` / `--self-test` / `--visual-preview` 回归，无新依赖。**不新增生产文件**（读取器与视图都在 `KimiUsage.swift`，`build.sh` 零改动）。

---

## 数据事实（2026-11-15 实测，实现前无需重验，口径注释须引用）

**文件源（Work / kimi CLI / Proma / Claude）：**
- Work 与 kimi CLI 同一套 daimon wire 格式：`llm.request` 与 `usage.record` 均带毫秒 `time`；usage 字段 kimi 系 `inputOther/inputCacheRead/inputCacheCreation/output`（CLI 真实文件实测存在）。
- Proma（Claude SDK 消息流）：assistant 行带毫秒 `_createdAt` 与完整 usage（`input_tokens/cache_read_input_tokens/cache_creation_input_tokens/output_tokens`，实测存在）；`result` 行是会话累计汇总，已被现有解析跳过。
- Claude JSONL：与 Proma 同构（`message.usage` 的 `*_tokens` 字段）。
- 现有聚合把缓存字段并进 input 总数后**丢弃明细**（parseLineObject 948-953），本方案新增平行累加，不动原累加。
- Work 解析（parseWorkLines）每趟全量重建（605 行 `rebuild = ... || !kimiOnly`），缓存明细无历史空洞；CLI/Proma/Claude 为字节游标增量，需 `scanRevision` bump 重建（592 行 `revision = kimiOnly ? 2 : 4` → bump 为 3/5；>31 天未修改文件本就在 30 天窗口外，重建代价秒级）。
- Work 双写语义：`usage.record` 与 `context.append_loop_event` 是同一次调用的双写（921-923 行），缓存累加必须落在与 input 相同的选择分支，防双计。

**Hermes：**
- `session_model_usage` 为 (session,model) 级累计行；本地缓存表已有 `cache_read_tokens/cache_write_tokens` 列（658 行）。缓存累加骑既有 hermes 扫描趟（diff 语义），与 input 同行读取，天然一致。

**ZCode：**
- 表：`model_usage`，每行 = 一次实际请求尝试。时间戳**毫秒**。`input_tokens` 即总输入，已包含缓存部分（`cache_read ⊆ input` 反例为 0）；`cache_creation_input_tokens` 本机当前全 0 但字段存在，不得假设恒为 0。
- Kimi 模型近 30 天缓存基线：k3.1-pro 1497 input 行 / 192M cache_read；kimi-for-coding 50 行 / 2.1M。

## 口径定义（实现必须逐条对齐，不得自行发挥）

**范围决策记录（2026-11-15，用户确认）：**
1. 只做「缓存命中」单卡，全 harness 六源（用户最终决策）。
2. 速度卡搁置：decode 数据仅 ZCode 存在、Kimi 自家日志无流式时间字段（证据见文档头）；E2E 口径用户明确拒绝。勿再重提「扩展速度卡来源」或「用 E2E 替代」。
3. 模型归一沿用 `normalizedModel`/`modelDisplayName`（K3.1 Pro / Kimi for Coding），分组合并跨来源自动完成。

**通用：**
- Kimi 过滤随现有 modelDays 语义（kimiOnly 扫描已过滤；Work 的未知模型行随现有口径进入统计）。
- 窗口：今日/近 7 天/近 30 天由按日聚合即时求和（289 行既有惯例）；读取近 30 天（31 天余量）。
- **分母复用现有 modelDays 各模型 input**（各源口径已统一为「含缓存总输入」：文件源 inputOther+cacheRead+cacheCreation 求和、Hermes input 含 cache、ZCode input_tokens 含缓存），**不重算分母，保证与「用量情况」数字同源一致**。
- `input_tokens ≤ 0` 的行不进任何分母（除零守卫，装配层执行）。

**分子（cache_read 取数键，逐源）：**
- kimi 系（Work/CLI）：`inputCacheRead`；Claude/Proma 系：`cache_read_input_tokens`/`cacheRead`；Hermes：`cache_read_tokens` 列；ZCode：`cache_read_input_tokens`。
- cache_creation 同型取数（kimi 系 `inputCacheCreation`、`cache_creation_input_tokens`/`cacheWrite`、`cache_write_tokens`），**仅用于 `—` 规则证据**，首版不独立展示写入量。

**命中率与展示：**
- 模型命中率 = `SUM(cache_read) / SUM(input)`；整体命中率 = 全来源全模型合计比值，置顶「整体」行，不参与排序。
- 命中率显示整数百分比（`97% 命中`）；输入量复用 `Fmt.tokens`。
- **`—` 规则**：窗口内该模型 `cache_read == 0 且 cache_creation == 0` → 命中率显示 `—`（区分「没有缓存数据」与「0% 命中」）；全部模型无证据 → 整体行同规则。
- 排序：窗口内 input_tokens 降序（与「用量情况」模型行同源）。
- 无卡片级「读取失败」态：文件源/Hermes 失败走现有部分失败语义（失败文件无贡献即无行）；**ZCode 缓存读取失败 → 该源 (input, cache) 同退**（分子分母同退防错位），其余来源照常渲染。不静默造 0。

## 已确认范围与不可变边界

- 卡片显示名「缓存命中」，默认可见，默认顺序：用量进度 → 用量情况 → 用量简析 → 额度周期回顾 → 工具明细 → 缓存命中；可经「···」隐藏/排序，恢复默认包含本卡。
- **红线：现有 `days`/`modelDays`/`days()`/`statWindows`/`buckets` 及「用量情况」「工具明细」「用量简析」全部数字零改动**（对齐 Codex plan 的 token_count 管线红线）；缓存累加只增不改，真机验收须含「升级前后用量情况三周期总量一致」。
- ZCode reader 只读打开 + `sqlite3_busy_timeout 1s`，挂 `aggregateBothDetailed()` includeSlow 分支，无新定时器/网络请求，不碰凭据/钥匙串。
- `scanRevision` bump 仅影响 CLI/Proma/Claude 窗口内文件一次性重建；Work/Hermes/ZCode token 路径语义不变。
- 周期选择：`cachePeriodIndex` in-memory 不落盘、默认「近 7 天」，对齐 `toolPeriodIndex` 现状。
- 首版不做：速度卡任何形式（decode 数据不存在 / E2E 已拒绝）、缓存写入量独立展示、按天趋势展开、会话级统计、菜单栏实时速度、单请求明细。
- 离线回归与 preview 只用临时 fixture，不读真实库/会话、不联网、不写生产偏好；不往 `AGENTS.md` 追加本功能细节。执行以实际符号为准，不机械依赖行号。

## UI 规格

```text
缓存命中                        [今日 | 近 7 天 | 近 30 天]
──────────────────────────────
整体                     97% 命中 · 输入196M
K3.1 Pro                 98% 命中 · 输入192M
Kimi for Coding          — 命中 · 输入2.1M
未知模型                  91% 命中 · 输入864K
```

- 行格式：模型名（主文字）｜命中率 + 输入量（次要文字，右对齐）。「整体」行恒置顶。
- 空态：窗口无任何 Kimi 用量 →「本周期暂无用量」（复用工具明细文案）；今日无缓存证据但有用量 → 各行按 `—` 规则显示，不算空态。
- 卡片不带独立刷新按钮，跟随面板全局刷新；周期行复用 `ToolPeriodButton`（标签「今日 / 7 天 / 30 天」对齐工具明细周期按钮命名）。

---

### Task 1: 文件源 + Hermes 并行缓存聚合 + 失败回归先行

**Files:**
- Modify: `KimiUsage.swift`（`FileScanState` 增 `cacheDays`；`parseLineObject`/`parseWorkLines` 累加扩展；Hermes 行结构与聚合扩展；`scanRevision` bump；`mergeSourceModelDays` 同型缓存合并；`--self-test` 各源 fixture 区追加断言）

**Step 1: 先写失败回归（各源临时 fixture，模式照抄既有 proma/claude/hermes/work fixture）**

1. Proma/Claude fixture assistant 行含 `cache_read_input_tokens`/`cache_creation_input_tokens` → cacheDays 精确累加；`result` 行（累计汇总）不产生缓存贡献。
2. CLI wire fixture（`usage.record` 含 `inputCacheRead/inputCacheCreation`）→ 精确累加；`context.append_loop_event` 双写不重复计（沿现有 preferUsageRecord 分支语义，缓存与 input 同分支）。
3. Work fixture（llm.request/usage.record 经 requestID 配对）→ 缓存按归属模型/日精确累加。
4. Hermes fixture：source 库带缓存列 → 本地行快照携带缓存列，diff 语义（新增/续写/删除）下 cache 累加正确。
5. **红线断言**：各 fixture 升级前后 `days`/`modelDays` 完全一致（缓存累加不触碰原数字）。
6. `scanRevision` bump：旧 revision 持久化状态 → 窗口内文件全量重建，cacheDays 无空洞；`offset == size` 的未变文件在 bump 后也重建；>31 天未修改文件仍跳过。
7. 截断/轮换（size < offset）→ cacheDays 随文件状态清零重扫。
8. 缓存合并：多来源同模型同日 cache 求和；窗口外行不进。

**Step 2: 实现使回归转绿**

- `FileScanState` 增 `cacheDays: [String: [String: [Double]]]`（day→model→[cacheRead, cacheCreation]），持久化随 ScanState JSON（旧 JSON 缺字段 → 空值，revision bump 后自然重建）。
- `parseLineObject`：在 948-953 usage 累加点同步提取 cache 两键入平行累加（键集复用同一组字符串常量，不改原 input 累加）。
- `parseWorkLines`：事件 usage 归属模型后同点累加。
- Hermes：行结构/本地表读写增缓存列传递（本地表建表列已存在，无需迁移；旧库无值按 0 起）。
- `scanRevision`：kimi 系 2→3、Work 4→5。
- 聚合出口：镜像 `mergeSourceModelDays` 增缓存合并；`aggregateBothDetailed()` 增 `cacheModelDays` 随快照上屏。

### Task 2: ZCode 缓存 sibling reader + 失败回归先行

**Files:**
- Modify: `KimiUsage.swift`（`scanZCodeModelDays` 之后新增 `scanZCodeCacheDays`；`--self-test` ZCode fixture 区追加断言）

**Step 1: 先写失败回归（模式照抄 7528 行既有 ZCode fixture）**

1. 已知 fixture → 按日 × 模型 cache_read/cache_creation 精确等于手算值。
2. 行选择语义与 `scanZCodeModelDays` 一致：同一 fixture 两条 reader 的行集相同（error/running 非零行同进，对齐「input 含 error 行」现状，保证分子分母行集一致）。
3. `isKimiModel` 过滤：混入 `glm-5.3`/`claude-sonnet-5-5` 行不出现在结果。
4. 毫秒时间戳与 `startOfDay` 日界正确；周期外行不进。
5. 缺 cache 列 fixture（`CREATE TABLE model_usage (unrecognized TEXT)`）→ 返回 nil（失败）；缺表/库不存在 → nil。装配层断言：reader 失败时该源 (input, cache) 同退，其余来源不受影响。

**Step 2: 实现使回归转绿**

- `SELECT model_id, input_tokens, cache_read_input_tokens, cache_creation_input_tokens, started_at FROM model_usage WHERE started_at >= ?`（毫秒 cutoff，31 天余量）；`LIMIT 0` 探针 schema 守卫——`no such table` 与 `no such column` 均按失败返回 nil（装配层同退该源），不静默置零。
- 只读 `open_v2`、打开失败释放句柄（729 行注释）、`busy_timeout 1s`、`defer close`；`isKimiModel` 过滤与日桶规则照抄 `scanZCodeModelDays`。
- 头部注释记录：为什么独立 reader（红线：不动 token 扫描 SQL）、行集一致性要求、失败同退语义。

### Task 3: 卡片注册与数据流

**Files:**
- Modify: `Sources/PanelCustomization.swift`（`KimiPanelCardID` 加 `case cache`「缓存命中」）
- Modify: `KimiUsage.swift`（数据流 + 注册 + 既有断言更新）

**Step:**
1. `aggregateBothDetailed()` 增 `cacheModelDays`（六源合并，zcode 失败同退）；`UsagePanelModel` 增 `CacheSection`（rows 三窗口预计算，模式对齐 5481 行 `toolWindows` 惯例；分母直接取现有各模型窗口 input）。
2. `buildPanel` switch（2836-2856）增 `.cache` case；控制器加 `cachePeriodIndex = 1` 与周期 action（照抄 `toggleToolPeriod` 3148）。
3. 既有断言同步：3334、3388 与同型 title 序列断言扩为 6 张、6694 customLayout 断言、preview 模型构造点（6281/6336/6519 区域）补 section、6534 卡片标题映射。
4. 断言补两条：旧 5 卡配置 `normalized()` 后 cache 追加末尾；设置列表 6 行完整。

### Task 4: 卡片视图

**Files:**
- Modify: `KimiUsage.swift`（`CacheSectionView`）

**Step:** 周期行（今日/近 7 天/近 30 天，默认近 7 天，in-memory）；按 UI 规格渲染；「整体」置顶行、`—` 规则、除零守卫、空态文案；`--visual-preview` 注入固定 fixture（模式对齐 `previewAPIDays` 5646），守门断言卡片出现、整体行与 `—` 文案。

### Task 5: 全量验证与文档

- `bash build.sh` 通过；`--self-test` 全绿（新增 8+5+2 断言）。
- 真机验收：
  - 缓存卡各源至少抽 1 模型与手工对拍一致（ZCode sqlite 取 `cache_read_input_tokens` 求和 / Work+CLI wire `jq` 取 `inputCacheRead` 求和 / Proma+Claude `jq` 取 `cache_read_input_tokens` / hermes sqlite 缓存列）；
  - **升级前后「用量情况」三周期总量与模型行完全一致**（红线直接证据）；
  - 隐藏/排序/恢复默认后其余 5 卡无布局回归；设置列表 6 行；首次启动 revision bump 重建后无性能异常；
  - `—` 行为实测（找一个窗口内无缓存的模型，如 deepseek 类或新模型）。
- `README.md`「能做什么」补一条；「统计口径」补命中率口径（input 含缓存、全来源合并、`—` 规则）。
- `CHANGELOG.md` 增条目；本文档标记实现完成日期；grep `docs/project/` 卡片数枚举同步。

## 验收清单

- [ ] 回归断言 15 项全绿，fixture 不触真实库/会话
- [ ] 卡片出现在设置列表（6 行），默认末位可见，可隐藏/排序/恢复默认；旧配置升级自动补末尾
- [ ] 命中率与各源手工对拍一致（每源至少 1 模型）
- [ ] 无缓存模型显示 `—` 非 0%；`input ≤ 0` 不进分母；ZCode reader 失败时该源同退、其余来源数字不受影响
- [ ] **用量情况三周期数字升级前后零变化**；其他 5 卡零回归
- [ ] 无新文件（build.sh 零改动）、无新网络请求、无新定时器、无凭据触碰

---

## 迭代 v2（2026-11-16 用户确认）：来源行 + 点击展开该源模型行

首版已部署（merge 1e6b1a1，模型行平铺）。v2 把行结构改为「来源行 + 展开模型」，实现按 harness 对比命中率。

**行结构：**

```text
缓存命中                        [今日 | 近 7 天 | 近 30 天]
──────────────────────────────
整体                     97% 命中 · 输入196M
› ZCode                  98% 命中 · 输入82M
⌄ Kimi Code              97% 命中 · 输入12M
    K3.1 Pro             97% 命中 · 输入11.2M
    kimi-for-coding      — 命中 · 输入0.8M
› Kimi Work              96% 命中 · 输入8M
```

**数据侧（扫描层零改动）：**
- 六源各自成对：Work = `st.work`；Kimi Code / Proma / Claude = `st.cli` 按 `fileToolStats` 同款 root 分区（apiSessionsRoots[0] / [1...2] / [3]，cacheDays 与 modelDays 必须同区拆，防分子分母错位）；Hermes = `st.hermes`；ZCode = 独立 reader（nil → 该源从整体与来源行同退）。
- `assembleCacheSnapshot` 改为按源保留快照对；「整体」= 保留源合并（数学不变）。
- 规则沿用：零用量源不显示行（工具明细 2026-11-07 决定）、无缓存证据 `—`、`input ≤ 0` 不进分母、来源行按窗口 input 降序（tie 按 ToolID 固定序）；「整体」行不可展开。

**交互（对齐用量情况 bucket 模式）：**
- 来源行 chevron 点击展开/收起该源模型行（缩进次要样式）；`expandedCacheSources: Set<String>` in-memory（对齐 `expandedUsageBuckets`，不落盘）；键盘与 AX 标签对齐用量情况 bucket 行现状。

**视觉对齐硬约束：**
- 复用用量情况 bucket 行/展开明细行的控件样式与尺寸（chevron、行高、缩进、悬停高亮、数字 monospacedDigits 右对齐）；卡头/周期行/圆角边距零新样式；深浅色双态不分叉；无新分隔线、无脚注、无来源后缀解释文案。

**断言新增（约 6 条）：**
1. per-source 命中率精确（多源不同率 fixture）。
2. cli/proma/claude 按 root 分区正确（同文件状态不跨源泄漏）。
3. ZCode reader 失败 → 该源行与整体均不含其贡献，其余源不变。
4. 零用量源隐藏；input≤0 不进任何行。
5. 嵌套模型行归属正确（同模型跨源各自显示该源数字）。
6. 展开状态切换不影响数据（preview 交互守门：展开/收起 + 嵌套行文案）。

**验收：** 离线全绿 + preview 截图核对深浅色对齐 + 真机部署后目视（沿用首版 ZCode 精确基线）。版本落 v1.7.11（CHANGELOG 条目并入）。

### 迭代 v2.1（2026-11-16 用户 3x 截图诊断）：视觉对齐修正

三处缺陷修复（数据层零改动，守门断言先红后绿）：

1. **卡头周期 pill 换行**：periodNames 改为与工具明细逐字同款 `["今日", "7 天", "30 天"]`（长标签在 330pt 卡头把 pill 组挤到标题第二行）；AX 同步短标签显示名；窗口口径不变（默认 index 1 = 近 7 天）。上文 UI 规格中「对齐 5412 行命名」细则据此同步修订。
2. **数值列化**：detail 由单 label 自由文本拆为两列——hit 列固定宽 62pt（「100% 命中」11pt monospacedDigits 自然宽度 57pt + 余量）、input 列固定宽 78pt（「输入999.99M」自然宽度 72pt + 余量）、列间 8pt gap（行内 stack spacing）；三行类型（整体/来源/嵌套模型）共用同一套常量（`CacheDetailColumns`），跨行「命中」「输入」起点垂直对齐。注意 wrapping label 自带 ±2pt 对齐内缩，列缘语义按 alignmentRect 度量（守门 B 同此口径）。嵌套行缩进只作用名称列（10pt），数值列不随缩进平移。
3. **层级呼吸感**：整体行与来源组之间 customSpacing 4（对齐工具明细末行节奏）；展开组尾行与下一来源行之间 customSpacing 2；其余行距走默认 5。行高/内边距沿用 TokenBucketRow/TokenDetailRow 实际常量（2pt 垂直内边距、hover 0.08、圆角 5）。

守门新增：周期 pill 短标签 AX + 与卡头同行（frame midY）、三行类型列缘 alignmentRect 精确等于共享常量且 gap 8pt、spacing rhythm 4/2 读回（`stack.customSpacing(after:)`）。
