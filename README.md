# KimiUsage — Kimi 订阅余量菜单栏小工具

macOS 菜单栏常驻，一瞥即知 Kimi 订阅的配额余量。原生 Swift 单文件实现，纯本地运行。

与 [GlmUsage](https://github.com/JUNX7764/Glmusage)、[CodexUsage](https://github.com/JUNX7764/Codexusage) 是同族三件套，分别盯 Kimi / GLM / Codex 的订阅余量。

## 功能

- **配额用量**：5 小时窗口 / 7 天 / 月度配额的使用比例与重置时间
- **Token 统计**：扫描本地会话日志，统计今天 / 近 7 天 / 近 30 天的 input/output 消耗
  - Kimi Work 本地会话（kimi-desktop daimon）
  - API 客户端会话：独立 Kimi Code CLI、Proma（sdk-config + agent-sessions）/ Claude Code（按 model 字段甄别 Kimi 系模型）、hermes（state.db 快照差分，按 base_url 甄别 kimi.com / moonshot）
- **菜单栏**：常驻，纯本地运行，数据不上传
- **刷新机制**
  - 5H / 7D 每 60 秒；月度额度与两类会话扫描每 300 秒；手动刷新执行完整刷新
  - 各窗口分别保留最后成功时间；失败时保留旧值，同时显示刷新错误与过期状态
  - 「最近尝试刷新」表示请求开始时间

## 安装与构建

需要 macOS 13+ 与 Xcode Command Line Tools（未装先执行 `xcode-select --install`，自带 `swiftc`）：

```bash
./build.sh
```

产物 `KimiUsage.app`，拖到 `/Applications` 双击运行。首次打开如遇 Gatekeeper 提示，右键 → 打开。

## 原理

- **凭据**：只读 Kimi 桌面端本地配置文件 `~/Library/Application Support/kimi-desktop/daimon-share/daimon/config.json`，不在本仓库保存任何凭据
- **月度接口 401**：读取最新 refresh token；写回前重新读取最新 JSON，仅合并 Kimi Web 认证字段，以唯一临时文件和同目录原子替换保存，并限制为仅所有者可读写。若检测到 Kimi 客户端已轮换 access/refresh token，则保留客户端版本。由于官方客户端不使用共享文件锁，检查与替换之间仍无法完全消除并发写入窗口
- **配额**：调用 Kimi 官方本地接口查询
- **Token**：扫描本地会话 wire.jsonl 日志聚合

## 隐私与安全

- 纯本地运行，数据不上传
- 凭据只读，不在本仓库保存任何凭据

## 调试与自检

```bash
# 离线自检：只用临时目录和假凭据，不访问真实凭据、网络或会话缓存
./KimiUsage.app/Contents/MacOS/KimiUsage --self-test
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

## License

MIT
