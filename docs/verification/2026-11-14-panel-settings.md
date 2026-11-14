# 面板设置（「···」）与 GLM 精修适配：验证记录

执行日期：2026-11-14；worktree `/Users/Chester/Documents/Zcode/kimi-usage-menubar-worktrees/panel-settings-20261113`，分支 `feat/panel-settings-20261113`。基线为生产同源 `f9b4d7d`（`v1.7.9-2`，含已部署的「优化用量提示与周期图表交互」「简化进行中周期选中呈现」两提交——本分支在其上重放全部功能，避免部署回退已上机体验；改动未提交，按用户要求不 commit）。**改动未提交（按用户要求不 commit），仅本地部署。**

实施范围：`docs/plans/2026-11-13-panel-settings-from-glm.md`（v2）Phase A–G 全量：
- 「···」统一面板设置菜单（卡片显示与排序… + 背景样式子菜单），替代原 paintpalette 按钮
- 原位卡片设置页：五卡显隐 + 上下排序 + 恢复默认 + 完成；`panelCardLayout.v1` 持久化与旧配置迁移（`Sources/PanelCustomization.swift`）
- 全部卡片隐藏空态 + 恢复入口
- 额度周期回顾：图标 `clock.arrow.circlepath`；双柱 → 单根 12pt 灰槽 + 底部蓝色填充（0% 不画、100% 填满、不用最小高度伪造面积；当前轮描边标记）（`Sources/KimiPanelVisuals.swift` slotBar/roundedPath）
- 比较条涨跌胶囊（Kimi 语义色：增蓝/减绿/持平灰；窄版两行回退 30→44pt，数字不截断）
- 每日柱顶 1.5pt 圆角（零值日保持 2pt 直柱）；选中行数值 320ms ease-out 过渡（重定向续走、首显/缺数即时、尊重减少动态、AX 即时报目标值）

## 离线门禁（最终轮，全部实际执行）

- `./build.sh`：退出码 0（v1.7.9-dirty，commit 53964d7）
- `./KimiUsage.app/Contents/MacOS/KimiUsage --self-test`：PASS（新增卡片布局模型/迁移/存储、统一菜单结构、原位设置页编辑器、单槽几何、全隐藏空态断言）
- `python3 -m unittest discover -s tests -p '*_test.py'`：Ran 83 tests，OK（含新 `panel_settings_test.py` 5 项：layoutModel / chipSizing / slotGeometry / dailyCorners / tokenTransition）
- `bash -n build.sh scripts/update.sh scripts/release.sh`、`git diff --check`：通过

## 原生 GUI 回归（串行执行、间隔 ≥5s，实际退出码均 0）

- `--visual-preview --visual-preview-test --visual-preview-quota-history`：quota history interaction PASS + visual interaction PASS
- `--visual-preview --visual-preview-quota-history --visual-preview-quota-geometry`：geometry PASS（单槽居中 12pt、填充按观测比例、基线/越界断言）
- `--visual-preview --visual-preview-card-settings-test`：PASS（真实窗口：显隐复选框、上移、完成、重开保留、逐卡隐藏至空态、恢复默认；断言编辑器初始焦点与真实 UserDefaults 未写）
- `--visual-preview --visual-preview-background-menu-test`：PASS（统一菜单经背景子菜单选择液态/经典，Popover 保持打开、monitor 恢复、真实 UserDefaults 未写）

## 截图（docs/verification/screenshots-20261113/，原生窗口合成）

01-light / 02-dark / 03-narrow / 04-slot-history / 05-card-settings / 06-cards-hidden（04/01 于 rebase 后重拍）。人工核对：明暗两版胶囊与单槽对比度、当前轮 65% 轻量填充与低用量标记、窄版胶囊单行不截断、设置页首末行箭头禁用态、全隐藏空态文案与恢复按钮。

## 对抗性审查与修复

Advetor 审查（2026-11-14）结论「无 P0，2 P1 / 3 P2 / P3 若干」，逐项修复后门禁复绿：
- P1-1 self-test 机器相关性：布局内存 override 提前到 self-test 首个控制器创建前（不读真实用户布局）
- P1-2 文档同步：README、docs/DEVELOPMENT.md（卡片布局/周期图/比较条/设置入口/旗标/文件表）、docs/project/02-architecture.md、CHANGELOG Unreleased
- P2-1 设置页 10s 刷新丢焦点：refreshPanelLayout 按 identifier 恢复编辑器焦点
- P2-2 normalized insert 分支零覆盖：fixture 增补 sparse legacy 用例
- P2-3 计划文档与验证记录入库（本文件 + docs/plans/2026-11-13-panel-settings-from-glm.md）
- P3：`cardSettingsViewForTest` → `currentCardSettingsEditor`（生产语义命名）、删除无调用的 `setVisibleState`、`import AppKit` 归顶

## 与生产部署态的合并（2026-11-14 追记）

初版基于 main `53964d7` 完成并通过全部门禁；部署前发现生产 App 为 `v1.7.9-2-gf9b4d7d`（fix/panel-usage-history-polish-20261113 分支 tip，含图内浮层→原生 tooltip、选中呈现简化、用量提示改进）。为不回退已上机体验，将分支重置到 `f9b4d7d` 后重放全部改动：`KimiUsage.swift`/`02-architecture`/`CHANGELOG` Git 自动合并，`Sources/QuotaCycleHistoryView.swift`、`docs/DEVELOPMENT.md`、`docs/project/17-quota-cycle-history.md` 以部署版为底手工重放；周期图最终形态 = 部署版交互语义（tooltip、品牌蓝选中、65% 当前轮填充）+ 单根额度槽几何。重放后全部门禁复绿（上方结果均为重放后实测）。

## 用户反馈第二轮（2026-11-14 上午，已实施并复验）

1. 设置页按钮：底部新增「返回」（与「完成」同为退出设置页，GLM 同款语义与样式——rounded bezel + regular 尺寸），「完成」绑回车键（keyEquivalent "\r"，系统渲染为蓝色主按钮）；key loop 扩展为 …→ 恢复默认 → 返回 → 完成 → 回环。
2. 额度周期回顾视觉对齐 CodexUsage/GLMUsage（用户以两兄弟 App 实机截图为准）：移除 19pt 大主数值行；新增图例行（上限/已用/当前色块图例 + 更早记录胶囊 + 翻页，单页隐藏、行高固定 20pt 防卡片高度漂移）；柱形回归 6pt 双柱（灰上限 + Kimi 蓝已用，1pt 圆角），当前轮 65% 轻量填充 + 日期「•」标记，选中列恢复产品蓝柔和底色；图下新增一行选中轮次状态行（detailTitle；剩余仍在 tooltip/VoiceOver）。单槽方案被本指示取代（KimiPanelVisuals.slotBar 已删，fixture slotGeometry 用例同步移除）。
3. 重放后门禁：build.sh / --self-test / 82 python / 四项 GUI 预览测试全绿（断言随结构同步：几何回到双柱口径，detailTitle 允许出现在状态行、detailValue 仍禁）。

## 用户反馈第三轮（2026-11-14，对齐 GLM v1.5.3）

用户指出第二轮对齐用的是 GLM 生产包 v1.5.2（双柱），最新版本为 v1.5.3（同日发布，含五项 UI 精修）。在临时 worktree（`/tmp/glm-v153`，tag v1.5.3）构建实物并截图作为黄金参照，周期卡再次对齐：恢复单根 12pt 额度槽（GLM v1.5.3 同构几何/透明度：灰槽 0.25、填充 0.72、选中/悬停 1.0；0% 不画、100% 填满），图例改「已用 / 距上限」纯文字，图区左上角新增 100% 刻度，柔和列底改为 GLM 三级（悬停 0.11/固定选中 0.08/当前轮 0.05，圆角 4pt），移除日期「•」与「当前」图例（v1.5.3 无此标记）。slotBar/slotGeometry 用例恢复。重放后门禁复绿：build.sh / --self-test / 83 python / 四项 GUI 测试。

## 槽填充顶边凸起修复（2026-11-14，用户反馈）

用户放大截图发现填充顶边中间有凸起。根因：`NSBezierPath.appendArc` 不带 `clockwise:` 参数时恒为逆时针（角度递增），slot 填充的 flipped 变体误用递减角度（0→-90 / -90→-180），每个角被画成 270° 凹弧向内啃，顶边两角凹陷使平直中段看似凸起。修复：视觉原语拆分为 `topRoundedPath`（y 向上，GLM 同款递增角）与 `bottomRoundedPath`（y 向上底边圆角，供 isFlipped 画布渲染视觉顶边圆角），角部弧全部递增角；fixture 增加角部弧内部 contains 区分性探针锁凹弧回归。重放后 build.sh / --self-test / 83 python / quota geometry GUI 测试全绿，截图确认顶边平直。

## 已知边界（离线通过不等于以下已验收）

- 320ms 动画的时序外观（快速扫过重定向、减少动态效果实机行为）由纯状态 fixture 与 GLM 同款实现模式覆盖，未做录屏级原生验收；物理鼠标悬停/拖拽仍属真机验收范围。
- 真实 VoiceOver、双屏/全屏布局、LaunchAgent 常驻链路未在本轮验证。
- 未联网读真实额度、未读取真实凭据正文、未发布/打 tag；全部预览与自检使用内存快照与临时目录。
