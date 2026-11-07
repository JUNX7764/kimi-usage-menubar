# 项目约定

## 项目地图

- KimiUsage 是面向 Apple Silicon、macOS 13+ 的本地菜单栏工具。`KimiUsage.swift` 是单文件 AppKit/Foundation/SQLite3 应用，包含凭据读取、额度接口、本地 Token 聚合、原生 Popover、更新检查和离线测试；底部有顶层命令行入口，拆文件时需要调整 Swift 可执行入口。
- `README.md` 为用户使用入口，`docs/DEVELOPMENT.md` 说明维护、统计口径与验证命令。`docs/project/` 目前包含尚未填完的模板，不能当作已实施的架构或发布事实；历史更新设计位于 `docs/features/reliable-release-update-20261102/`。
- `build.sh` 以 `swiftc -O -target arm64-apple-macos13.0` 编译，重建仓库内 `KimiUsage.app` 并做 ad-hoc 签名；构建版本来自 `git describe`，注入产物的 `CUBuildVersion`。需要保留现有运行包时，直接编译到会话工作台，避免覆盖它。
- `scripts/update.sh` 接收目标 tag 和当前应用路径，校验 Release ZIP/SHA256、构建版本与签名完整性，暂存换包并在失败时尝试回滚。`scripts/release.sh vX.Y.Z` 涉及远端 tag 与 GitHub Release，是实际发布操作，不作为普通验证命令执行。
- 本地数据路径由源码中的 `CredStore`、`TokenAggregator` 定义；认证信息来自 Kimi 桌面配置，续期会写回官方客户端配置。扫描覆盖 Work、CLI/Proma/Claude JSONL 与 ZCode/Hermes SQLite；缓存位于用户 Application Support/KimiUsage。审查与测试优先使用临时目录和假凭据，不输出真实 token 或会话正文。

## 验证入口

- 离线 Swift 回归：构建后的可执行文件加 `--self-test`，仅使用临时数据，不访问真实凭据、网络和扫描缓存。
- 更新发布脚本回归：`python3 -m unittest discover -s tests -p '*_test.py'`，通过 PATH mock 验证失败分支。
- `--tokens-once` 会读取真实本地会话与缓存，但不联网、不持久化扫描结果；`--once` 会读取真实凭据、联网、可能续期并写缓存，不能作为无副作用自检。
- 原生交互预览使用 `--visual-preview` 及开发文档所列选项；离线测试通过不等于真实 App、TCC 权限、LaunchAgent 或线上更新已验收。

<!-- proma:memory:start -->
## 记忆维护

- 项目记忆索引：[MEMORY.md](</Users/Chester/.proma/agent-workspaces/kimi-usage-menubar/memory/MEMORY.md>)；详细主题按索引按需读取，新增、移动、归档主题时同步索引。
- 全局用户画像：[user_profile.md](</Users/Chester/.proma/memory/user_profile.md>)，跨项目共享；本项目补充偏好存入 /Users/Chester/.proma/agent-workspaces/kimi-usage-menubar/memory/project-preferences.md 并加入项目索引，仅在本项目覆盖全局偏好。
- 在任务中及时修订已确认的偏好、经验和决策，保留来源、适用范围和核验日期；不把临时任务进度写成永久偏好。超过一周的阶段性要求结合本轮证据复查；到期或被替代的内容移出有效入口并可恢复地归档。读取不等于核验，不编造用户事实。
<!-- proma:memory:end -->
