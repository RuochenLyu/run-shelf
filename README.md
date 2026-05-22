# Run Shelf

Run Shelf 是一个简洁的 macOS 定时 Shell 脚本管理工具，用来创建、运行、查看和调试本地自动化脚本。

当前实现覆盖 P0-A/P0-B 主链路：主 App、文件任务模型、模板、Shell 编辑器、简单计划生成 Cron、Cron 预览、立即运行、日志历史、后台调度进程、失败通知入口和保留清理。

## 构建

要求：

```text
macOS 13+
Xcode 26+
Ruby xcodeproj gem
```

生成 Xcode project：

```bash
ruby scripts/generate_xcodeproj.rb
```

命令行构建：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project RunShelf.xcodeproj \
  -scheme RunShelf \
  -configuration Debug \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

启动调试版：

```bash
open ".build/DerivedData/Build/Products/Debug/Run Shelf.app"
```

## 数据目录

任务文件默认写入：

```text
~/Library/Application Support/Run Shelf/tasks/
```

后台调度状态写入：

```text
~/Library/Application Support/Run Shelf/scheduler-state.json
~/Library/Application Support/Run Shelf/scheduler-heartbeat.json
~/Library/Application Support/Run Shelf/scheduler.log
```

设置页会展示任务存储目录，并可调整新建任务使用的默认日志保留天数和最大运行记录数。

每个任务目录包含：

```text
task.json
run.sh
notes.md
runs/<run-id>/meta.json
runs/<run-id>/stdout.log
runs/<run-id>/stderr.log
runs/<run-id>/run.sh.snapshot
```

## 后台调度

主 App 构建时会把 `RunShelfScheduler` helper 嵌入：

```text
Run Shelf.app/Contents/Library/Helpers/RunShelfScheduler
```

同时把 SMAppService LaunchAgent plist 嵌入：

```text
Run Shelf.app/Contents/Library/LaunchAgents/com.aix4u.runshelf.scheduler.plist
```

App 设置页通过 `SMAppService.agent(plistName:)` 启动/停止后台调度进程。后台调度进程每 30 秒检查一次任务，每分钟粒度匹配 5 段 Cron；错过运行在默认 30 分钟窗口内补跑，超过窗口记录为 `stale`。

调度 smoke test 可使用独立数据目录，避免污染真实任务：

```bash
RUN_SHELF_APP_SUPPORT_DIR=/tmp/run-shelf-smoke \
  ".build/DerivedData/Build/Products/Debug/RunShelfScheduler"
```
