# KimiUsage 发布与回滚说明

> 状态：当前发布清单。最后核对：2026-11-11。
> 本文区分脚本自动检查与仍需人工完成的验收。

## 1. 发布资产

每个正式版本必须包含：

- `KimiUsage.dmg`：人工下载与安装；
- `KimiUsage.zip`：应用内自动更新；
- `KimiUsage.zip.sha256`：ZIP 完整性校验。

仓库、Bundle、LaunchAgent、更新器与发布目标必须保持既有身份，不得与其他 Usage 应用混用。

## 2. 发布前本地门禁

```bash
git status --short
./build.sh
./KimiUsage.app/Contents/MacOS/KimiUsage --self-test
python3 -m unittest discover -s tests -p '*_test.py'
bash -n build.sh scripts/update.sh scripts/release.sh
```

发布前由 Agent 对比上一正式版与目标版本，核实实际改动并编写、提交 `release-notes/vX.Y.Z.md`。脚本拒绝缺失或空白说明；已有 Release 正文与文件不一致时停止，不自动覆盖。

确认工作区干净、HEAD 已推送且版本号符合变更类型后，执行 `scripts/release.sh vX.Y.Z`。

脚本自动完成远端与身份检查、标签创建、构建、二进制自检、ad-hoc 签名验证、DMG / ZIP 打包与校验、SHA256 生成以及 Release 创建或补全。

**脚本不会自动执行 Python 回归、真实面板更新、崩溃回滚或最低系统版本验收。**

`build.sh` 会校验构建环境为 macOS 26+ SDK（编译部署目标仍是 macOS 13；液态玻璃背景依赖新 SDK 的原生 NSPopover chrome 语义），旧 SDK 直接报错退出。背景样式离线证据：`--self-test` 覆盖解析回退、持久化、菜单结构、旧系统降级、reduce 强制与切换不重建；`--visual-preview-background-test=<目录>`（需 GUI 会话）产出 3 样式 × 明暗 + reduce 强制共 9 张屏幕合成截图。真实验收仍需覆盖：macOS 13–25 上液态玻璃菜单项禁用与降级渲染、系统「降低透明度」实时切换、菜单选择不关闭主面板。

## 3. 更新链路验收

更新器或更新控制器变化后，至少在真实安装副本上验收：

1. 安装上一个正式 Release；
2. 从面板点击更新，观察下载、安装和重启；
3. 核对新版版本、额度加载、Token 明细和自启状态；
4. 注入启动失败，确认旧包恢复并能重新运行；
5. 覆盖 LaunchAgent 正常、关闭自启和路径含空格等状态；
6. 记录版本、路径、日期和结果，不把 mock 通过写成真实验收。

## 4. 发布后检查

- 重新下载 ZIP，核对 SHA256、压缩包完整性和 `CUBuildVersion`；
- 核对 Bundle Identifier、签名状态，并从发布包运行离线自检；
- 确认 Release 非 draft、非 prerelease 且三个资产完整；
- 确认更新列表选择目标版本，不选择资产不完整的更高版本。

## 5. 回滚与事故处理

更新脚本在停止旧进程后失败时，应恢复旧包并尝试重启。进程存在不等于应用健康，发布者仍需保留上一个已知可用的 Release 和安装包。

更新器拒绝降级。出现严重问题时，应撤回或预发布化受影响 Release，并发布版本号更高的修复版，而不是依赖自动降级。

## 6. 当前公开分发限制

- 当前使用 ad-hoc 签名，不是 Developer ID 公证。
- ZIP 与 SHA256 来自同一 Release，尚无独立发布者签名验证。
- 尚无 CI 和 macOS 13 / 14 / 15 的完整兼容性矩阵。
- 完整面板点击升级与崩溃回滚应成为更新链路变化的固定验收，而非默认假设已完成。

发布说明必须准确描述验证范围，不宣称“全链路可靠”或“所有系统均已验证”。
