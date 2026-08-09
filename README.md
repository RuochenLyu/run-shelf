# Run Shelf

[![Check](https://github.com/RuochenLyu/run-shelf/actions/workflows/check.yml/badge.svg)](https://github.com/RuochenLyu/run-shelf/actions/workflows/check.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

简体中文 | [English](README.en.md)

Run Shelf 是一个 macOS 上的本地脚本管理工具。你可以把常用 Shell 脚本放进来，手动运行，按 cron 表达式定时运行，并查看每次运行的输出、退出码和失败原因。

它不是云端自动化平台，也不需要账号。任务、脚本、备注和运行历史都保存在本机文件里，不会上传。

![Run Shelf 主窗口：任务列表、脚本编辑器与运行计划](docs/assets/main-window.png)

## 功能

- 文件化任务：每个任务都是一个目录，包含 `task.json`、`run.sh`、`notes.md` 和运行历史。
- 手动运行：记录 stdout、stderr、退出码、脚本快照、耗时和状态。
- 定时调度：支持 5 段 cron，主窗口关闭后也能由后台辅助进程继续检查。
- 停止运行：超时、取消或后台终止时会清理整组子进程。
- 安全提示：编辑和 CLI 写入时会识别高风险命令。
- Agent/CLI 操作：内置 `runshelf`，Codex/Claude 可以用 JSON 契约创建、修改、运行和查询任务。

## 系统要求

```text
macOS 15 或更高版本
```

Run Shelf 最低支持 macOS 15。macOS 26 上会自然使用系统提供的新视觉效果；macOS 15 和 16 保持同一套核心功能，使用系统当时可用的原生控件外观。

## 安装

从 GitHub Release 下载最新版 `RunShelf-<version>-macOS15.dmg`，打开后把 `Run Shelf.app` 拖到 `Applications`。

第一次打开后，可以在设置里启用后台运行。后台运行不是必需项；不启用时，手动运行和任务编辑仍然可用。

## App 使用

1. 新建任务，填写名称、执行计划和脚本。
2. 手动运行任务，确认 stdout、stderr 和退出码符合预期。
3. 需要定时执行时启用任务，并在设置里开启后台运行。
4. 运行失败时，从历史记录进入 stdout/stderr 排查。

![Run Shelf 新建任务并立即运行的演示](docs/assets/demo.gif)

[高清视频](docs/assets/demo.mp4)

![Run Shelf 失败运行历史与 stderr 日志](docs/assets/run-history.png)

任务默认保存在：

```text
~/Library/Application Support/Run Shelf/tasks/
```

每个任务目录大致如下：

```text
task.json
run.sh
notes.md
runs/<run-id>/meta.json
runs/<run-id>/stdout.log
runs/<run-id>/stderr.log
runs/<run-id>/run.sh.snapshot
.run-claim/<run-id>/claim.json
```

`.run-claim` 是跨进程运行登记目录：`concurrency=skip` 同时只允许一个活动 claim，`concurrency=allow` 则按 run id 保存多个 claim。App、后台调度进程和 CLI 共用这套登记来查询、取消和回收运行。

## CLI 使用

发布版 App 内置 CLI：

```zsh
/Applications/Run\ Shelf.app/Contents/Library/Helpers/runshelf
```

如果想在终端里直接输入 `runshelf`：

```zsh
/Applications/Run\ Shelf.app/Contents/Library/Helpers/runshelf install-cli --json
```

macOS 默认 zsh 不一定包含 `~/.local/bin`。如果 `command -v runshelf` 找不到，把下面这一行加入 `~/.zshrc`：

```zsh
export PATH="$HOME/.local/bin:$PATH"
```

常用命令：

```zsh
runshelf task list --json
runshelf task show <id|slug> --json
runshelf task delete <id|slug> --json
runshelf apply spec.json --dry-run --json
runshelf apply spec.json --json
runshelf apply spec.json --dry-run --expected-revision <revisionToken> --json  # 预演修改
runshelf apply spec.json --expected-revision <revisionToken> --json   # 修改已有任务
runshelf run <id|slug> --wait --json
runshelf run <id|slug> --detach --json
runshelf run status <run-id> --json
runshelf run cancel <run-id> --json
runshelf run stop <run-id> --json                         # cancel 的别名
runshelf run log <run-id> --stdout
runshelf run log <run-id> --stderr
runshelf run log <run-id> --bytes 262144 --json
runshelf run log <run-id> --full
runshelf doctor --json
runshelf help agent
runshelf agent-setup                                      # 输出 agent 集成说明
runshelf agent-setup --write claude --json                # 写入 ~/.claude/CLAUDE.md
runshelf schema task-spec --example
runshelf schema cli-result
runshelf version --json
```

`apply` 写入的是 TaskSpec JSON，不是完整 `task.json`。创建任务时没有覆盖到的内部策略使用默认值；更新任务时没有覆盖到的内部策略会保留原值。
未知字段会直接返回校验错误；当前时区只支持字面值 `local`。日志默认只返回最后 1 MiB，JSON 调用方应检查 `truncated`，只有显式 `--full` 才读取完整文件。

所有 `--json` 响应都带 `schemaVersion`；也可以设置 `RUNSHELF_JSON=1` 强制 JSON 输出。`version --json` 返回 App 与 envelope schema 版本。前台运行失败时返回 `ok: false`、`error.code: "run_failed"` 和退出码 `8`，完整运行记录仍在 `result.run`。`schema` 命令输出原始 JSON（不包 envelope）。

最小 TaskSpec 示例：

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
  "notes": "由 CLI 管理。"
}
```

修改已有任务时，先 `task show` 读取 `revisionToken`，再带回 `apply --expected-revision`。如果 App 或另一个 CLI 在中间改过任务，CLI 会返回 `conflict`，避免静默覆盖。
更新已有任务时（包括 `--dry-run`）省略 `--expected-revision` 会返回 `usage`/退出码 `2`，且不会写盘。slug 不能使用 CLI 保留字 `status`、`log`、`cancel`、`stop`。

## 让 Codex/Claude 操作

最快的方式是让 CLI 自己完成集成：

```zsh
runshelf agent-setup --write claude
```

这会把一段集成说明幂等写入 `~/.claude/CLAUDE.md`（带标记块，重复执行只更新块内内容）；`--write agents` 则写当前目录的 `AGENTS.md`。也可以在 App 设置页的「命令行与 AI Agent」里一键完成同样的事。

如果想手动粘贴，把下面这段发给 Codex/Claude，它就能按 Run Shelf 的 CLI 契约操作任务：

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

更完整的 agent 操作说明见 [docs/agent-usage.md](docs/agent-usage.md)。

## 后台调度

应用内嵌后台辅助进程：

```text
Run Shelf.app/Contents/Library/LaunchServices/RunShelfScheduler
```

启用后台运行后，辅助进程每 30 秒检查一次任务，按分钟粒度匹配 cron。超过补跑时间窗口的任务会记为 `stale`，主应用会读取心跳文件来显示后台状态。

后台调度状态保存在：

```text
~/Library/Application Support/Run Shelf/scheduler-state.json
~/Library/Application Support/Run Shelf/scheduler-heartbeat.json
~/Library/Application Support/Run Shelf/scheduler.log
```

## 开发和发布

开发者文档已经从使用说明里拆出去：

- [docs/development.md](docs/development.md)：源码构建、测试、Xcode 工程生成和本地 CLI 冒烟。
- [docs/release.md](docs/release.md)：签名、DMG、公证和 GitHub Release。
- [docs/requirements.md](docs/requirements.md)：产品需求和实现约束。
- [docs/roadmap.md](docs/roadmap.md)：路线图和暂缓事项。

## 许可证

Run Shelf 使用 MIT 许可证，见 [LICENSE](LICENSE)。
