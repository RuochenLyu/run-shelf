# Run Shelf

Run Shelf 是一个 macOS 上的本地脚本管理工具。你可以把常用 Shell 脚本放进来，手动运行，按 cron 表达式定时运行，并查看每次运行的输出和失败原因。

它的重点不是做一套复杂的自动化平台，而是把个人电脑上的脚本管理做得清楚、可控、容易排查。任务、脚本、备注和历史记录都保存在本机文件里，不需要账号，也不会上传。

## 功能

- 文件化任务：每个任务都是一个目录，里面有 `task.json`、`run.sh`、`notes.md` 和运行历史。
- 内置模板：快速创建常见的本地巡检、清理、备份类脚本。
- Shell 编辑器：支持基础高亮，并在发现危险命令时给出提示。
- 手动运行：记录 stdout、stderr、退出码、脚本快照、耗时和运行状态。
- 停止运行：可以取消正在运行的任务，超时或取消时会清理整组子进程。
- 定时调度：支持 5 段 cron，提供预览，并记录错过执行窗口的任务。
- 后台调度：通过 `SMAppService` 管理后台辅助进程，主窗口关闭后也能继续检查任务。
- 数据留在本机：Run Shelf 不上传任务定义、脚本内容、日志或运行历史。

## 系统要求

```text
macOS 15 或更高版本
Xcode 26 或更高版本（从源码构建时需要）
Ruby + xcodeproj gem（重新生成 Xcode 工程时需要）
```

Run Shelf 最低支持 macOS 15。macOS 26 上会自然使用系统提供的新视觉效果；macOS 15 和 16 保持同一套核心功能，使用系统当时可用的原生控件外观。

## 安装

从 GitHub Release 下载最新版，解压 `RunShelf-<version>-macOS15.zip`，把 `Run Shelf.app` 拖到 `/Applications`。

后台调度默认不强制开启。第一次打开后，在设置里启用后台运行即可。

## 从源码构建

安装工程生成脚本需要的依赖：

```bash
gem install xcodeproj
```

新增或删除源码文件后，重新生成 Xcode 工程：

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

运行测试：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test \
  -project RunShelf.xcodeproj \
  -scheme RunShelf \
  -configuration Debug \
  -derivedDataPath .build/TestDerivedData \
  CODE_SIGNING_ALLOWED=NO
```

启动调试版：

```bash
open ".build/DerivedData/Build/Products/Debug/Run Shelf.app"
```

## 发布打包

发布包需要本机有 Developer ID Application 证书：

```bash
RUN_SHELF_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
scripts/package_release.sh 1.0.0
```

如果要公证，额外提供 `notarytool` 的钥匙串配置：

```bash
RUN_SHELF_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
RUN_SHELF_NOTARY_PROFILE="your-notary-profile" \
scripts/package_release.sh 1.0.0
```

产物会写到 `.build/release/RunShelf-<version>/`。

完整发布流程见 [docs/release.md](docs/release.md)。

## 数据位置

任务默认保存在：

```text
~/Library/Application Support/Run Shelf/tasks/
```

后台调度状态保存在：

```text
~/Library/Application Support/Run Shelf/scheduler-state.json
~/Library/Application Support/Run Shelf/scheduler-heartbeat.json
~/Library/Application Support/Run Shelf/scheduler.log
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
```

## 后台调度

应用内嵌了一个后台辅助进程：

```text
Run Shelf.app/Contents/Library/Helpers/RunShelfScheduler
```

同时内嵌 `SMAppService` 使用的 LaunchAgent plist：

```text
Run Shelf.app/Contents/Library/LaunchAgents/com.aix4u.runshelf.scheduler.plist
```

启用后台运行后，辅助进程每 30 秒检查一次任务，按分钟粒度匹配 5 段 cron。超过补跑时间窗口的任务会记为 `stale`，主应用会读取心跳文件来显示后台状态。

## 项目文档

- [docs/requirements.md](docs/requirements.md)：产品需求和实现约束。
- [docs/roadmap.md](docs/roadmap.md)：路线图和暂缓事项。
- [docs/release.md](docs/release.md)：发布前检查和打包流程。

## 许可证

Run Shelf 使用 MIT 许可证，见 [LICENSE](LICENSE)。
