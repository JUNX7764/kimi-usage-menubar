# 额度周期回顾视觉对齐验收记录

日期：2026-11-13

分支：`plan/quota-cycle-history-20261112`

计划基线：`1fd046d`；视觉实现提交：`1ed2f2e`、`3a1c7af`、`10b12f8`、`42b5caf`。

## 结论

「额度周期回顾」已在不改变历史模型、状态机、存储和浏览逻辑的前提下，重构为 CodexUsage 用量简析同构的标题/主数值/柱图/状态条布局。立柱采用 6pt 宽、46pt 柱区、3pt 组内间隙和 1pt 圆角；当前轮已用柱为空心，短历史按固定六列槽宽居中，完整详情迁入不拦截命中的图内浮层。

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
- `--self-test` PASS。新增覆盖展示文案、当前/已结束柱样式、6pt 柱宽、46pt 上限、3pt 间隙、28/61/32pt 行高，以及 1/4 轮固定槽宽和居中。
- 330/300pt 几何均 PASS；六组双柱不重叠、不越界，已用不超过上限，旧双行详情不再作为可见文本渲染。
- 额度历史交互 PASS：图内浮层内容、完整边界、hit-transparent、移出隐藏、点击固定、顶部/底部同步、方向键跨页、翻页、12→24 扩展、刷新保持、折叠重开、作用域重置和 VoiceOver。
- 通用面板交互与键盘事件均 PASS。
- Python 共 78 tests，全部 OK；三个 Shell 脚本语法检查通过。
- 数据/持久化文件、`build.sh`、脚本协议和 `tests/script_test.py` 无差异。

## 视觉证据

固定内存假数据截图位于会话工作台：

```text
/Users/Chester/.proma/agent-workspaces/kimi-usage-menubar/018b3726-abcb-4ff8-8817-47921e080223/verification/quota-history-visual-polish/
```

- `full-light.png` / `full-dark.png`：六轮默认页，检查主数值、图例、柱形、日期和状态条。
- `one-light.png` / `short-light.png`：一轮居中、四轮固定槽宽，无假柱或假日期。
- `pending-narrow.png`：300pt 下「窗口变化待确认」与剩余完整可读。
- `cross-year.png`：12 月与 01/01 标签保持正确。
- `backgrounds/`：纯色、经典毛玻璃、液态玻璃 × 浅色/深色/降低透明度共 9 张，全部生成；已检查柱体、文字和选中底色可辨。
- `core-contact.png` / `background-contact.png`：仅供本轮集中审阅的裁剪联系表，不是生产资产。
- `cua-preview.png`：本次构建真实 NSPopover 的 Cua 窗口截图，确认运行实例、卡片结构和实际合成像素。

仓库 `docs/images/kimi-usage.png` 使用 `full-light.png` 固定演示数据更新；工作台审查图不作为仓库资产。

## Cua 覆盖与限制

Cua `list_windows` 确认预览 PID 65906、CGWindowID 25585，窗口尺寸 356×867pt；`get_window_state` 的截图有效且已人工查看。Popover 没有可关联的 AXWindow，Driver 明确拒绝后台鼠标和键盘输入，因此未执行物理连续悬停、点击和键盘操作。本轮没有请求前台焦点切换授权。

## 未验证边界

- 真实 Kimi 账号长期跨周期观测仍沿用原功能验收的未验证边界；本轮未运行 `--once`，未读取真实凭据。
- 真实物理输入、VoiceOver 朗读、最低系统版本、TCC、LaunchAgent 和线上更新不在本轮通过范围内。
- 本记录不表示已经合并、推送、发布或替换用户运行中的 App；本机部署结果在获得用户授权后单独补充。
