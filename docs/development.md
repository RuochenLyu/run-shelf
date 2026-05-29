# Run Shelf 开发文档

这份文档给开发 Run Shelf 本身的人看。普通用户安装和使用请看仓库根目录的 `README.md`。

## 本机要求

```text
macOS 15 或更高版本
Xcode 26 或更高版本
Ruby
xcodeproj gem
```

如果命令行构建意外使用了 Command Line Tools，可以显式指定 Xcode：

```zsh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

## 安装工程生成依赖

```zsh
gem install xcodeproj
```

新增、删除或移动源码文件后，重新生成 Xcode 工程：

```zsh
ruby scripts/generate_xcodeproj.rb
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
RunShelf/Scheduler/           后台辅助进程入口
RunShelfTests/                Core 测试
schemas/                      给 agent/工具消费的 JSON Schema
docs/                         需求、使用、开发、发布文档
```

## 关键约束

- 任务目录名必须等于 `TaskManifest.id`，不要改成 slug。
- `slug` 只是给人和 agent 使用的别名，可以为空，但不能作为目录名。
- `TaskSpec` 是 agent 的稳定写入面，不要让它无脑追随 `TaskManifest` 的所有内部字段。
- App、scheduler、CLI 都必须通过 `.run-claim` 判断同一个任务是否正在运行。
- CLI 写入已有任务时应使用 `revisionToken` 做 CAS，避免覆盖 App 或另一个 CLI 的改动。
- 不要让 agent 或用户直接拼写 `task.json`；写入入口是 `runshelf apply`。

## 发布

发布打包、签名、公证和 GitHub Release 见 [release.md](release.md)。
