# Claude / Codex Hook 卸载清理与鲁棒性增强设计

日期：2026-04-26

## 背景

`CCBot` 当前已经具备 Claude Code Hook 与 Codex Hook 的安装、卸载、配置合并和失败回滚能力，但卸载路径仍存在两个体验问题：

1. 卸载后可能留下只属于 CCBot 的空配置文件或空 hooks 目录。
2. 状态判断虽然已经区分“已安装”和“有残留”，但底层清理结果还不够干净，容易给后续排障带来噪声。

这轮目标是继续增强底层 installer 的清理能力和鲁棒性，不扩展交互层范围，不把任务演变成新的菜单改版。

## 目标

- 卸载 Claude / Codex Hook 后，不再留下仅由 CCBot 占用的空配置文件和空 hooks 目录。
- 保持当前多文件安装/卸载的事务回滚模型，不因为“清理更干净”引入新的半安装或半卸载风险。
- 保证用户已有配置、外部脚本、外部 hook 注册不被误删。

## 非目标

- 不新增菜单按钮，不重构菜单栏安装器交互。
- 不改动 HookServer 的通知路由、消息格式或审批通知语义。
- 不修改安装路径的功能边界；安装仍保持写脚本、合并配置、失败回滚。

## 当前实现摘要

### Claude Hook

- 脚本位于 `~/.claude/hooks/cc-bot-notification.sh` 与 `~/.claude/hooks/cc-bot-stop.sh`。
- 兼容清理旧脚本 `~/.claude/hooks/cc-bot-pre-tool-use.sh`。
- 配置通过合并 `~/.claude/settings.json` 中的 `hooks.Notification` 与 `hooks.Stop` 完成。
- 卸载时会删除脚本、移除受管 hook 项，并使用 snapshot / restore 进行失败回滚。

### Codex Hook

- 脚本位于 `~/.codex/hooks/cc-bot-notify.sh` 与 `~/.codex/hooks/cc-bot-permission-request.sh`。
- 配置同时涉及：
  - `~/.codex/config.toml` 中的 `notify`
  - `~/.codex/config.toml` 中的 `[features] codex_hooks = true # ccbot`
  - `~/.codex/hooks.json` 中的 `PermissionRequest` hook
- 卸载同样支持多文件 snapshot / restore 回滚。

### 当前问题

- 卸载后即使配置已经只剩空壳，也仍可能保留空的 `settings.json`、`config.toml`、`hooks.json`。
- 脚本删除后，若 `~/.claude/hooks/` 或 `~/.codex/hooks/` 已空，目录仍可能残留。
- 这些残留不会直接破坏功能，但会降低“卸载干净”体验，也会增加后续排障时的状态噪声。

## 方案概览

方案分两层执行：

1. 事务核心层：继续处理脚本文件与配置文件的受管内容移除，并保持失败回滚。
2. 收尾清理层：在事务成功后，保守地裁剪空文件壳和空 hooks 目录。

核心原则：

- 配置内容的修改仍必须是事务性的。
- 目录清理只做成功后的保守收尾，不参与主事务回滚决策。
- “只清理 CCBot 管理的内容”，任何用户内容、外部内容都必须保留。

## 详细设计

### 1. 配置文件空壳清理

卸载路径在移除 CCBot 相关接线后，不再无条件把结果写回磁盘，而是先判断清理后的内容是否仍然有意义：

- 若清理后仍保留用户内容，则写回该文件。
- 若清理后只剩空对象、空 section、空 hooks 容器或纯空白文本，则直接删除该文件。

目标行为如下：

- Claude：
  - `settings.json` 若移除 `Notification` / `Stop` / legacy `PreToolUse` 后已无有效内容，则删除文件。
  - 若仍有 `permissions`、用户自定义 hooks 或其他 JSON 键，则保留文件，仅做定点移除。
- Codex：
  - `config.toml` 若移除受管 `notify` 和 `codex_hooks = true # ccbot` 后为空壳，则删除文件。
  - `hooks.json` 若移除受管 `PermissionRequest` 后为空壳，则删除文件。
  - 若仍有用户配置、其他 feature、其他 hook entries，则保留并定点清理。

这里的“空壳”判断只针对语义空内容，不把包含真实用户配置的文件误删。

### 2. 空 hooks 目录裁剪

在脚本文件删除成功后，额外尝试删除以下目录：

- `~/.claude/hooks/`
- `~/.codex/hooks/`

删除规则：

- 仅在目录存在且为空时尝试删除。
- 目录中只要还有任意文件或子目录，就直接保留。
- 删除失败不视为主流程失败，不触发整次卸载回滚。

这样可以保证“清理更干净”，同时避免因为目录层面的偶发状态影响配置层事务安全。

### 3. installer 结构调整

代码职责按下面收口：

- `HookInstaller.removeHooks(...)`
  - 只负责从 `settings.json` 的数据结构里移除 CCBot 接线。
  - 不直接决定是否删除文件。
- `CodexNotifyInstaller.removeNotify(...)`
  - 只负责移除受管 `notify`。
- `CodexNotifyInstaller.removeManagedHooksFeature(...)`
  - 只负责移除受管 `codex_hooks = true # ccbot`。
- `CodexNotifyInstaller.removePermissionRequestHook(...)`
  - 只负责移除受管 `PermissionRequest` hook。
- `HookInstaller.uninstall(...)` / `CodexNotifyInstaller.uninstall(...)`
  - 统一根据“清理后是否为空壳”决定写回还是删文件。
  - 在主事务成功后再调用空目录裁剪。

这样可以把“内容变换”和“磁盘清理决策”分离，避免 helper 同时承担数据语义和磁盘副作用。

### 4. FileUtilities 扩展

新增通用文件工具以支撑 installer：

- `writeOrRemoveIfEmpty(...)`
  - 有语义内容时写回文件。
  - 为空壳时删除目标文件。
  - 仍然保留失败回滚所需的可预测行为。
- `removeDirectoryIfEmpty(...)`
  - 仅删除空目录。
  - 幂等；目录不存在或非空时都安全返回。

这些 helper 只承载通用文件系统操作，不嵌入 Claude / Codex 业务判断。

## 数据流

### Claude 卸载

1. 读取 `settings.json`，生成移除受管 hooks 后的新数据。
2. capture snapshots：脚本、legacy 脚本、`settings.json`。
3. 删除受管脚本。
4. 根据新数据决定：
   - 写回 `settings.json`
   - 或删除 `settings.json`
5. 主事务成功后，尝试删除空的 `~/.claude/hooks/`。

### Codex 卸载

1. 读取 `config.toml` 和 `hooks.json`，分别生成移除受管配置后的新数据。
2. capture snapshots：脚本、`config.toml`、`hooks.json`。
3. 删除受管脚本。
4. 根据新数据决定：
   - 写回或删除 `config.toml`
   - 写回或删除 `hooks.json`
5. 主事务成功后，尝试删除空的 `~/.codex/hooks/`。

## 错误处理

### 事务范围内

以下操作失败时，必须恢复到卸载前状态：

- 受管脚本删除
- 配置文件写回
- 配置文件删除

继续复用现有 snapshot / restore 模型，保证主事务失败时不会留下半清理状态。

### 事务范围外

以下操作失败时，不影响卸载结果：

- 删除空的 hooks 目录

原因是目录裁剪只属于成功后的卫生清理，不应让主流程因为非关键失败而整体回滚。

## 测试计划

### HookInstallerTests

- 卸载后如果 `settings.json` 只剩 CCBot 接线，文件应被删除。
- 卸载后如果 `settings.json` 仍有用户内容，文件应保留且只移除我们的 hooks。
- 卸载后 `~/.claude/hooks/` 为空时应被删除。
- 若 `~/.claude/hooks/` 还有非 CCBot 文件，目录必须保留。

### CodexNotifyInstallerTests

- 卸载后若 `config.toml` 仅剩受管 `notify` 与 `codex_hooks = true # ccbot`，文件应被删除。
- 卸载后若 `hooks.json` 仅剩受管 `PermissionRequest`，文件应被删除。
- 若 `config.toml` / `hooks.json` 仍有用户内容，则只做定点清理。
- 卸载后 `~/.codex/hooks/` 为空时应被删除，非空时必须保留。

### 回归验证

- `xcodebuild test -project CCBot.xcodeproj -scheme CCBot -destination 'platform=macOS'`

## 风险与缓解

### 风险 1：把语义上仍有内容的配置误判为空壳

缓解：

- 空壳判断只建立在解析后的语义结果之上，不按简单字符串长度判断。
- 为“仍保留用户内容”的场景补专门回归测试。

### 风险 2：清理目录时误删用户目录

缓解：

- 只尝试删除固定的 hooks 目录。
- 严格要求“目录为空”才删除。
- 非空或失败一律 no-op。

### 风险 3：新 helper 破坏现有回滚模型

缓解：

- 文件层变更仍放在 snapshot / restore 的事务范围里。
- 目录裁剪明确放到事务成功后执行，不和主回滚耦合。

## 验收标准

- 卸载后不再留下由 CCBot 独占的空配置文件和空 hooks 目录。
- 用户已有配置、外部脚本、外部 hook 注册保持不变。
- 现有安装/卸载回滚能力不退化，完整测试通过。
