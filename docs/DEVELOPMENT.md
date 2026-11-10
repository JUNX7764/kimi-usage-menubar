# KimiUsage 开发与维护

> **当前工程事实源**。构建、测试、发布或权限行为变化时，应在同一个提交中更新本文。
> 最后核对：2026-11-10。

## 文档入口与效力

| 文档 | 用途 |
|---|---|
| `README.md` | 面向用户的功能、安装、更新与隐私说明 |
| `docs/DEVELOPMENT.md` | 当前构建、测试、发布和验证边界 |
| `docs/project/02-architecture.md` | 当前模块、数据流和信任边界 |
| `docs/project/07-standards.md` | 当前维护与测试约定 |
| `docs/project/10-release.md` | 当前发布资产、门禁和回滚边界 |

判断当前行为时，优先级为：**源码与测试 → 当前工程文档 → README**。不得用空模板或历史发布记录证明现状。

## 构建

需要 macOS 13 或更新版本、Apple Silicon 和 Xcode Command Line Tools；未安装 CLT 时先执行 `xcode-select --install`。

```bash
./build.sh
```

`build.sh` 会重建项目内的 `KimiUsage.app`，并执行 ad-hoc 签名验证。版本号来自 Git 标签；拆分源码时必须保留合法 top-level 入口并同步调整构建脚本。

## 原理与数据边界

- **凭据**：读取 Kimi 桌面端本地配置文件 `~/Library/Application Support/kimi-desktop/daimon-share/daimon/config.json`，不在本仓库保存任何凭据
- **月度接口 401**：读取最新 refresh token；续期请求进程内单飞（月度与账号两条 401 链共享同一次刷新结果），写回前重新读取最新 JSON，仅合并 Kimi Web 认证字段，跨进程写入经 `flock` 互斥，以唯一临时文件和同目录原子替换保存，并限制为仅所有者可读写。若检测到 Kimi 客户端已轮换 access/refresh token，则保留客户端版本。由于官方客户端不使用共享文件锁，检查与替换之间仍无法完全消除并发写入窗口
- **配额**：通过 Kimi 远程接口查询 5 小时、7 天和月度额度
- **头部账号行**：`GET https://www.kimi.com/api/user`（Kimi Web 认证）取昵称与手机号；手机号由服务端打码返回，客户端原样展示。Kimi 账号可能为手机号/微信注册，无 email 字段，账号行显示「昵称（打码手机号）」，两者皆缺时隐藏。随月度接口同在慢轮刷新，401 走相同的 refresh→重试链，失败保留旧值
- **面板卡片布局**：固定头部与底部操作区，中间滚动区按额度、用量情况、用量简析、工具明细分为四张卡片；卡片只重组现有视图，不改变数据快照、默认展开状态或更新链路。面板宽 330pt（窄预览 300pt），卡片圆角 14pt、内容边距 10pt，浅色以中性表面和轻阴影分层，深色以表面色差和描边为主。工具占比条固定 72pt，为完整工具名称保留空间，并按 `ToolID` 固定分色，不随周期或用量排序变化；展开、收起和异步刷新仍实时调整 Popover 高度，超过屏幕可用高度 85% 后内部滚动。
- **Token**：扫描本地会话 wire.jsonl / 客户端 JSONL 日志，并只读查询 ZCode、Hermes 的 sqlite 用量表聚合。ZCode 以 `model_usage` 逐请求表为唯一来源；输入包含缓存读取/创建，不重复加 cache 字段。近 7 天和近 30 天均包含今天。混接客户端缺失模型名时不归属 Kimi；可信 Kimi Code 旧格式可兼容并归入「未知模型」。ZCode 暂时不可读时保留最近成功快照并提示，其他来源继续更新。Work 优先按请求 ID，或同一 agent 的 `llm.request` 与 `turnStep` 关联模型和双写用量；同一请求内用量一致且两侧各一条的 `usage.record` / `step.end` 只计一次，不受工具执行耗时限制。没有请求上下文的旧日志仍只匹配时间和位置邻近的事件。保留独有历史调用和压缩用量，跳过子任务完成汇总；只有缺少可靠模型依据的用量才进入「未知模型」。
- **模型明细**：`scan-state-v6.json` 按「日 × 模型」保存文件贡献，ZCode 与 Hermes 同步保留模型维度；周期汇总和展开行从同一数据源计算，模型输入、输出之和等于汇总。Work 扫描修订 v4 会重建旧文件贡献，保留 sqlite 增量快照；文件追加后重扫 Work 请求上下文，未变化文件直接复用缓存。用量情况板块的周期整行控制展开与收起，模型明细行与表头四列对齐，数字列与汇总行共用等宽布局。
- **用量情况（v1.5 合并板块）**：「用量情况」合并展示本机全部已适配来源（Kimi Work 与 API 客户端）的今日/近 7 天/近 30 天用量。合并口径：本机 Kimi 模型统计，可能包含 API、不同账号或订阅归属未确认的记录，不代表订阅账单；面板不设统计范围入口，口径以本文为准。既有去重（Work 镜像、Proma 并行日志、ZCode 唯一 model_usage 来源）在聚合前生效。
- **逐工具维度**：工具明细展示 Kimi Work、Kimi CLI、Proma、Claude Code、ZCode、Hermes 六类来源的周期用量与占比（分母为同周期同一快照的合并总量）。状态语义：可读取 / 可读取无记录 / 标准路径未发现（不等于未安装）/ 部分记录·缓存（本轮读取失败，保留上次快照，不清零）/ 可读取·近似归日（Hermes 累计行差分按 last_seen 归日，非逐请求日期）。sqlite 来源卸载（库文件消失但窗口内仍有历史快照）时保留历史计入合并与比较、不算读取失败，行标「标准路径未发现」，快照随 31 天窗口自然过期；「暂时不可读」（库存在但读取失败）仍按部分记录·缓存提示。逐工具窗口之和等于合并总量（原始精度）。
- **用量简析与比较**：近 30 天每日柱状图复用同一份按日聚合（不新增扫描或网络调用）；首轮本地扫描完成前，缺键日与比较统一显示「数据不足」，不得显示全零或持平。扫描完成后，某日仅当覆盖可证实才可为 0，来源读取失败时缺键日显示缺失占位。比较条「较昨日 / 较前 7 天」以 D=今天、本地日历日运算（Calendar，覆盖 DST 与跨月）：仅当失败来源在比较区间 [D-13, D] 内无贡献时给出百分比，否则固定「数据不足」；基期为 0 且本期为正显示「新增」，两期相等显示「持平」，不产生无穷百分比。日图与比较不是官方账号统计，不代表账号全部用量。
- **窗口口径**：今天及含今天的近 7 天（D−6…D）/ 近 30 天（D−29…D）均为本地日历日，`windowCutoffs` 使用 `Calendar.date(byAdding:)`（v1.5 起；此前固定 86400 秒在 DST 日界会漂移一天）。
- **模型别名**：聚合时移除 `kimi-code/` 提供商前缀，合并同一模型在各客户端及旧缓存中的用量；当前显示为 `K3.1 Pro`、`K3-256k`、`K3`、`Kimi for Coding`。`k3` 与 `k3-256k` 保持独立，`kimi-for-coding` 保留入口名称，不依据当前客户端标签回填历史版本；其他模型 ID 继续独立显示。归并不改变各周期输入、输出或总量。
- **自诊断状态**：`status.json` 的内容指纹剔除每轮变化的 `lastAttemptAt`；内容变化时立即原子写入，稳定内容仅按 60 秒心跳写入。只有写盘成功才推进内容指纹与心跳时间，失败时下轮可补写；因此诊断文件中的最近尝试时间在稳定状态下最多滞后一个心跳周期。

本地会话和数据库仅用于本机统计；额度查询会向 Kimi 服务发送必要认证信息，更新检查会连接 GitHub。月度登录信息续期会修改 Kimi 桌面端本地配置中的认证字段。

## 调试与自检

```bash
# 离线自检：临时目录和假凭据，不访问真实凭据、网络或会话缓存
./KimiUsage.app/Contents/MacOS/KimiUsage --self-test

# 纯本地 Token 对账：不读取凭据、不联网、不写扫描状态
./KimiUsage.app/Contents/MacOS/KimiUsage --tokens-once

# 固定假数据交互预览：不读取真实状态、不联网
./KimiUsage.app/Contents/MacOS/KimiUsage --visual-preview
./KimiUsage.app/Contents/MacOS/KimiUsage --visual-preview-states --visual-preview-test

# 脚本回归：PATH mock，不操作真实 app、LaunchAgent 或 GitHub
python3 -m unittest discover -s tests -p '*_test.py'

# Shell 语法检查
bash -n build.sh scripts/update.sh scripts/release.sh
```

视觉预览可附加 `--visual-preview-models`（展开模型明细）、`--visual-preview-tools`（展开工具明细）、`--visual-preview-dark`、`--visual-preview-narrow`、`--visual-preview-empty`、`--visual-preview-states` 或 `--visual-preview-long`。`--once` 会读取真实登录态并联网，不属于离线测试；等待超时（45s）以非零退出码报告。

另有内部测试旗标（发布与用户路径不依赖）：`--visual-preview-full`、`--visual-preview-popover-test=<目录>`、`--visual-preview-update-test`、`--visual-preview-key-test`、`--visual-preview-updating`、`--visual-preview-updating-install`、`--visual-preview-output=<路径>`、`--visual-preview-scroll-end`。入口支持 `--help`；未识别的 `--` 旗标会打印错误并以退出码 2 拒绝启动，不会静默拉起常驻应用。

## 文件说明

| 文件 | 说明 |
|---|---|
| `KimiUsage.swift` | 当前全部 Swift 源码；单文件 AppKit 菜单栏应用 |
| `build.sh` | 编译、打包和 ad-hoc 签名 |
| `Info.plist` | Bundle 身份、最低系统版本和菜单栏常驻配置 |
| `AppIcon.icns` | 应用图标（`AppIcon.iconset/` 为本机生成中间产物，不入库） |
| `scripts/icon_gen.swift` | 图标生成脚本 |
| `scripts/update.sh` | Release 下载、校验、暂存、换包和失败回滚（含中断自愈） |
| `scripts/release.sh` | 标签、构建、自检、资产校验和 GitHub Release 发布 |
| `tests/script_test.py` | 更新、发布和签名故障的离线回归测试 |

## 发布前必须执行

```bash
git status --short
./build.sh
./KimiUsage.app/Contents/MacOS/KimiUsage --self-test
python3 -m unittest discover -s tests -p '*_test.py'
bash -n build.sh scripts/update.sh scripts/release.sh
```

确认工作区干净且 HEAD 已推送后，再运行 `scripts/release.sh v1.2.3`。

`release.sh` 会执行构建、二进制自检、签名和资产校验，但**不会自动运行 Python 脚本回归，也不代表真实面板更新、回滚或最低系统版本验收已完成**。完整要求见 `docs/project/10-release.md`。

## 验证证据边界

- 离线自检与 PATH mock 不能替代真实 Kimi 登录态、网络接口、LaunchAgent 或安装目录权限验证。
- macOS 13 部署目标不等同于已在 macOS 13、14、15 或干净用户环境完成实机验收。
- 真实更新验收必须明确记录旧版版本、目标版本、安装路径、是否从面板点击，以及重启和回滚结果。

## License

MIT，详见 [LICENSE](../LICENSE)。
