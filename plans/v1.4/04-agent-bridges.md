# 任务书 04：Agent/CLI 发现性（产品桥）

背景：Run Shelf 的双形态（人用 GUI、agent 用 CLI）目前互相不可见——GUI 用户不知
道 CLI 存在，agent 没有入口知道这台机器上有 runshelf。本任务书补三座桥。设计已
定稿，按 A→C 实施；依赖任务书 03 完成（契约稳定后再固化对外文档）。

---

## A（P1）agent → 工具的桥：`runshelf agent-setup`

新增子命令 `runshelf agent-setup`，让"让 agent 学会用 runshelf"从手工粘贴 prompt
变成一条命令。

行为：
- `runshelf agent-setup`（无参）：向 stdout 输出一段自包含的 agent 集成说明
  （Markdown），内容包括：runshelf 是什么（一句话）、CLI 绝对路径（运行时解析自
  身路径，不硬编码）、`help agent` / `schema task-spec` 入口、最小 TaskSpec 示例、
  退出码表、危险命令与 `--allow-dangerous` 约定。内容以 `help agent` 为 SSOT 生成，
  不维护两份文案。
- `runshelf agent-setup --write claude`：写入/幂等追加到 `~/.claude/CLAUDE.md`
  （带 `<!-- runshelf:begin -->/<!-- runshelf:end -->` 标记块，重复执行只更新块内）。
- `runshelf agent-setup --write agents`：同样逻辑写当前目录 `AGENTS.md`。
- `--json` 输出写入路径与是否变更。
- 写入用户文件前若目标存在且无标记块，只追加不改动既有内容；输出提示已写入的路径。

## B（P1）人 → CLI 的桥：设置页入口

设置页（`RunShelf/App/Views/SettingsView.swift`）新增"命令行与 AI Agent"分组：

- "安装 runshelf 命令"按钮：调用现有 `install-cli` 逻辑，显示安装结果与 PATH 提示
  （复用 CLI 里的检测，不重写）。已安装时显示所在路径与版本。
- "为 AI Agent 配置"：说明一行 + 两个动作——"复制集成说明"（即 agent-setup 的
  stdout 内容进剪贴板）、"写入 ~/.claude/CLAUDE.md"（等价 `--write claude`，执行前
  展示将写入的内容）。
- 文案遵循现有中文风格（docs/requirements.md 第 19 节词汇表）。

## C（P2）CLI → 人的桥：任务来源标记

让 GUI 用户看见"这个任务是 agent 建的"，自然建立双形态心智。

设计澄清（2026-08-09，修正初稿的错误假设）：`origin` 是**写入方自动记录的出处
元数据，不是调用方输入**。它只进 `TaskManifest` 持久化结构，不进任何 schema：

- `TaskManifest`（`task.json`）增加可选字段 `origin`：`"app" | "cli"`。schemaVersion
  保持 1，字段可选即向后兼容；缺失视为未知，不显示标记。
- **不改 `schemas/task-spec.schema.json`**——origin 不是 apply 的合法输入，出现在
  TaskSpec 里必须按未知字段拒绝（现有严格校验已保证，补一条测试固定该行为）。
- **不新增 task-manifest schema**——task.json 没有独立 schema surface，本任务不引入。
  `GeneratedSchemas.swift` 因此无需重新生成。
- 写入规则：CLI `apply` 创建任务时自动写 `origin: "cli"`；App 新建任务时自动写
  `origin: "app"`；更新任务时保留原值不变（出处随创建固定，不可被后续写入方改写）。
- `task show`/`task list` 的 JSON result 里透出 `origin`（result payload 本就无 schema
  约束，不涉及 envelope 变更）。
- 侧边栏/Inspector 对 `origin == "cli"` 的任务显示小标记（如 "CLI" 徽章 + tooltip
  "由命令行/AI agent 创建"）。
- run 的 meta 已有 `trigger`（manual/scheduled），不动。

## 明确不做

- MCP server：CLI + JSON + 退出码已满足 agent 需要，MCP 只是换运输层，暂不做。
- 自动检测/提示"你装了 Claude/Codex"：越界，保持用户主动触发。

## 验收

- `runshelf agent-setup --write claude` 重复执行幂等；标记块外内容零改动。
- 全新 agent 会话中只提供 `runshelf` 路径，能凭 agent-setup 输出自主完成
  创建 → 运行 → 查日志 → 删除 全流程（人工用一次 Claude/Codex 会话验证）。
- 设置页两个入口在无 CLI 安装、已安装两种状态下表现正确。
- `scripts/check.sh` 全绿。
