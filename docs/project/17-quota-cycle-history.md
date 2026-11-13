# 额度周期回顾

> 当前功能口径。最后核对：2026-11-13。实现以 `Sources/QuotaCycle*.swift` 与测试为准。

## 用户可见行为

「额度周期回顾」位于「用量简析」之后、「工具明细」之前，是第五张常规卡片，默认展开且可独立折叠。

- 只记录 Kimi **7 天额度窗口**，不混入 5 小时、月度额度或本地 Token 统计。
- 每轮灰柱表示 100% 上限，Kimi 动态蓝柱表示已用比例；零用量是低基线，缺失不是零。
- 每屏最多 6 轮，默认最新页，当前轮在最右。首批可浏览最近 12 轮；到已加载最旧页后可用「更早记录」每次再扩展 12 轮，存储不设 12 轮上限。
- 悬停临时查看，点击固定选择，左右键逐组并跨页；刷新和本进程关闭重开保留选择/页位置，重启恢复最新页，凭据作用域变化立即重置。
- 详情使用百分比，不显示推算 Token 上限、跨周期浪费总量或平均利用率。

历史从首次成功读取 7 天额度后开始，不回填安装前记录。没有充值卡、主动用卡或被动重置原因分类。

## 视觉结构

- 卡片采用与 CodexUsage 用量简析同构的层级：标题行、主数值、柱图、状态条。翻页按钮与页码位于标题行，折叠箭头保持最右。
- 主数值为当前展示轮次的已用百分比，19pt semibold 等宽数字配 10pt「已用」；右侧仅保留灰色「上限 100%」图例，不设置额外纵轴或「当前」图例。
- 图布固定 61pt，柱区 46pt；每根灰柱/已用柱宽 6pt，同组间隙 3pt，圆角 1pt。当前轮的已用柱为描边空心，已结束轮为实心；零用量保留低基线。
- 选中只增加 `labelColor@0.07` 的列底并强化日期字色，柱体透明度不随选择改变。日期以 9pt 等宽数字直接绘制在图布内。
- 不足 6 轮时仍按六列计算固定槽宽，实际分组整体居中；不绘制假柱、占位日期或额外空组。
- 完整双行详情在图内浮层展示，浮层不拦截命中、不增加卡片高度。图下 32pt 状态条仅显示简洁状态与既有剩余语义；完整文案保留在 tooltip 与 VoiceOver。

## 观测与结束语义

每条样本只来自本次 `GET /coding/v1/usages` 的有效 7 天响应：比例有限且在 0...1、reset 存在、该窗口无错误。请求失败、缺字段或 merged 保留的旧值不入账；历史不增加请求，也不等待月度、账号或本地扫描慢轮。

轮次是接口窗口，不是本机日历周：

- 首轮开始时间用 `resetAt - 7 天` 推算，并标记记录不完整；不宣称完整观测七天。
- 同一 reset（±120 秒容差）且比例不减时更新当前轮。等值新请求只推进内存最后观测，不增加 evidence。
- 同 reset 比例下降至少 1 个百分点时保留「额度回修／窗口变化待确认」候选，不用新读数覆盖已确认当前轮。
- reset 前移且观测连续时，先用第一笔新窗口样本创建候选，再由 10–180 秒内不同 requestStartedAt 的同窗口样本确认；同笔重放和过快样本不确认。
- 越过旧截止的确认轮换记「正常到期」，包括 0→0；旧截止前的确认变化只记「窗口变化（原因未知）」，不归因官方或用户操作。
- 窗口变化前连续观测中断超过 15 分钟时，旧段记「观测缺口」，新段开始未知；不补零、不推断漏过几轮。
- reset 回拨、第三窗口、非有限值、越界和乱序请求不进入已确认历史。

详情始终使用 `lastObservedUsedPercent` 与 `remainingAtLastObservation`：最后观测不是精确终点值。正常到期未采到终点时显示「到期未用约」；异常变化显示「窗口变化前剩余约」；缺口不计算确定剩余。只有原始值等于 100 才标「已用满」，99.6 即使显示为 100% 也不算用满。

## 本地存储与隐私

生产目录：

```text
~/Library/Application Support/KimiUsage/quota-history/
├── scope-salt
└── <64 位小写作用域哈希>/history-v1.json
```

- root 下随机生成 32 字节 salt；作用域为 `SHA256("kimi-quota-cycle-v1\\0" + salt + UTF8(apiKey))`。原始 API Key、无盐哈希、salt、昵称、手机号、token、请求头和原始响应不写入历史 JSON。
- root/分区目录为 0700，salt/history 文件为 0600；保存复用 `AtomicJSONFile` 原子替换。
- API Key 变化会进入新分区并重新记录，旧分区不展示。轮换后暂时看不到旧历史是避免跨账号串联的刻意降级。
- 首次、真实内容变化和五分钟心跳保存；等值样本不每 10 秒写盘。候选、确认和回滚立即保存。
- 写失败保留最后成功磁盘状态，本进程继续记录并提示「历史未保存」，下次成功清除。
- 损坏或未来 schema 加载失败后禁止自动覆盖原文件；界面显示中性读取状态和失败提示。

`QuotaCycleSnapshot` 只含展示模型和进程内 generation，不含凭据。后台协调器串行执行 load → reduce → persist；UI 主线程再次核对 generation，旧作用域或旧代际回调不得覆盖新账号。

## 模块边界

| 文件 | 职责 |
|---|---|
| `Sources/QuotaCycleHistory.swift` | 观测模型、状态机、快照、浏览器与固定预览数据 |
| `Sources/QuotaCycleStore.swift` | 加盐作用域、权限、版本校验、原子保存与保存节奏 |
| `Sources/QuotaCycleCoordinator.swift` | 串行读写、作用域代际、失败回退与快照交付 |
| `Sources/QuotaCycleHistoryView.swift` | AppKit 双柱、图内浮层、状态条、分页、选择、键盘和 VoiceOver |
| `KimiUsage.swift` / `AppDelegate` | 现有刷新样本 gate、生产协调器和面板状态接入 |
| `main.swift` | 唯一 Swift 顶层可执行入口 |

## 验证

独立模型/持久化 runner：

```bash
python3 -m unittest discover -s tests -p 'quota_cycle_history_test.py' -v
```

完整离线回归与原生预览：

```bash
./build.sh
./KimiUsage.app/Contents/MacOS/KimiUsage --self-test
python3 -m unittest discover -s tests -p '*_test.py' -v
./KimiUsage.app/Contents/MacOS/KimiUsage --visual-preview --visual-preview-quota-history --visual-preview-test
./KimiUsage.app/Contents/MacOS/KimiUsage --visual-preview --visual-preview-quota-geometry
./KimiUsage.app/Contents/MacOS/KimiUsage --visual-preview-narrow --visual-preview-quota-geometry
```

固定形态旗标：`--visual-preview-quota-one`、`--visual-preview-quota-six`、`--visual-preview-quota-long`、`--visual-preview-quota-short`、`--visual-preview-quota-empty`、`--visual-preview-quota-pending`、`--visual-preview-quota-save-failed`、`--visual-preview-quota-load-failed`、`--visual-preview-quota-cross-year`。均可与 `--visual-preview-dark`、`--visual-preview-narrow` 或现有输出/背景旗标组合。所有预览只用内存假数据，不创建真实历史目录。

原始功能证据见 `docs/verification/2026-11-12-quota-cycle-history.md`，本轮视觉重构见 `docs/verification/2026-11-13-quota-cycle-history-visual-polish.md`。离线测试与假数据原生预览不等于真实账号长期跨周期观测；Cua 前台实际输入仍需明确授权后补验。
