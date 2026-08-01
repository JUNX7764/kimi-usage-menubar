# KimiUsage — Kimi 用量菜单栏小工具

一个 macOS 菜单栏（Menu Bar）小工具，实时显示 Kimi 的用量情况。

## 功能

- **配额用量**：5 小时窗口 / 7 天 / 月度配额的使用比例与重置时间
- **Token 统计**：扫描本地会话日志，统计今天 / 近 7 天 / 近 30 天的 input/output token 消耗
  - Kimi Work 本地会话（kimi-desktop daimon）
  - API 客户端会话：独立 Kimi Code CLI、Proma / Claude Code（按 model 字段甄别 Kimi 系模型）
- 菜单栏常驻，纯本地运行，数据不上传

## 原理

- 凭据：只读 Kimi 桌面端本地配置文件 `~/Library/Application Support/kimi-desktop/daimon-share/daimon/config.json`，不在本仓库保存任何凭据
- 配额：调用 Kimi 官方本地接口查询
- Token：扫描本地会话 wire.jsonl 日志聚合

## 构建

需要 macOS 13+ 和 Xcode Command Line Tools（自带 `swiftc`）：

```bash
./build.sh
```

产物为 `KimiUsage.app`，双击或拖到 `/Applications` 即可运行。

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
