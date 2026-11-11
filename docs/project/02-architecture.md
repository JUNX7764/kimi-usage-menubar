# KimiUsage 当前架构概览

> 状态：当前架构摘要。最后核对：2026-11-11。
> 本文解释模块与边界，函数级行为以源码和测试为准。

## 1. 应用形态

KimiUsage 是 macOS 13+、Apple Silicon 的原生 AppKit 菜单栏应用，当前 Swift 实现集中在 `KimiUsage.swift`，无 Swift Package 依赖。面板使用原生 `NSPopover`，不是 SwiftUI 面板。

应用身份保持为：

- 仓库：`JUNX7764/kimi-usage-menubar`
- Bundle / LaunchAgent：`com.local.kimi-usage`
- 应用：`KimiUsage.app`

## 2. 模块边界

| 模块 | 当前职责 |
|---|---|
| `CredStore` | 读取 Kimi 桌面端配置；月度认证续期时合并并原子写回 |
| `Fetcher` | 查询 5 小时、7 天、月度额度与账号信息；Transport 可注入，401 续期重试支持离线测试 |
| `TokenAggregator` | 汇总 Kimi Work、Kimi Code、ZCode、Proma、Claude Code、Hermes 等本地用量 |
| `UpdateChecker` | 检查 GitHub Release 和更新资产 |
| `UpdateProgressController` | 后台更新、进度恢复和错误展示 |
| `UsagePanelController` | 原生 Popover、额度与模型明细交互、面板背景样式（纯色/液态玻璃/经典毛玻璃） |
| `AppDelegate` | 生命周期、刷新调度、自启和状态聚合 |
| `KimiOfflineRegression` | 使用临时目录与假数据的离线自检 |

单文件是当前实现状态，不是永久架构约束。后续拆分时优先分离凭据、网络、Token 聚合、更新和 UI。

## 3. 主要数据流

### 额度与认证

Kimi 桌面端配置 → 内存认证状态 → Kimi 远程接口 → 新鲜度与错误合并 → Popover 和诊断状态。

401 续期是当前配置写回路径。写回必须保留客户端并发轮换结果、原子替换和仅所有者权限；认证字段不得写入日志、缓存、测试或提交。

### 本地 Token

本地 JSONL / SQLite → 只读扫描与来源去重 → `scan-state-v6.json` → 今日、近 7 日、近 30 日及模型明细。

原始会话与数据库只读。缺少模型名、来源不可读、重复日志和 SQLite 中途失败必须按既定边界降级，不能将部分结果当成完整成功。

### 自动更新

GitHub Release → 可安装版本与说明同时选择 → 面板内查看说明并确认 → ZIP / SHA256 下载 → 身份、版本、签名与离线自检 → 暂存 → 停止目标进程 → 换包 → 健康检查 → 成功清理或失败回滚。

更新器只处理当前应用路径和 `com.local.kimi-usage`，不得按名称模糊终止其他进程。

### 面板背景样式

头部最右缘按钮 → 原生 NSMenu（纯色 / 液态玻璃 / 经典毛玻璃，旧系统液态项标题「液态玻璃（需 macOS 26+）」）→ `PanelBackgroundStyle` → UserDefaults 单 key `panelBackgroundStyle` → `applyBackgroundStyle()` → 背景层 hidden/opacity。

- 缺省与非法值回退 solid；打开、切换、系统无障碍通知（经 `NSWorkspace.shared.notificationCenter` 注册）共用同一应用入口，切换不重建面板内容。
- solid：`PanelSolidBackgroundView` opacity=1（无历史 0.9 混合）；classicMaterial：仅 `NSVisualEffectView(.popover)`；liquidGlass：两层自绘背景全部隐藏，露出 macOS 26+ 新 SDK 原生 NSPopover chrome，不引入 NSGlassEffectView / NSPanel。卡片底色为 `labelColor@0.035`，描边为 `labelColor@0.09`，无阴影。
- 旧系统禁用液态菜单项并渲染降级 classicMaterial；「降低透明度」临时强制 solid 且不改写持久化偏好。
- NSMenu 弹出期间挂起面板 local/global 事件 monitor（避免面板被自己的 monitor 关闭），结束后恢复；主 Popover 保持 transient。
- 预览回归经 `--visual-preview-background=` / `--visual-preview-backdrop` / `--visual-preview-background-test=` / `--visual-preview-background-menu-test` 走覆盖模式，所有预览路径不写真实 UserDefaults；矩阵/单拍不弹真实 NSMenu，背板只存在于预览进程，合成截图带面板墨水有效性守门。

## 4. 信任边界

- Kimi 接口与本地客户端格式可能变化，解析失败必须显式降级。
- 本地配置写回与官方客户端之间没有共同文件锁，已知并发窗口不能宣称完全消除。
- GitHub Release 与 SHA256 来自同一信任源；ad-hoc 签名不提供独立发布者身份验证。
- 离线 mock、真实接口验证和真实安装验收是不同证据。
- 当前没有 CI 强制发布门禁，也没有完整系统版本兼容性矩阵。
