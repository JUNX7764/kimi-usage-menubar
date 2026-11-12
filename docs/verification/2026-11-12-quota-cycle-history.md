# 额度周期回顾验收记录

日期：2026-11-12  
验收分支：`plan/quota-cycle-history-20261112`  
验收构建：`2713936`（含预览矩阵补充）

## 结论

7 天额度周期模型、凭据隔离持久化、现有刷新接入、原生卡片与交互已完成。离线回归、arm64 构建、签名、330/300pt 原生预览、背景矩阵和 AppKit 合成事件测试通过。真实 Kimi 账号的长期跨周期观测未进行；Cua 仅完成窗口发现与截图，前台实际鼠标/键盘验收因输入授权不可用而未完成，不以合成事件冒充该项通过。

## 自动化验证

在同一 worktree 执行，未替换原项目或安装目录中的 App：

```bash
./build.sh
./KimiUsage.app/Contents/MacOS/KimiUsage --self-test
python3 -m unittest discover -s tests -p '*_test.py' -v
bash -n build.sh scripts/update.sh scripts/release.sh
file KimiUsage.app/Contents/MacOS/KimiUsage
codesign --verify --deep --strict KimiUsage.app
```

结果：

- 构建通过，SDK 27.2，目标保持 arm64 / macOS 13；`file` 报告 `Mach-O 64-bit executable arm64`。
- ad-hoc 签名与 `codesign --verify --deep --strict` 通过。
- `--self-test`：PASS。覆盖严格额度解析、样本 gate、作用域/代际隔离、主队列旧快照拒绝、预览 fixture 及原有限额、Token、更新和背景回归。
- Python：77 tests，全部 OK。其中额度历史覆盖首样本、同窗口、候选确认/回滚/超时、自然轮换 0→0、观测缺口、非法与乱序、持久化往返、权限、损坏/未来 schema 保全、写失败恢复、等值去重与心跳、A/B/A 代际、分页及 0/1/5/6/7/12/13/25 边界。
- 三个 shell 脚本语法检查通过。

## 原生预览与事件回归

以下真实二进制预览均使用固定 epoch 和内存假数据，不创建生产协调器、不读取真实凭据或偏好：

```bash
./KimiUsage.app/Contents/MacOS/KimiUsage --visual-preview --visual-preview-quota-history --visual-preview-test
./KimiUsage.app/Contents/MacOS/KimiUsage --visual-preview --visual-preview-test
./KimiUsage.app/Contents/MacOS/KimiUsage --visual-preview --visual-preview-quota-geometry
./KimiUsage.app/Contents/MacOS/KimiUsage --visual-preview-narrow --visual-preview-quota-geometry
./KimiUsage.app/Contents/MacOS/KimiUsage --visual-preview --visual-preview-key-test
./KimiUsage.app/Contents/MacOS/KimiUsage --visual-preview --visual-preview-background-test=<临时目录>
```

结果：

- 额度历史交互 PASS：整列进入/移出、点击固定、方向键跨页、12→24 扩展、翻页、刷新保持、折叠重开、作用域重置、VoiceOver 和焦点释放。
- 既有面板交互与 Esc 测试 PASS；330/300pt 几何均 PASS。
- 背景矩阵 9 张全部生成：纯色/液态玻璃/经典毛玻璃 × 浅色/深色/降低透明度。人工查看深色液态玻璃截图，双柱、日期和详情可辨。
- 1、4、6、13、25 轮及空态、待确认、写失败、读取失败、跨年均有固定预览或几何/模型断言。25 轮默认只显示最新 6 轮；跨年截图显示 12 月与 01/01，未按真实运行日改变 fixture 含义。
- 截图证据保存在会话工作台 `verification/`，不作为仓库资产提交。

## 持久化与隔离证据

测试全部使用临时 root、假 API Key 和注入 writer：

- 保存后新建 Store/Coordinator 可恢复当前轮次与候选；A/B key 使用不同加盐分区，切回 A 可恢复 A，不带出 B。
- 同 key 旧 generation 不 reduce、不写盘、不交付 UI；不同 key 的迟到样本只能写自己的旧分区。
- 等值新请求不增加 evidence，也不在 10 秒轮询中反复写盘；真实变化立即保存，稳定状态按五分钟心跳保存。
- 非法 JSON、未来 schema 和时间倒退数据加载失败，原文件字节保留；合法文件的 loose 权限会修为 0600，目录为 0700。
- 注入不可写/writer 失败后，最后成功磁盘状态不变，本进程继续观测并显示「历史未保存」，后续成功保存清除提示。
- 预览代码路径不构造生产仓库；测试中的生产路径均指向注入临时 root。未读取真实 auth，未运行 `--once`。

## Cua 验收状态

已确认运行的是本 worktree 构建的 `KimiUsage --visual-preview --visual-preview-quota-history` 进程，并通过 Cua `list_windows(pid:)` 定位真实 NSPopover，展示窗口镜像且成功取得截图。截图确认第五张卡片、六组双柱和完整详情可见。

该 Popover 的 AX window 无法与 CGWindowID 关联，Cua 明确拒绝所有后台输入并建议 foreground。前台授权询问工具超时，因此未获得授权，也未执行 Cua 前台鼠标/键盘操作。上述 AppKit 合成事件测试是另一层证据，不能替代 Cua 的实际悬停、第六组点击、翻页、键盘跨页、折叠及关闭重开验收。

## 未验证边界

- 真实 Kimi 账号连续多周的 7 天窗口轮换、服务端 reset 抖动和长时间关机缺口尚未观测；启发式参数不是服务端保证。
- Cua 前台实际输入未完成，需在用户明确授权后补验。
- 未验证真实 TCC、LaunchAgent、安装目录、线上更新或最低系统版本实机行为。
- 未运行真实 `--once`，未读取真实凭据，未替换用户正在运行的 App，未执行 update/release。
