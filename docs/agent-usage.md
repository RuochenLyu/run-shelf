# Codex / Claude 操作 Run Shelf 的约定

这份文档给“使用 Run Shelf 管理自动化任务”的 agent 看，不是给修改 Run Shelf 源码的 agent 看。

## 基本原则

1. 不直接改 `task.json`、`run.sh`、`notes.md`。
2. 读任务用 `runshelf task show <id|slug> --json`。
3. 写任务用 `runshelf apply <spec.json|-> --json`，先 `--dry-run` 再真正写入。
4. 选择任务优先用 `id` 或 `slug`，不要靠 `name` 猜。
5. 修改已有任务时，把 `task show` 返回的 `revisionToken` 原样带回 `apply --expected-revision <token>`。
6. 遇到 `conflict`、`not_found`、`validation`、`already_running` 这类错误，重新读取任务或等待运行结束后再决定下一步。
7. slug 不能使用 CLI 保留字 `status`、`log`、`cancel`、`stop`。

CLI、App、后台调度进程共用同一个任务目录。CLI 写入时会做一致性读取、乐观 CAS 和原子写；运行任务时会用 `.run-claim` 做跨进程去重，所以 App 和 CLI 同时操作同一批任务时不会靠“最后写入覆盖前一个写入”来赌运气。

## 复制给 Codex/Claude

最快的集成方式是 `runshelf agent-setup --write claude`（写入 `~/.claude/CLAUDE.md`）或
`runshelf agent-setup --write agents`（写入当前目录 `AGENTS.md`）：内容与 `help agent`
同源，带标记块，重复执行幂等。以下手动粘贴方式仍然有效。

用户可以把下面这段原样发给 Codex/Claude：

```text
请使用 Run Shelf 管理我的本地自动化任务。

规则：
1. 不要直接编辑 ~/Library/Application Support/Run Shelf/tasks/ 里的 task.json、run.sh、notes.md。
2. 通过 runshelf CLI 操作；如果 shell 里没有 runshelf，先使用 /Applications/Run\ Shelf.app/Contents/Library/Helpers/runshelf。
3. 先运行 runshelf help agent 读取约定，再运行 runshelf doctor --json 确认数据目录。
4. 读任务用 runshelf task list --json 和 runshelf task show <id|slug> --json。
5. 写任务用 TaskSpec JSON。创建任务先 runshelf apply spec.json --dry-run --json，再 runshelf apply spec.json --json。
6. 修改已有任务必须先 task show 读取 result.revisionToken，再 runshelf apply spec.json --expected-revision <revisionToken> --json；遇到 conflict 要重新读取，不要强行覆盖。
7. 运行任务用 runshelf run <id|slug> --wait --json；长任务用 runshelf run <id|slug> --detach --json，然后用 runshelf run status <run-id> --json 轮询。
8. 需要停止后台运行时，用 runshelf run cancel <run-id> --json。
9. 脚本命中 dangerous_command 时，默认不要加 --allow-dangerous，除非我明确确认。
10. 选择任务优先用 id 或 slug，不要靠 name 猜。
```

## CLI 位置

发布版 App 内置 CLI：

```zsh
/Applications/Run\ Shelf.app/Contents/Library/Helpers/runshelf
```

如果要让 shell 里直接输入 `runshelf`，可以建立符号链接：

```zsh
/Applications/Run\ Shelf.app/Contents/Library/Helpers/runshelf install-cli --json
```

macOS 默认 zsh 不一定包含 `~/.local/bin`。如果 `command -v runshelf` 找不到，把下面这一行加入 `~/.zshrc`：

```zsh
export PATH="$HOME/.local/bin:$PATH"
```

## 常用命令

```zsh
runshelf task list --json
runshelf task show <id|slug> --json
runshelf task delete <id|slug> --json
runshelf apply spec.json --dry-run --json
runshelf apply spec.json --json
runshelf apply spec.json --dry-run --expected-revision <revisionToken> --json
runshelf apply spec.json --expected-revision <revisionToken> --json
runshelf run <id|slug> --wait --json
runshelf run <id|slug> --detach --json
runshelf run status <run-id> --json
runshelf run cancel <run-id> --json
runshelf run stop <run-id> --json
runshelf run log <run-id> --stdout
runshelf run log <run-id> --stderr
runshelf run log <run-id> --bytes 262144 --json
runshelf run log <run-id> --full
runshelf doctor --json
runshelf install-cli --json
runshelf help agent
runshelf schema task-spec
runshelf schema task-spec --example
runshelf schema cli-result
runshelf version --json
```

`--wait` 会让 CLI 持有运行直到任务结束；`--detach` 会启动一个后台 host 进程，CLI 立刻返回 `runId`，后续用 `run status` 轮询。

前台 `run` 以非成功状态结束时，退出码是 `8`，JSON envelope 同时返回 `ok: false` 和 `error.code: "run_failed"`；`result.run` 仍保留完整运行记录，包括状态、脚本退出码和日志路径，便于 agent 诊断。

如果 `run status` 显示后台运行仍在继续，但 agent 判断必须停止，用 `runshelf run cancel <run-id> --json`。CLI 会读取 `.run-claim` 里的进程组并发送 `SIGTERM`。

`run stop` 是 `run cancel` 的别名。任务运行结束后可以用 `task delete` 删除；任务仍在运行时删除会返回 `already_running`/退出码 `7`。`run cancel` 对已经结束的 run 返回 `not_found`，应改用 `run status` 查看最终状态。

## JSON envelope 与自描述

支持 JSON 的命令在传入 `--json`（或设置 `RUNSHELF_JSON=1`）时输出单个 envelope。所有 envelope 都包含：

```json
{
  "schemaVersion": 1,
  "ok": true,
  "result": {}
}
```

每个 envelope 都至少包含 `schemaVersion` 和 `ok`。成功时包含 `result`；失败通常包含带 `code`、`message` 的 `error`，并省略 `result`。唯一保留失败结果的情况是前台 `run`：它返回 `ok: false` 和 `run_failed`，同时在 `result.run` 留下完整运行记录。`doctor` 发现任务读取问题时仍返回可检查的成功 envelope（`ok: true`、`result.loadIssues` 非空），但进程退出码是 `1`。

`runshelf version --json` 返回 App 版本和 envelope schema 版本。`runshelf schema task-spec`、`runshelf schema cli-result` 输出原始 JSON Schema，不包 envelope；`runshelf schema task-spec --example` 输出原始最小 TaskSpec JSON。`help` 输出文本。

## 写入冲突

`runshelf task show <id|slug> --json` 的返回值里有 `result.revisionToken`。更新已有任务时必须把这个 token 带回去：

```zsh
runshelf apply spec.json --expected-revision "$revisionToken" --json
```

如果 App 或另一个 CLI 在你读取后改过任务，命令会返回 `conflict`，退出码是 `5`。这时不要重试同一个 spec，先重新 `task show`，确认当前内容后再生成新的 TaskSpec。

更新已有任务（包括 `--dry-run`）时省略 `--expected-revision` 会返回 `usage`，退出码是 `2`，且不会写盘；创建新任务不需要 revision token。

## TaskSpec

`TaskSpec` 是给 agent 的稳定写入面，不是 `task.json` 的完整镜像。创建任务时没有覆盖到的内部策略使用默认值；更新任务时没有覆盖到的内部策略会保留原值。
根对象和 `schedule` 中的未知字段都是硬错误；当前 `timezone` 只接受 `local`，不会静默接受未实现的时区。日志默认读取最后 1 MiB，JSON 消费方必须检查 `truncated`、`totalBytes` 和 `returnedBytes`。

最小示例：

```json
{
  "slug": "daily-report",
  "name": "每日报告",
  "enabled": true,
  "schedule": {
    "type": "cron",
    "expression": "0 9 * * *",
    "timezone": "local"
  },
  "timeoutSeconds": 600,
  "script": "#!/bin/zsh\nset -euo pipefail\n\nprintf 'ok\\n'\n",
  "notes": "由 agent 管理。"
}
```

完整 schema 在 `schemas/task-spec.schema.json`。

可以直接让 CLI 生成最小可用示例：

```zsh
runshelf schema task-spec --example
```

## 高风险命令

`apply` 和 `run` 会扫描脚本。命中 `rm -rf`、`sudo` 这类高风险模式时，默认拒绝写入或运行，错误码是 `dangerous_command`，退出码是 `6`。

确认要写入或运行时，必须显式加：

```zsh
runshelf apply spec.json --allow-dangerous --json
runshelf run <id|slug> --allow-dangerous --wait --json
```

这个开关只表达本次操作的确认，不会写入任务配置。

## 退出码

```text
0  成功
1  未分类错误；或 doctor 发现任务读取问题（此时 result.loadIssues 非空）
2  命令用法错误
3  任务或运行记录不存在
4  输入校验失败
5  写入冲突或选择器歧义
6  高风险命令被默认拦截
7  任务正在运行
8  脚本运行失败、超时或被取消
```

## 运行环境

当前版本保持既有行为：任务继承启动它的进程环境。也就是说，App、CLI、后台调度进程的 `PATH` 和环境变量可能不同。稳定的任务应该在脚本里自己声明需要的环境，例如显式设置 `PATH`，不要依赖交互式 shell 的隐式配置。

可以用下面的命令检查当前 CLI 看到的路径和调度进程心跳：

```zsh
runshelf doctor --json
```
