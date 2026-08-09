# Run Shelf 需求文档

> 本文档是立项时的产品需求存档，保留用于追溯设计决策。当前功能现状以仓库根目录 README 与代码为准。

## 1. 产品基本信息

```text
Product Name: Run Shelf
Repository: runshelf
Bundle Identifier: com.aix4u.runshelf
Display Language: 简体中文优先
Platform: macOS
Product Type: Native macOS App
```

一句话定位：

> Run Shelf 是一个简洁的 macOS 定时 Shell 脚本管理工具，用来创建、运行、查看和调试本地自动化脚本。

英文 tagline：

> Scheduled shell scripts for macOS.

中文描述：

> 一个简洁的 macOS 定时脚本控制台。

## 2. 产品定位

Run Shelf 不是：

```text
crontab GUI
launchd plist 编辑器
Lingon 替代品
复杂工作流/DAG 工具
no-code 自动化平台
```

Run Shelf 是：

```text
Scheduled Shell Script Console
```

核心目标：

```text
让用户用 shell 表达任务；
用 UI 管理定时、状态、日志、历史和运行控制。
```

核心原则：

```text
Shell 是执行真相。
模板只生成 shell。
UI 不隐藏业务逻辑。
调度和观测由 App 负责。
```

## 3. 目标用户

首发目标用户：

```text
个人开发者
macOS power user
需要定时跑脚本的人
会写 shell / curl / Python / Node / git 命令的人
```

非首发目标：

```text
团队协作用户
服务器批量运维用户
完全不会写命令的普通用户
企业级任务编排用户
```

## 4. 典型使用场景

### 4.1 网站健康检查

用户需要定时请求一个接口，失败时收到通知并查看日志。

示例 cron：

```cron
*/15 * * * *
```

实际脚本：

```bash
#!/bin/zsh
set -euo pipefail

curl --fail --silent --show-error \
  --connect-timeout 10 \
  --max-time 30 \
  "https://example.com/health"
```

产品需要解决：

```text
执行时间可视化
下次运行时间预览
失败日志
失败通知
立即运行
任务启停
运行历史
```

### 4.2 爬虫 / 项目脚本

用户需要进入项目目录、激活环境、执行脚本。

```bash
#!/bin/zsh
set -euo pipefail

cd "$HOME/Projects/my-crawler"
source .venv/bin/activate
exec python -m crawler.main
```

产品不需要理解 Python、venv、爬虫。
这些都由 shell 表达。

产品需要解决：

```text
定时执行
日志查看
失败状态
上次运行结果
防止重复运行
运行历史
```

### 4.3 Git 同步

```bash
#!/bin/zsh
set -euo pipefail

cd "$HOME/Projects/notes"

git pull --rebase
git add -A
git commit -m "auto sync: $(date '+%Y-%m-%d %H:%M:%S')" || true
git push
```

### 4.4 本地备份

```bash
#!/bin/zsh
set -euo pipefail

rsync -av --delete \
  "$HOME/Documents/" \
  "/Volumes/Backup/Documents/"
```

### 4.5 磁盘空间检查

```bash
#!/bin/zsh
set -euo pipefail

usage="$(df -H "$HOME" | awk 'NR==2 { gsub("%", "", $5); print $5 }')"

if [ "$usage" -ge 90 ]; then
  echo "Home disk usage is ${usage}%" >&2
  exit 1
fi

echo "Home disk usage is ${usage}%"
```

### 4.6 首次启动示例任务

P0 可以在任务目录为空时创建 1-2 个示例任务，帮助用户理解产品形态。

示例任务要求：

```text
默认停用
名称包含“示例”
脚本内容通用、不包含个人服务或私有账号
可以直接删除
不影响用户手动新建任务
```

推荐示例：

```text
网站健康检查（示例）
磁盘空间检查（示例）
```

## 5. 产品设计原则

### 5.1 配置尽可能少

新建任务只需要三件事：

```text
任务名
执行时间
run.sh
```

高级选项默认隐藏。

### 5.2 简单能用，复杂也能用

简单用户看到：

```text
任务列表
任务详情
执行时间
脚本编辑器
立即运行
日志
```

复杂用户可以展开：

```text
Cron 表达式
并发策略
超时
错过运行策略
日志保留
通知
模板片段
```

### 5.3 不做隐藏执行配置

不要把这些拆成隐藏字段：

```text
Working Directory
Shell
Setup Script
Command
Python venv
Node runtime
Env file
```

这些都应该写在 `run.sh` 里：

```bash
#!/bin/zsh
set -euo pipefail

cd "$HOME/Projects/foo"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
source .venv/bin/activate
exec python -m main
```

### 5.4 模板只是脚手架

模板只生成：

```text
task.json
run.sh
notes.md
```

模板不是任务类型系统。

不要做：

```text
Python Task
HTTP Task
Crawler Task
Backup Task
```

应该做：

```text
Blank Shell Script
Project Script
curl Request
Git Sync
Node Script
Python Script
rsync Backup
```

## 6. MVP 范围

### 6.1 P0 必须实现

```text
任务列表
任务详情页
任务新建/编辑/删除
任务启用/停用
run.sh 编辑器
Shell 语法高亮
任务模板
简单执行时间选择
高级 Cron 表达式输入
下次运行时间预览
立即运行
运行状态
运行历史
stdout/stderr 日志
一个后台调度进程
App 关闭后任务仍能按计划运行
```

### 6.2 P1 再做

```text
菜单栏入口
crontab 导入
ShellCheck 集成
日志搜索
Keychain secret 管理
失败原因诊断
危险命令提醒
任务导出/导入
脚本版本 diff
通知规则增强
```

### 6.3 暂不做

```text
团队协作
远程机器
DAG 工作流
复杂权限系统
root LaunchDaemon 管理
Mac App Store 版本
专用 HTTP 表单任务
专用 Python/Node 任务类型
```

## 7. 核心信息架构

### 7.1 任务结构

每个任务是一个目录：

```text
~/Library/Application Support/Run Shelf/tasks/<task-id>/
  task.json
  run.sh
  notes.md
  runs/
    <run-id>/
      meta.json
      stdout.log
      stderr.log
      run.sh.snapshot
```

说明：

```text
task.json：调度、启停、runner 策略
run.sh：真实执行逻辑
notes.md：用户备注，可选
runs/：每次运行记录
run.sh.snapshot：每次运行时的脚本快照
```

### 7.2 task.json 示例

```json
{
  "schemaVersion": 1,
  "id": "9F6B2D63-9F7F-4D4B-8C5D-6B55E2E58A21",
  "name": "网站健康检查（示例）",
  "description": "每 15 分钟请求一次示例健康检查地址；示例默认停用，可删除",
  "enabled": false,
  "createdAt": "2026-05-22T10:00:00+08:00",
  "updatedAt": "2026-05-22T10:00:00+08:00",
  "schedule": {
    "type": "cron",
    "expression": "*/15 * * * *",
    "timezone": "local"
  },
  "runner": {
    "concurrency": "skip",
    "timeoutSeconds": 0,
    "missedRunPolicy": {
      "type": "skipIfLate",
      "maxDelaySeconds": 1800
    }
  },
  "notifications": {
    "onFailure": true,
    "onSuccess": false
  },
  "retention": {
    "days": 30,
    "maxRuns": 500
  }
}
```

### 7.3 run meta 示例

```json
{
  "runId": "2026-05-22T10-15-00+08-00",
  "taskId": "9F6B2D63-9F7F-4D4B-8C5D-6B55E2E58A21",
  "trigger": "scheduled",
  "status": "success",
  "exitCode": 0,
  "startedAt": "2026-05-22T10:15:00+08:00",
  "endedAt": "2026-05-22T10:15:02+08:00",
  "durationMs": 2010,
  "scriptSha256": "6d5f7a...",
  "stdoutPath": "stdout.log",
  "stderrPath": "stderr.log"
}
```

## 8. 状态模型

### 8.1 任务状态

```text
enabled
disabled
running
failed
```

UI 展示优先级：

```text
running > failed > enabled > disabled
```

### 8.2 运行状态

```text
pending
running
success
failed
skipped
timeout
cancelled
stale
```

说明：

```text
success：exit code = 0
failed：exit code != 0
timeout：超过设置的 timeout
skipped：并发策略导致跳过
stale：错过运行且超过补跑窗口
cancelled：用户手动停止
```

## 9. 调度设计

### 9.1 Schedule 类型

P0 支持：

```text
每天固定时间
每周固定时间
每月固定日期
每隔 N 分钟/小时
高级 Cron 表达式
手动运行
```

### 9.2 简单模式

示例：

```text
每天
08:00, 12:00, 18:00
```

内部可转换为：

```cron
0 8,12,18 * * *
```

### 9.3 高级 Cron 模式

P0 支持 5 段 cron：

```text
minute hour day-of-month month day-of-week
```

支持语法：

```text
*
,
-
/
数字
```

示例：

```cron
*/15 * * * *
0 8,12,18 * * *
0 9 * * 1-5
```

P0 不支持：

```text
秒级 cron
@reboot
@daily
L
W
#
复杂自然语言表达式
```

### 9.4 下次运行预览

保存前必须展示：

```text
下次 5 次运行时间
```

示例：

```text
下次运行
- 今天 18:00
- 明天 08:00
- 明天 12:00
- 明天 18:00
- 后天 08:00
```

### 9.5 Cron 编辑体验参考

高级 Cron 输入可以参考 `crontab.guru` 的交互方式：输入表达式时即时解释含义、标出错误字段、提供常见示例，并展示接下来几次运行时间。([Crontab.guru][4])

Run Shelf 只参考它的 Cron 表达式编辑体验，不把产品做成 crontab GUI：

```text
Cron 是调度表达式
run.sh 是执行真相
运行历史、失败通知、日志和状态由 Run Shelf 管理
```

## 10. Runner 策略

### 10.1 并发策略

P0 支持：

```text
skip
allow
```

默认：

```text
skip
```

解释：

```text
skip：如果上一次还没结束，本次跳过并记录 skipped
allow：允许多个实例同时运行
```

P1 可加：

```text
queue
killPrevious
```

### 10.2 超时

默认：

```text
timeoutSeconds = 0
```

表示不限制。

用户设置后：

```text
超过 timeout 后终止进程
状态记为 timeout
写入 stderr
```

### 10.3 错过运行策略

默认：

```text
skipIfLate 30 分钟
```

含义：

```text
如果 Mac 睡眠或后台调度进程未运行导致错过任务；
醒来后如果距离原计划时间不超过 30 分钟，则补跑一次；
超过 30 分钟则跳过并记录 stale。
```

P0 UI 文案：

```text
错过运行：迟到 30 分钟内补跑，否则跳过
```

## 11. UI 设计

### 11.1 主窗口布局

```text
┌────────────────────────────────────────────────────────────┐
│ Toolbar: 新建任务 / 立即运行 / 启用开关 / 保存             │
├───────────────┬──────────────────────────────┬─────────────┤
│ 左侧任务列表   │ 中间任务详情                  │ 右侧状态栏   │
│               │                              │             │
│ - 网站检查     │ 标题 / 描述                    │ 状态         │
│ - 项目脚本     │ 执行时间                       │ 下次运行     │
│ - Git 同步     │ run.sh 编辑器                  │ 上次运行     │
│               │                              │ 最近历史     │
├───────────────┴──────────────────────────────┴─────────────┤
│ 底部：运行历史 / stdout / stderr                            │
└────────────────────────────────────────────────────────────┘
```

### 11.2 左侧任务列表

每个任务展示：

```text
任务名
启用状态
上次结果
下次运行时间
失败标记
```

排序：

```text
失败任务优先
正在运行优先
然后按下次运行时间
```

### 11.3 任务详情页

字段：

```text
任务名
任务描述
启用/停用
执行时间
run.sh 编辑器
立即运行
保存
```

Tab：

```text
脚本
备注
运行历史
日志
```

默认打开：

```text
脚本
```

### 11.4 右侧 Inspector

展示：

```text
状态
下次运行
上次运行
上次耗时
最近失败
并发策略
超时设置
通知设置
```

### 11.5 新建任务流程

步骤：

```text
1. 选择模板
2. 输入任务名
3. 设置执行时间
4. 编辑 run.sh
5. 保存并启用
```

P0 模板：

```text
空白脚本
项目脚本
curl 请求
Git 同步
Node 脚本
Python 脚本
rsync 备份
```

## 12. Shell 编辑器

### 12.1 技术方案

主界面用 SwiftUI。
Shell 编辑器用 AppKit `NSTextView`，通过 SwiftUI `NSViewRepresentable` 嵌入。`NSTextView` 是 AppKit 文本系统的前端类，负责文本绘制和用户编辑事件；`NSViewRepresentable` 用于在 SwiftUI 中创建和管理 AppKit 的 `NSView`。([Apple Developer][1])

### 12.2 P0 编辑器能力

```text
等宽字体
Shell 语法高亮
撤销/重做
Cmd+S 保存
查找
插入模板片段
路径选择后插入 cd "..."
显示未保存状态
Run Now
```

### 12.3 P0 高亮范围

```text
注释：# ...
字符串："..." / '...'
变量：$HOME / ${TOKEN}
常见命令：cd / source / export / curl / python / node / git / rsync
危险命令提示：rm -rf / sudo / chmod -R / curl | sh
```

### 12.4 不做完整 IDE

P0 不做：

```text
自动补全
tree-sitter
minimap
代码折叠
多文件编辑
终端模拟器
完整 bash parser
```

## 13. 模板设计

### 13.1 空白脚本

```bash
#!/bin/zsh
set -euo pipefail

# Write your script here
```

### 13.2 项目脚本

```bash
#!/bin/zsh
set -euo pipefail

cd "$HOME/Projects/my-project"

# Optional: make Homebrew tools available
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# Optional: activate project environment
# source .venv/bin/activate

# Replace this command
exec ./run.sh
```

### 13.3 curl 请求

```bash
#!/bin/zsh
set -euo pipefail

curl --fail --silent --show-error \
  --connect-timeout 10 \
  --max-time 30 \
  "https://example.com"
```

### 13.4 Git 同步

```bash
#!/bin/zsh
set -euo pipefail

cd "$HOME/Projects/my-repo"

git pull --rebase
git add -A
git commit -m "auto sync: $(date '+%Y-%m-%d %H:%M:%S')" || true
git push
```

### 13.5 Node 脚本

```bash
#!/bin/zsh
set -euo pipefail

cd "$HOME/Projects/my-node-project"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

exec node scripts/main.mjs
```

### 13.6 Python 脚本

```bash
#!/bin/zsh
set -euo pipefail

cd "$HOME/Projects/my-python-project"
source .venv/bin/activate

exec python -m main
```

### 13.7 rsync 备份

```bash
#!/bin/zsh
set -euo pipefail

rsync -av --delete \
  "$HOME/Documents/" \
  "/Volumes/Backup/Documents/"
```

## 14. 日志与历史

### 14.1 每次运行必须记录

```text
run id
触发来源
开始时间
结束时间
耗时
exit code
运行状态
stdout
stderr
脚本 sha256
脚本快照
```

### 14.2 触发来源

```text
scheduled
manual
retry
```

P0 支持：

```text
scheduled
manual
```

### 14.3 日志查看

P0 支持：

```text
stdout
stderr
合并查看
复制日志
打开日志所在目录
```

P1 支持：

```text
日志搜索
日志过滤
失败原因高亮
日志脱敏
```

## 15. 后台调度架构

### 15.1 推荐架构

```text
Run Shelf App
  ↓ 编辑 task.json / run.sh

后台调度进程
  ↓ 扫描任务、计算 due runs

Task Runner
  ↓ 执行 run.sh、记录日志和历史
```

### 15.2 不采用每个任务一个 LaunchAgent

原因：

```text
任务越多 plist 越多
复杂 cron 不好表达
运行历史不好统一
错过运行策略不好统一
日志管理分散
```

P0 只注册一个后台调度进程：

```text
com.aix4u.runshelf.scheduler
```

### 15.3 后台调度进程注册

Run Shelf 首版最低支持 macOS 15。后台调度进程使用 `SMAppService` 管理 app 的 helper / Login Item；Apple 文档说明 macOS 13+ 可用 `SMAppService` 注册和控制 LoginItems、LaunchAgents、LaunchDaemons。([Apple Developer][2])

macOS 26 上使用系统自动提供的新视觉表现；macOS 15/16 保持同一套核心功能，不为首版单独仿制 macOS 26 视觉效果。

### 15.4 常驻模型

Run Shelf 的常驻部分是后台调度进程，不是主窗口本身。

```text
主 App：用户打开时作为控制台使用，负责编辑、查看和手动触发
后台调度进程：随系统登录启动，负责按计划运行任务
```

要求：

```text
关闭主 App 后，后台调度进程仍能运行计划任务
主 App 重新打开后，从文件系统读取后台调度进程写入的历史
任务失败通知由后台调度进程发出
```

菜单栏常驻入口放到 P1，不阻塞 P0。

### 15.5 后台调度进程行为

后台调度进程负责：

```text
启动时扫描所有任务
每分钟计算 due tasks
执行到期任务
处理 missed run
处理并发策略
写入运行记录
发通知
清理过期日志
```

后台调度进程不负责：

```text
展示 UI
编辑脚本
理解业务逻辑
上传数据
```

### 15.6 Run Now 行为

`立即运行` 必须走同一个 Task Runner。

要求：

```text
手动运行和定时运行使用同一套 runner
日志结构一致
运行历史一致
状态一致
```

## 16. 技术选型

### 16.1 App

```text
SwiftUI
Swift
AppKit bridge
String Catalog
```

简体中文首发用 Xcode String Catalog 管理本地化文本；Apple 文档将 String Catalog 用于在 Xcode 中管理和翻译 app 文本。([Apple Developer][3])

### 16.2 编辑器

```text
NSTextView wrapped by NSViewRepresentable
```

不使用纯 SwiftUI `TextEditor` 作为核心代码编辑器。

### 16.3 数据

```text
文件系统为 source of truth
task.json
run.sh
notes.md
runs/*.json
logs
```

P0 不用 SwiftData 做核心存储。

原因：

```text
脚本和日志天然是文件
方便备份
方便 Git 管理
方便用户直接打开
避免数据库和文件状态不同步
```

### 16.4 调度

```text
自研轻量 scheduler
支持 5-field cron subset
每分钟检查 due tasks
本地时间
```

### 16.5 Runner

使用 Swift `Process` 执行脚本。

执行方式：

```text
/bin/zsh <task-dir>/run.sh
```

但如果 `run.sh` 有 shebang，也允许后续改为：

```text
exec run.sh
```

P0 推荐统一用：

```text
chmod +x run.sh
exec run.sh
```

原因：

```text
尊重 shebang
用户可用 #!/bin/bash / #!/bin/zsh / #!/usr/bin/env python
```

## 17. 安全与权限

### 17.1 基本原则

```text
Run Shelf 以当前用户权限运行脚本
P0 不做 root 任务
P0 不请求管理员权限
P0 不自动修改系统级 LaunchDaemon
```

### 17.2 Secret

P0 不做完整 secret 管理。

P0 只保证：

```text
不主动打印环境变量
不主动打印 task.json 中的敏感内容
日志只记录脚本 stdout/stderr
```

用户如果在脚本里 `echo $TOKEN`，P0 不保证自动脱敏。

P1 再做：

```text
Keychain secret store
runshelf secret get NAME
日志脱敏
secret 引用检测
```

### 17.3 危险命令提醒

P0 可做轻量提示，不阻止执行。

提示命令：

```text
rm -rf
sudo
chmod -R
chown -R
curl ... | sh
```

UI 文案：

```text
脚本包含高风险命令，请确认后运行。
```

## 18. 通知

### 18.1 P0

```text
失败通知
```

默认：

```text
失败时通知：开启
成功时通知：关闭
```

失败通知是 Run Shelf 相比原生 crontab 的核心提升之一。crontab 只负责按时触发命令，不负责告诉用户失败、展示失败上下文或统一保留日志。

P0 失败通知要求：

```text
由后台调度进程或主 App 中的同一套 TaskRunner 触发
包含任务名
包含退出码或 timeout/cancelled 状态
提示用户打开 Run Shelf 查看日志
通知授权被拒绝时不影响任务运行
失败历史仍然写入 runs/
```

如果技术成本可控，点击失败通知应打开 Run Shelf 并定位到对应任务；否则 P0 至少保证通知内容足够定位任务。

### 18.2 P1

```text
成功通知
运行超过 N 分钟通知
连续失败 N 次通知
任务恢复成功通知
```

## 19. 中文 UI 文案

基础词汇：

```text
任务
新建任务
立即运行
启用
停用
已启用
已停用
运行中
成功
失败
跳过
超时
执行时间
下次运行
上次运行
运行历史
日志
标准输出 stdout
错误输出 stderr
退出码 exit code
Cron 表达式
高级
模板
脚本
备注
保存
取消
删除
复制
打开目录
```

状态文案：

```text
活跃
已停用
运行中
上次成功
上次失败
下次运行：今天 18:01
暂无运行记录
```

## 20. 设置页

P0 设置项：

```text
任务存储目录
日志保留天数
最大运行记录数
后台调度进程状态
启动/停止后台调度进程
打开数据目录
```

默认值：

```text
日志保留：30 天
最大运行记录：500 条/任务
```

## 21. Repo 结构建议

```text
runshelf/
  README.md
  docs/
    requirements.md
  RunShelf/
    RunShelfApp.swift
    App/
      Views/
      Models/
      Stores/
      Localization/
    Core/
      TaskModel/
      Scheduler/
      Runner/
      Logging/
      Templates/
      Cron/
    Editor/
      ShellScriptEditor.swift
      ShellSyntaxHighlighter.swift
    SchedulerProcess/
      RunShelfSchedulerMain.swift
    Resources/
      Localizable.xcstrings
      Templates/
```

更清晰的模块：

```text
RunShelfApp
SchedulerCore
ShellEditor
RunShelfScheduler
TaskRunner
```

## 22. 关键类/模块

### 22.1 TaskStore

职责：

```text
扫描任务目录
读取 task.json
写入 task.json
创建任务目录
删除任务
监听文件变化
```

### 22.2 ScriptStore

职责：

```text
读取 run.sh
保存 run.sh
创建脚本快照
插入模板片段
```

### 22.3 CronSchedule

职责：

```text
解析 5-field cron
验证表达式
计算下次运行
返回 next 5 runs
```

### 22.4 Scheduler

职责：

```text
扫描 enabled tasks
计算 due tasks
处理 missed run
调用 TaskRunner
```

### 22.5 TaskRunner

职责：

```text
创建 run directory
处理 concurrency
执行 run.sh
捕获 stdout/stderr
记录 meta.json
返回状态
```

### 22.6 ShellScriptEditor

职责：

```text
显示和编辑 run.sh
语法高亮
保存状态
查找
快捷键
```

## 23. 验收标准

### 23.1 新建任务

给定用户新建一个空白任务：

```text
输入任务名
选择每天 09:00
编辑 run.sh
保存
```

应满足：

```text
任务出现在左侧列表
task.json 被创建
run.sh 被创建
下次运行显示正确
用户手动新建的任务默认启用；首次启动示例任务默认停用
```

### 23.2 立即运行

给定任务脚本：

```bash
#!/bin/zsh
set -euo pipefail
echo "hello"
```

点击立即运行后：

```text
状态变为 running
完成后状态为 success
stdout 显示 hello
运行历史新增一条
meta.json 记录 exitCode = 0
```

### 23.3 失败记录

给定任务脚本：

```bash
#!/bin/zsh
set -euo pipefail
exit 1
```

运行后：

```text
状态为 failed
exit code = 1
运行历史新增失败记录
触发失败通知
```

### 23.4 定时运行

给定任务设置为每分钟运行：

```cron
* * * * *
```

关闭主 App 后：

```text
后台调度进程仍运行
任务按计划执行
runs/ 产生运行记录
重新打开 App 后能看到历史
```

### 23.5 并发 skip

给定一个长运行任务：

```bash
#!/bin/zsh
sleep 120
```

调度为每分钟一次，concurrency = skip：

```text
第一次运行中
第二次触发被跳过
运行历史记录 skipped
不会启动第二个进程
```

## 24. P0 实现顺序

### Milestone 1：项目骨架

```text
创建 Xcode SwiftUI 项目
设置 Bundle ID: com.aix4u.runshelf
设置简体中文 String Catalog
完成主窗口三栏布局
```

### Milestone 2：任务文件模型

```text
实现 task.json schema
实现 TaskStore
实现任务创建/删除/读取/保存
实现默认任务目录
```

### Milestone 3：Shell 编辑器

```text
实现 NSTextView wrapper
实现 run.sh 读取/保存
实现基础 shell 高亮
实现 Cmd+S 保存
```

### Milestone 4：模板

```text
实现模板列表
实现模板生成 task.json + run.sh
实现 Project/curl/Git/Node/Python/rsync 模板
```

### Milestone 5：立即运行

```text
实现 TaskRunner
捕获 stdout/stderr
写入 runs/<run-id>/
更新 UI 状态
展示日志
```

### Milestone 6：调度

```text
实现 cron parser
实现 next runs preview
实现 Scheduler
实现每分钟 due task 检查
```

### Milestone 7：后台调度进程

```text
实现后台调度进程
使用 SMAppService 注册 helper / Login Item
App 关闭后任务仍运行
设置页显示后台调度进程状态
```

### Milestone 8：打磨

```text
失败通知
日志保留清理
危险命令提示
中文文案统一
README
```

## 25. Codex 首轮任务指令

给 Codex 的第一条任务可以这样写：

```text
Build the initial macOS SwiftUI app for Run Shelf.

Product:
- Name: Run Shelf
- Bundle ID: com.aix4u.runshelf
- Language: Simplified Chinese first
- Purpose: A simple macOS app for scheduled shell scripts

Architecture:
- SwiftUI main app
- File-based task storage
- Task = task.json + run.sh + notes.md + runs/
- Shell editor should be NSTextView wrapped in NSViewRepresentable
- Do not use SwiftData as source of truth
- Do not build Python/HTTP-specific task types
- Templates only generate shell scripts

Implement first:
1. Three-column main window:
   - left task list
   - center task detail and run.sh editor
   - right status inspector
2. TaskStore that reads/writes tasks under:
   ~/Library/Application Support/Run Shelf/tasks/
3. New task flow using templates:
   - Blank Shell Script
   - Project Script
   - curl Request
   - Git Sync
   - Node Script
   - Python Script
   - rsync Backup
4. Shell editor:
   - monospace font
   - edit run.sh
   - save with Cmd+S
   - basic shell syntax highlighting
5. Run Now:
   - execute run.sh
   - capture stdout/stderr
   - write runs/<run-id>/meta.json, stdout.log, stderr.log
   - show run history in UI

Do not implement the background scheduler process yet in the first commit.
Keep the project simple and compileable after each milestone.
```

## 26. 最终边界

Run Shelf 的核心不是“配置更多字段”，而是：

```text
少配置
直接写 shell
可靠定时
清楚知道有没有跑
失败时能看到为什么
```

产品抽象最终定为：

```text
Task = Schedule + run.sh + Runner History
```

不是：

```text
Task = 一堆表单字段
```

[1]: https://developer.apple.com/documentation/appkit/nstextview "NSTextView | Apple Developer Documentation"
[2]: https://developer.apple.com/documentation/servicemanagement/smappservice "SMAppService | Apple Developer Documentation"
[3]: https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog "Localizing and varying text with a string catalog"
[4]: https://crontab.guru/ "Crontab.guru"
