# 额度周期回顾视觉对齐验收记录

日期：2026-11-13

分支：`plan/quota-cycle-history-20261112`

计划基线：`1fd046d`；视觉实现提交：`1ed2f2e`、`3a1c7af`、`10b12f8`、`42b5caf`；本机反馈修订：`316d5f3`、`31aaa6e`。

## 结论

「额度周期回顾」已在不改变历史模型、状态机、存储和浏览逻辑的前提下，重构为 CodexUsage 用量简析同构的标题/主数值/柱图布局。立柱采用 6pt 宽、66pt 柱区、3pt 组内间隙和 1pt 圆角；当前轮已用柱为空心，短历史按固定六列槽宽右对齐，每轮日期下显示已用百分比，完整详情迁入不拦截命中的图内浮层。底部状态/余量栏已移除，选中列使用产品蓝的浅蓝底色。

构建、离线自检、78 项 Python 回归、330/300pt 几何、AppKit 合成事件、九张背景矩阵和 Cua 真实 Popover 截图检查通过。Cua 因 Popover AX/CGWindow 关联未解析而拒绝后台输入；真实物理悬停和键盘输入未验收，不以合成事件冒充该项通过。

## 自动化验证

```bash
./build.sh
./KimiUsage.app/Contents/MacOS/KimiUsage --self-test
./KimiUsage.app/Contents/MacOS/KimiUsage --visual-preview --visual-preview-quota-geometry
./KimiUsage.app/Contents/MacOS/KimiUsage --visual-preview-narrow --visual-preview-quota-geometry
./KimiUsage.app/Contents/MacOS/KimiUsage --visual-preview --visual-preview-quota-history --visual-preview-test
./KimiUsage.app/Contents/MacOS/KimiUsage --visual-preview --visual-preview-test
./KimiUsage.app/Contents/MacOS/KimiUsage --visual-preview --visual-preview-key-test
python3 -m unittest discover -s tests -p '*_test.py' -v
bash -n build.sh scripts/update.sh scripts/release.sh
codesign --verify --deep --strict KimiUsage.app
```

结果：

- arm64 / macOS 13 构建通过，SDK 27.2，无编译 warning；ad-hoc 签名验证通过。
- `--self-test` PASS。新增覆盖展示文案、当前/已结束柱样式、6pt 柱宽、66pt 上限、3pt 间隙、28/96pt 主数值与图布高度、逐轮日期与百分比标签、底部栏移除，以及 1/4 轮固定槽宽和右对齐。
- 330/300pt 几何均 PASS；六组双柱不重叠、不越界，已用不超过上限，旧双行详情不再作为可见文本渲染。
- 额度历史交互 PASS：图内浮层内容、完整边界、hit-transparent、移出隐藏、点击固定、主数值同步、方向键跨页、翻页、12→24 扩展、刷新保持、折叠重开、作用域重置和 VoiceOver；底部状态/余量栏不再存在。
- 通用面板交互与键盘事件均 PASS。
- Python 共 78 tests，全部 OK；三个 Shell 脚本语法检查通过。
- 数据/持久化文件、`build.sh`、脚本协议和 `tests/script_test.py` 无差异。

## 视觉证据

固定内存假数据截图位于会话工作台：

```text
/Users/Chester/.proma/agent-workspaces/kimi-usage-menubar/018b3726-abcb-4ff8-8817-47921e080223/verification/quota-history-visual-polish/
```

- `full-light.png` / `full-dark.png`：六轮默认页，检查主数值、图例、柱形、日期和状态条。
- `one-light.png` / `short-light.png`：第一轮视觉验收的一轮居中、四轮固定槽宽；后续 `feedback-one-light.png` / `feedback-full-light.png` 按用户反馈改为右对齐并逐轮显示百分比。
- `pending-narrow.png`：第一轮 300pt 下「窗口变化待确认」与剩余完整可读；最终版将二者保留在浮层与无障碍详情。
- `feedback2-full-light.png` / `feedback2-full-dark.png` / `feedback2-one-light.png`：最终无底部栏、66pt 柱体和浅蓝选中底色的固定数据截图。
- `cross-year.png`：12 月与 01/01 标签保持正确。
- `backgrounds/`：第一轮纯色、经典毛玻璃、液态玻璃 × 浅色/深色/降低透明度共 9 张。最终 `feedback2-backgrounds/` 首轮液态玻璃 dark/reduce 子进程退出 1，按既有背板守门单独重跑后两张均生成有效截图；已检查柱体、文字和选中底色可辨。
- `core-contact.png` / `background-contact.png`：仅供本轮集中审阅的裁剪联系表，不是生产资产。
- `cua-preview.png`：本次构建真实 NSPopover 的 Cua 窗口截图，确认运行实例、卡片结构和实际合成像素。

仓库 `docs/images/kimi-usage.png` 使用 `full-light.png` 固定演示数据更新；工作台审查图不作为仓库资产。

## Cua 覆盖与限制

Cua `list_windows` 确认预览 PID 65906、CGWindowID 25585，窗口尺寸 356×867pt；`get_window_state` 的截图有效且已人工查看。Popover 没有可关联的 AXWindow，Driver 明确拒绝后台鼠标和键盘输入，因此未执行物理连续悬停、点击和键盘操作。本轮没有请求前台焦点切换授权。

## 本机部署

用户明确要求完成后部署本机。最终构建为 `v1.7.8-24-g59bcf1a`，暂存包自检和签名通过后替换 `/Users/Chester/Applications/KimiUsage.app`，旧包保留于会话工作台 `deployment/KimiUsage-pre-8fa1fd1.app`。

首次 `launchctl bootstrap` 返回 Input/output error，退出恢复路径随后成功加载同一 LaunchAgent；复核确认新进程 PID 69964 从目标路径稳定运行，安装包 `CUBuildVersion` 为 `59bcf1a`，没有回滚成旧包。

通过真实菜单栏项的 `AXPress` 打开生产 Popover，Cua 截图 `deployed-panel.png` 已人工检查。首次部署时当前账号 7 天额度剩余 30%，历史当前轮显示已用 70%、剩余 30%，与额度区一致；空心当前柱和状态条正常。用户随后指出当前轮应靠右并补逐轮百分比。

反馈版最终构建为 `v1.7.8-27-gd6e5ead`。一次替换后的驻留检测早于 LaunchAgent 实际启动，自动恢复上一版；改用 `kickstart` 并延长检查后成功运行新包，PID 78451。旧包保留在会话工作台 `deployment/KimiUsage-pre-feedback-retry-59bcf1a.app`。生产 Popover 截图 `deployed-feedback-panel.png` 确认当前轮靠右、日期正下方显示 73%、顶部已用 73% 与底部剩余 27% 一致，单页翻页控件已隐藏；面板保持打开供用户查看。

二次反馈版最终构建为 `v1.7.8-30-g02e76af`。一次 LaunchAgent 驻留时序失败已自动恢复；随后以 `open` 启动新包并确认 LaunchAgent 正在运行，最终 PID 90849。旧包保留在 `deployment/KimiUsage-pre-feedback2-open-d6e5ead.app`。本轮 AXPress/前台激活后均未能发现生产 Popover 窗口，因此未获得最终真实面板截图；最终视觉检查基于上述固定数据原生预览，生产实例版本与驻留已核实。

## 未验证边界

- 真实 Kimi 账号长期跨周期观测仍沿用原功能验收的未验证边界；本轮未单独运行 `--once`，生产 App 按既有正常刷新链更新。
- 真实物理连续悬停、键盘输入和 VoiceOver 朗读仍未验收；最低系统版本、额外 TCC 场景和线上更新不在本轮通过范围内。
- 本记录不表示已经合并、推送或发布；仅完成用户明确授权的本机部署。
