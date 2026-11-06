# KimiUsage 开发与维护

> **当前工程事实源**。构建、测试、发布或权限行为变化时，应在同一个提交中更新本文。
> 最后核对：2026-11-06。

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
- **月度接口 401**：读取最新 refresh token；写回前重新读取最新 JSON，仅合并 Kimi Web 认证字段，以唯一临时文件和同目录原子替换保存，并限制为仅所有者可读写。若检测到 Kimi 客户端已轮换 access/refresh token，则保留客户端版本。由于官方客户端不使用共享文件锁，检查与替换之间仍无法完全消除并发写入窗口
- **配额**：通过 Kimi 远程接口查询 5 小时、7 天和月度额度
- **Token**：扫描本地会话 wire.jsonl / 客户端 JSONL 日志，并只读查询 ZCode、Hermes 的 sqlite 用量表聚合。ZCode 以 `model_usage` 逐请求表为唯一来源；输入包含缓存读取/创建，不重复加 cache 字段。近 7 天和近 30 天均包含今天。混接客户端缺失模型名时不归属 Kimi；可信 Kimi Code 旧格式可兼容并归入「未知模型」。ZCode 暂时不可读时保留最近成功快照并提示，其他来源继续更新。Work 优先按请求 ID，或同一 agent 的 `llm.request` 与 `turnStep` 关联模型和双写用量；同一请求内用量一致且两侧各一条的 `usage.record` / `step.end` 只计一次，不受工具执行耗时限制。没有请求上下文的旧日志仍只匹配时间和位置邻近的事件。保留独有历史调用和压缩用量，跳过子任务完成汇总；只有缺少可靠模型依据的用量才进入「未知模型」。
- **模型明细**：`scan-state-v6.json` 按「日 × 模型」保存文件贡献，ZCode 与 Hermes 同步保留模型维度；周期汇总和展开行从同一数据源计算，模型输入、输出之和等于汇总。Work 扫描修订 v4 会重建旧文件贡献，保留 sqlite 增量快照；文件追加后重扫 Work 请求上下文，未变化文件直接复用缓存。两个用量板块的周期整行分别控制展开与收起，数字列与汇总行共用等宽布局。
- **模型别名**：聚合时移除 `kimi-code/` 提供商前缀，合并同一模型在各客户端及旧缓存中的用量；当前显示为 `K3.1 Pro`、`K3-256k`、`K3`、`Kimi for Coding`。`k3` 与 `k3-256k` 保持独立，`kimi-for-coding` 保留入口名称，不依据当前客户端标签回填历史版本；其他模型 ID 继续独立显示。归并不改变各周期输入、输出或总量。

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

视觉预览可附加 `--visual-preview-models`、`--visual-preview-dark`、`--visual-preview-narrow`、`--visual-preview-empty`、`--visual-preview-states` 或 `--visual-preview-long`。`--once` 会读取真实登录态并联网，不属于离线测试。

## 文件说明

| 文件 | 说明 |
|---|---|
| `KimiUsage.swift` | 当前全部 Swift 源码；单文件 AppKit 菜单栏应用 |
| `build.sh` | 编译、打包和 ad-hoc 签名 |
| `Info.plist` | Bundle 身份、最低系统版本和菜单栏常驻配置 |
| `AppIcon.icns` / `AppIcon.iconset/` | 应用图标 |
| `icon_gen.py` | 图标生成脚本 |
| `scripts/update.sh` | Release 下载、校验、暂存、换包和失败回滚 |
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
