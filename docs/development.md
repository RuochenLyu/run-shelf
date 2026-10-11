# Run Shelf 开发文档

这份文档给开发 Run Shelf 本身的人看。普通用户安装和使用请看仓库根目录的 `README.md`。

## 本机要求

```text
macOS 15 或更高版本
Xcode 26 或更高版本
Ruby
Bundler
```

如果命令行构建意外使用了 Command Line Tools，可以显式指定 Xcode：

```zsh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

## 安装工程生成依赖

```zsh
bundle install
```

新增、删除或移动 Swift 源码后，默认做增量同步，避免工程 UUID 抖动：

```zsh
bundle exec ruby scripts/sync_xcodeproj_files.rb
```

提交前可用只读模式检查文件引用与四个 target 的 membership：

```zsh
bundle exec ruby scripts/sync_xcodeproj_files.rb --check
```

只有工程损坏或需要从零重建时才运行完整生成器：

```zsh
bundle exec ruby scripts/generate_xcodeproj.rb
```

## 构建

构建主 App：

```zsh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project RunShelf.xcodeproj \
  -scheme RunShelf \
  -configuration Debug \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

构建 CLI：

```zsh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project RunShelf.xcodeproj \
  -scheme RunShelfCLI \
  -configuration Debug \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

启动调试版 App：

```zsh
open ".build/DerivedData/Build/Products/Debug/Run Shelf.app"
```

调试版 CLI 路径：

```text
.build/DerivedData/Build/Products/Debug/runshelf
```

## 测试

```zsh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test \
  -project RunShelf.xcodeproj \
  -scheme RunShelf \
  -configuration Debug \
  -derivedDataPath .build/TestDerivedData \
  CODE_SIGNING_ALLOWED=NO
```

## CLI 冒烟

本地测试 CLI 时，不要直接使用真实 App Support。给它一个临时目录：

```zsh
CLI=".build/DerivedData/Build/Products/Debug/runshelf"
ROOT="$(mktemp -d)"
export RUN_SHELF_APP_SUPPORT_DIR="$ROOT"

"$CLI" doctor --json
```

最小创建和运行：

```zsh
cat > "$ROOT/spec.json" <<'JSON'
{
  "slug": "dev-smoke",
  "name": "开发冒烟",
  "enabled": true,
  "script": "#!/bin/zsh\nset -euo pipefail\nprintf 'ok\\n'\n"
}
JSON

"$CLI" apply "$ROOT/spec.json" --dry-run --json
"$CLI" apply "$ROOT/spec.json" --json
"$CLI" run dev-smoke --wait --json
```

修改任务时先读取 revision token：

```zsh
TOKEN="$("$CLI" task show dev-smoke --json | jq -r '.result.revisionToken')"
"$CLI" apply "$ROOT/spec.json" --expected-revision "$TOKEN" --json
```

## 工程结构

```text
RunShelf/App/                 SwiftUI App 层
RunShelf/Core/                App、scheduler、CLI 共用的核心逻辑
RunShelf/Core/Storage/        文件读写、路径、任务仓库
RunShelf/Core/Runner/         任务运行、进程组、claim、retention
RunShelf/Core/Scheduler/      后台调度引擎
RunShelf/CLI/                 runshelf 命令行入口
RunShelf/SchedulerProcess/    后台辅助进程入口
RunShelfTests/                Core 测试
schemas/                      给 agent/工具消费的 JSON Schema
docs/                         需求、使用、开发、发布文档
```

## 关键约束

- 任务目录名必须等于 `TaskManifest.id`，不要改成 slug。
- `slug` 只是给人和 agent 使用的别名，可以为空，但不能作为目录名。
- `TaskSpec` 是 agent 的稳定写入面，不要让它无脑追随 `TaskManifest` 的所有内部字段。
- App、scheduler、CLI 都必须通过 `.run-claim/<run-id>/claim.json` 判断运行状态；`skip` 保持任务级互斥，`allow` 可同时存在多个 run claim。
- 计划运行由 `RunShelfScheduler __run-host`（`SchedulerRunHost`）在独立 session 中监督：调度进程先抢 claim，再 `posix_spawn(SETSID)` 宿主并把 claim 的 `processID` 改成宿主 pid。调度进程崩溃、被 launchd 重启或随 App 升级重新注册时，宿主继续执行超时/取消并写真实终态与失败通知；重启后的调度进程看到活跃 claim 会按并发策略跳过。`SchedulerEngine` 的默认 `scheduledRun` 仍是进程内运行，只有调度进程入口接入独立宿主。`TaskRunClaimLease.update` 在 claim 锁内读-改-写，调用方不能已持有同一把锁。
- `UNUserNotificationCenter` 只能在 Run Shelf.app 进程里调用；RunShelfScheduler 和 `runshelf` 是裸可执行文件，调用会断言 abort。调度进程的失败通知写入 `notifications/outbox/<taskId>--<runId>.json`，由 App 每 5 秒转投；App 未运行时通知会延迟到下次启动，超过 24 小时的条目丢弃。
- CLI 写入已有任务时应使用 `revisionToken` 做 CAS，避免覆盖 App 或另一个 CLI 的改动。
- 不要让 agent 或用户直接拼写 `task.json`；写入入口是 `runshelf apply`。

## 发布

发布打包、签名、公证和 GitHub Release 见 [release.md](release.md)。
