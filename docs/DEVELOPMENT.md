# 开发与维护

从源码构建（开发者，需要 Xcode Command Line Tools，未装先执行 `xcode-select --install`）：

```bash
./build.sh
```

发布新版本（开发者，要求工作区干净且已推送）：`scripts/release.sh v1.2.3`——创建本地 tag → 构建与离线自测 → 签名及 DMG/zip 校验 → 推送 tag → 创建 GitHub Release。若同名 Release 已存在（人工创建或上次上传中断），会补传/替换完整附件。验证失败不会推送远端 tag。

## 原理

- **凭据**：读取 Kimi 桌面端本地配置文件 `~/Library/Application Support/kimi-desktop/daimon-share/daimon/config.json`，不在本仓库保存任何凭据
- **月度接口 401**：读取最新 refresh token；写回前重新读取最新 JSON，仅合并 Kimi Web 认证字段，以唯一临时文件和同目录原子替换保存，并限制为仅所有者可读写。若检测到 Kimi 客户端已轮换 access/refresh token，则保留客户端版本。由于官方客户端不使用共享文件锁，检查与替换之间仍无法完全消除并发写入窗口
- **配额**：通过 Kimi 远程接口查询 5 小时、7 天和月度额度
- **Token**：扫描本地会话 wire.jsonl / 客户端 JSONL 日志，并只读查询 ZCode、Hermes 的 sqlite 用量表聚合。ZCode 以 `model_usage` 逐请求表为唯一来源；输入包含缓存读取/创建，不重复加 cache 字段。近 7 天和近 30 天均包含今天。混接客户端缺失模型名时不归属 Kimi；可信 Kimi Code 旧格式可兼容并归入「未知模型」。ZCode 暂时不可读时保留最近成功快照并提示，其他来源继续更新。Work 优先按请求 ID，或同一 agent 的 `llm.request` 与 `turnStep` 关联模型和双写用量；同一请求内用量一致且两侧各一条的 `usage.record` / `step.end` 只计一次，不受工具执行耗时限制。没有请求上下文的旧日志仍只匹配时间和位置邻近的事件。保留独有历史调用和压缩用量，跳过子任务完成汇总；只有缺少可靠模型依据的用量才进入「未知模型」。
- **模型明细**：`scan-state-v6.json` 按「日 × 模型」保存文件贡献，ZCode 与 Hermes 同步保留模型维度；周期汇总和展开行从同一数据源计算，模型输入、输出之和等于汇总。Work 扫描修订 v4 会重建旧文件贡献，保留 sqlite 增量快照；文件追加后重扫 Work 请求上下文，未变化文件直接复用缓存。两个用量板块的周期整行分别控制展开与收起，数字列与汇总行共用等宽布局。
- **模型别名**：聚合时移除 `kimi-code/` 提供商前缀，合并同一模型在各客户端及旧缓存中的用量；当前显示为 `K3.1 Pro`、`K3-256k`、`K3`、`Kimi for Coding`。`k3` 与 `k3-256k` 保持独立，`kimi-for-coding` 保留入口名称，不依据当前客户端标签回填历史版本；其他模型 ID 继续独立显示。归并不改变各周期输入、输出或总量。

## 隐私与安全

- 本地会话和用量数据库用于本机统计；额度查询向 Kimi 服务发送认证信息，检查更新会访问 GitHub。
- 月度登录信息续期时会更新 Kimi 桌面端本地配置中的认证字段，不在本仓库保存凭据。

面板打开时优先更新额度，月度和本地扫描按周期执行；手动刷新执行全部项目。应用内更新绑定选定 Release 和当前运行的应用路径，校验目标版本、正在运行的副本与 LaunchAgent 后换包，失败时尝试回滚。

## 调试与自检

```bash
# 离线自检：只用临时目录和假凭据，不访问真实凭据、网络或会话缓存
./KimiUsage.app/Contents/MacOS/KimiUsage --self-test

# 纯本地 token 对账：不读取凭据、不联网、不写扫描状态，只读聚合并打印两类统计
./KimiUsage.app/Contents/MacOS/KimiUsage --tokens-once

# 固定假数据交互预览：不读取凭据、扫描缓存或写入状态，也不联网
./KimiUsage.app/Contents/MacOS/KimiUsage --visual-preview
# 可附加 --visual-preview-models / --visual-preview-dark / --visual-preview-narrow /
# --visual-preview-empty / --visual-preview-states / --visual-preview-long 检查模型明细、外观和异常状态
# --visual-preview-states --visual-preview-test 覆盖板块折叠、三周期展开、刷新状态和数字列坐标对齐

# 脚本回归：PATH mock 故障注入，不操作真实 app、LaunchAgent 或 GitHub
python3 -m unittest discover -s tests -p '*_test.py'
```

## 文件说明

| 文件 | 说明 |
|---|---|
| `KimiUsage.swift` | 全部源码（单文件 SwiftUI/AppKit 菜单栏应用） |
| `build.sh` | 编译 + 打包 + ad-hoc 签名脚本 |
| `Info.plist` | App Bundle 配置（LSUIElement = 菜单栏常驻） |
| `AppIcon.icns` / `AppIcon.iconset/` | 应用图标 |
| `icon_gen.py` | 图标生成脚本 |
| `icon_*.png` | 图标设计候选稿 |
| `scripts/update.sh` | Release 下载、暂存、换包、健康检查与失败回滚 |
| `scripts/release.sh` | 本地 tag、构建测试、资产校验与 GitHub Release 发布 |
| `tests/script_test.py` | 更新、发布、签名故障的离线回归测试 |

## License

MIT，详见 [LICENSE](../LICENSE)。
