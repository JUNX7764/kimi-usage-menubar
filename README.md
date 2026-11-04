# KimiUsage — Kimi 订阅余量菜单栏小工具

macOS 菜单栏常驻，一瞥即知 Kimi 订阅的配额余量。原生 Swift 单文件实现，纯本地运行。

与 [GlmUsage](https://github.com/JUNX7764/Glmusage)、[CodexUsage](https://github.com/JUNX7764/Codexusage) 是同族三件套，分别盯 Kimi / GLM / Codex 的订阅余量。

## 功能

- **配额用量**：5 小时窗口 / 7 天 / 月度配额的使用比例与重置时间
- **Token 统计**：扫描本地会话日志与只读用量数据库，统计今天 / 近 7 天 / 近 30 天的 input/output 消耗（近 7/30 天为含今天共 7/30 个日历日，2026-11-03 起）
  - Kimi Work 本地会话（kimi-desktop daimon）
  - API 客户端会话：ZCode、Kimi Code CLI、Proma、Claude Code、Hermes Agent 等客户端中实际走 Kimi / Moonshot 模型的用量（按会话内的模型与接口地址字段甄别，其他模型的用量不计入）
  - ZCode 以 `model_usage` 逐请求表为唯一来源，自动回填数据库保留的历史；不叠加 `turn_usage` 或并行日志，input 已含缓存读取/创建，不重复加 cache 字段
  - 已安装来源全部不可读时保留旧值并显示错误与 ⚠️ 过期标注，不静默沿用旧数据充当新鲜
- **菜单栏**：常驻，纯本地运行，数据不上传
- **刷新机制**
  - 5H / 7D 每 30 秒；月度额度与两类会话扫描每 300 秒；手动刷新执行完整刷新
  - 各窗口分别保留最后成功时间；失败时保留旧值，同时显示刷新错误与过期状态
  - 打开面板即触发一轮全量刷新；面板打开时数据会更新
  - 「最近尝试刷新」表示请求开始时间

## 安装与更新

需要 macOS 13+。安装：到 [Releases](https://github.com/JUNX7764/kimi-usage-menubar/releases) 下载最新 `KimiUsage.dmg`，打开后把 KimiUsage 拖进 Applications（或 `~/Applications`）双击运行。首次打开如遇 Gatekeeper 提示，右键 → 打开。

**更新**：发布新 Release 后（每 30 分钟检查一次，打开菜单也会触发一次节流检查），菜单最上方出现「⬆ 新版本可用，点击更新」，点击即自动下载替换并重启（zip 经 SHA256 校验后才替换）。更新检查和下载只认 `KimiUsage.zip` 与 `.sha256` 附件齐全的 Release；最新 Release 缺附件时自动选择最近的可安装版本，不会再对空 Release 发起必然 404 的下载。点击面板底部版本号可手动检查并查看结果。日常代码提交不会触发更新提示——只有正式发版才会。

从源码构建（开发者，需要 Xcode Command Line Tools，未装先执行 `xcode-select --install`）：

```bash
./build.sh
```

发布新版本（开发者，要求工作区干净且已推送）：`scripts/release.sh v1.2.3`——创建本地 tag → 构建与离线自测 → 签名及 DMG/zip 校验 → 推送 tag → 创建 GitHub Release。若同名 Release 已存在（人工创建或上次上传中断），会补传/替换完整附件。验证失败不会推送远端 tag。

## 原理

- **凭据**：只读 Kimi 桌面端本地配置文件 `~/Library/Application Support/kimi-desktop/daimon-share/daimon/config.json`，不在本仓库保存任何凭据
- **月度接口 401**：读取最新 refresh token；写回前重新读取最新 JSON，仅合并 Kimi Web 认证字段，以唯一临时文件和同目录原子替换保存，并限制为仅所有者可读写。若检测到 Kimi 客户端已轮换 access/refresh token，则保留客户端版本。由于官方客户端不使用共享文件锁，检查与替换之间仍无法完全消除并发写入窗口
- **配额**：调用 Kimi 官方本地接口查询
- **Token**：扫描本地会话 wire.jsonl / 客户端 JSONL 日志，并只读查询 ZCode、Hermes 的 sqlite 用量表聚合

## 隐私与安全

- 纯本地运行，数据不上传
- 凭据只读，不在本仓库保存任何凭据

## 调试与自检

```bash
# 离线自检：只用临时目录和假凭据，不访问真实凭据、网络或会话缓存
./KimiUsage.app/Contents/MacOS/KimiUsage --self-test

# 纯本地 token 对账：不读取凭据、不联网、不写扫描状态，只读聚合并打印两类统计
./KimiUsage.app/Contents/MacOS/KimiUsage --tokens-once

# 固定假数据交互预览：不读取凭据、扫描缓存或写入状态，也不联网
./KimiUsage.app/Contents/MacOS/KimiUsage --visual-preview
# 可附加 --visual-preview-dark / --visual-preview-narrow / --visual-preview-empty /
# --visual-preview-states / --visual-preview-long 检查不同外观和异常状态

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

MIT
