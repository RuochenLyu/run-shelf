# Run Shelf Roadmap

> 本文档是 P0/P1 阶段的开发路线存档，保留用于追溯工程决策。当前进展以 CHANGELOG 与代码为准。

本文档把 `docs/requirements.md` 拆成可执行的开发顺序，并记录已经确认采用的默认工程决策。

## 1. 当前结论

`requirements.md` 的产品边界足够清晰，可以开始开发：

```text
Task = Schedule + run.sh + Runner History
```

P0 的核心交付不是做复杂配置系统，而是：

```text
创建任务
编辑 run.sh
预览下次运行
立即运行
记录日志和历史
后台按计划运行
```

为了避免一次性实现失控，P0 应拆成两个阶段：

```text
P0-A：主 App 可用，支持文件模型、模板、编辑器、立即运行、日志历史
P0-B：后台调度进程可用，支持调度、错过运行、通知、保留清理
```

第一轮提交不做后台调度进程。先让主 App 和 TaskRunner 跑通，否则后台调度进程问题会和 UI、存储、Runner 问题叠在一起。

## 1.1 当前实现状态

截至 2026-07-11，P0-A、P0-B 和首轮发布链路已实现：

```text
P0-A：项目骨架、文件模型、模板、编辑器、立即运行、日志历史、Cron 预览
P0-B：Scheduler Core、后台调度进程、失败通知入口、危险命令提示、保留清理、设置页状态
发布：正式 AppIcon、菜单栏入口、Developer ID 签名、公证、staple、DMG/zip 发布脚本
```

已验证：

```text
xcodebuild Debug 构建通过
隔离数据目录下后台调度进程可触发 scheduled run 并写入 heartbeat/runs
主 App UI 可显示简单计划、Cron 预览、编辑器片段、后台调度状态和默认保留策略
```

保留到 P1 或发布打磨：

```text
ShellCheck、日志搜索、Keychain secret、crontab 导入、导入导出、脚本版本 diff
```

## 2. 已确认的默认工程决策

这些不是产品方向问题，而是后续实现必须稳定遵守的工程边界。

### 2.1 macOS 与 Xcode 版本

现状：

```text
需求文档指定 macOS 原生 App，后台调度进程使用 SMAppService。
SMAppService 约束会影响最低系统版本、签名、helper target 和调试方式。
```

默认决策：

```text
最低支持 macOS 15
开发使用当前稳定版 Xcode
P0 不兼容 macOS 14 及以下
```

原因：

```text
保留 SMAppService / MenuBarExtra / SwiftUI 原生控件的稳定路径
让 macOS 26 自动呈现系统新视觉，同时允许 macOS 15+ 使用同一套核心功能
避免为更旧系统增加 LaunchAgent 兼容层
```

### 2.2 App 沙盒、签名与发布方式

现状：

```text
需求文档明确暂不做 Mac App Store 版本，但没有说明 P0 是否开启 App Sandbox。
Run Shelf 需要执行用户脚本、访问用户选择的项目目录、写 Application Support、注册后台调度进程。
```

默认决策：

```text
P0 先做 Developer ID / 本地直接分发路径
P0 不开启 App Sandbox
启用 Hardened Runtime；正式版本产出已签名、公证并 staple 的 DMG 和 zip
```

当前发布结果：

```text
v1.0.0 起已提供外部分发版本
标准发布流程见 docs/release.md
```

### 2.3 文件写入一致性

现状：

```text
App 会编辑 task.json/run.sh。
后台调度进程会读取 task.json/run.sh 并写 runs/。
App 和后台调度进程可能同时访问同一个任务目录。
```

默认决策：

```text
task.json 使用原子写入：写临时文件后 rename
run.sh 保存也使用原子写入
runs/<run-id>/ 只由 TaskRunner 创建和写入
App 只读 runs/，不修改历史记录
后台调度进程扫描时跳过无法解析或写入中的任务，并记录诊断
```

需要实现时明确：

```text
是否引入轻量文件锁
任务删除时如何处理正在运行的进程
run.sh 保存中触发调度时使用旧脚本还是新脚本
```

默认决策：

```text
P0 不做全局文件锁
删除运行中任务时先停用，再提示不能删除运行中的任务
运行开始前创建 run.sh.snapshot，实际执行 snapshot
```

### 2.4 task id 与 schema 迁移

现状：

```text
需求示例需要稳定 id，但不应依赖任务名或业务语义。
```

默认决策：

```text
task id 使用 UUID 或 ULID，不依赖任务名
目录名等于 task id
task.json 必须包含 schemaVersion
P0 只支持 schemaVersion = 1
遇到未来版本时只读展示错误，不尝试写回
```

原因：

```text
避免中文任务名、重名、改名导致路径变化
为后续 schema 迁移留空间
```

### 2.5 Cron 语义

现状：

```text
P0 支持 5 段 cron，但没有规定 day-of-month 和 day-of-week 同时受限时是 OR 还是 AND。
也没有说明夏令时、月底不存在日期、本地时区变化的行为。
```

默认决策：

```text
采用常见 cron 语义：day-of-month 和 day-of-week 同时受限时按 OR 匹配
所有计算使用当前系统本地时区
P0 不做自定义时区
P0 不做夏令时特殊补偿，只按系统 Calendar 计算下一次匹配时间
```

需要实现时写进测试：

```text
*/15 * * * *
0 8,12,18 * * *
0 9 * * 1-5
0 9 1 * *
0 9 1 * 1
```

### 2.6 简单计划与 Cron 的内部模型

现状：

```text
需求中同时有“每天/每周/每月/每隔 N 分钟/小时”和高级 Cron。
task.json 示例只有 type = cron。
```

默认决策：

```text
P0 内部统一存 cron expression
简单模式只是 UI 生成 cron
每隔 N 分钟/小时只支持能准确表达为 5 段 cron 的范围
```

注意：

```text
每隔 90 分钟不能被 5 段 cron 严格表达为滚动间隔。
P0 应限制简单模式，不要假装支持所有 interval。
```

P0 简单模式：

```text
每天多个固定时间
每周固定星期和时间
每月固定日期和时间
每 N 分钟：N 必须是 1-59 且能整除 60
每 N 小时：N 必须是 1-23 且能整除 24
```

### 2.7 Runner 执行方式

现状：

需求中同时出现：

```text
/bin/zsh <task-dir>/run.sh
chmod +x run.sh
exec run.sh
```

默认决策：

```text
P0 执行 run.sh.snapshot
保存脚本时 chmod +x run.sh
运行时 chmod +x run.sh.snapshot
通过 Process 直接执行 snapshot 路径
尊重 shebang
```

执行环境默认：

```text
currentDirectoryURL = task directory
继承 App 或后台调度进程的进程环境
不自动加载用户 login shell 环境
需要 PATH、venv、cd 的内容写在 run.sh 里
```

原因：

```text
符合“Shell 是执行真相”
避免 UI 隐藏 Working Directory、Shell、Env file 等执行配置
```

### 2.8 进程取消与超时

现状：

```text
需求定义了 timeout/cancelled，但没有说明如何杀子进程树。
Shell 脚本经常会启动 curl、python、node、rsync 等子进程。
```

默认决策：

```text
每次运行创建独立进程组
超时和取消时终止整个进程组
先 SIGTERM，短暂等待后 SIGKILL
stderr 追加超时或取消说明
```

需要 Spike：

```text
Swift Process 在 macOS 下创建和终止进程组的实现方式
后台调度进程中取消运行的 IPC 或状态传递方式
```

### 2.9 日志写入策略

现状：

```text
需求要求 stdout/stderr 日志和合并查看，但没有规定实时写入还是结束后写入，也没有规定单次日志大小上限。
```

默认决策：

```text
stdout.log 和 stderr.log 实时追加写入
UI 可以轮询或监听文件变化刷新
P0 合并查看按读取时根据流来源粗略合并，或者先只提供 stdout/stderr 分栏
单次日志 P0 不强制截断，依赖保留策略清理历史
```

需要后续确认：

```text
是否必须在 P0 支持严格按时间顺序合并 stdout/stderr
是否需要单次运行日志大小上限
```

推荐：

```text
P0 不做严格流交织合并；那需要额外 timestamped event log。
```

### 2.10 后台调度进程与 App 的通信方式

现状：

```text
需求说 App 关闭后后台调度进程仍运行，但没有定义 App 如何触发 Run Now、读取后台调度进程状态、停止任务。
```

默认决策：

```text
P0-A 的 Run Now 由主 App 直接调用 TaskRunner
P0-B 引入后台调度进程后，计划任务由后台调度进程执行
P0-B 的 Run Now 仍可由主 App 直接执行同一 TaskRunner 代码
后台调度进程状态先通过 SMAppService 状态和心跳文件展示
```

原因：

```text
避免 P0 过早引入 XPC
满足“手动运行和定时运行使用同一套 runner”的要求
```

需要后续确认：

```text
是否 P1 再做 XPC，让 App 能让后台调度进程代跑手动任务和取消运行
```

### 2.11 通知权限

现状：

```text
需求要求失败通知默认开启，但 macOS 通知需要用户授权。
```

默认决策：

```text
首次需要发送失败通知时请求通知权限
设置页展示通知授权状态
用户拒绝授权时仍记录失败历史，不阻断任务运行
```

### 2.12 常驻模型与失败通知

现状：

```text
用户需要从 GUI 获得 crontab 没有的失败反馈，但主窗口不应该成为任务能否运行的前提。
```

默认决策：

```text
常驻部分是后台调度进程，不是主 App 窗口
主 App 关闭后任务仍由后台调度进程按计划运行
任务失败由后台调度进程发送系统通知
菜单栏入口已实现；它只提供快捷操作，不承担后台调度存活职责
```

### 2.13 删除、停用与历史保留

现状：

```text
需求有任务删除，但没有规定删除是否同时删除历史。
```

默认决策：

```text
P0 删除任务 = 移入内置 trash 目录或系统废纸篓
不直接永久删除
运行中任务不能删除
停用任务不影响历史记录
```

原因：

```text
脚本和日志可能有排障价值
误删成本高
```

## 3. P0-A Roadmap：主 App 与立即运行

P0-A 的目标是主 App 可独立完成任务管理和手动运行。这个阶段结束时，即使没有后台调度进程，用户也能创建脚本、立即运行、看日志和历史。

### Milestone A1：项目骨架

范围：

```text
创建 Xcode SwiftUI macOS 项目
设置 Bundle ID: com.aix4u.runshelf
设置简体中文 String Catalog
建立 RunShelfApp / Core / Editor 目录结构
实现主窗口三栏布局
```

验收：

```text
项目能编译运行
主窗口有任务列表、详情区、Inspector 区
空状态文案为中文
```

不做：

```text
真实任务保存
真实脚本执行
后台调度进程
```

### Milestone A2：任务文件模型

范围：

```text
定义 TaskManifest schemaVersion = 1
定义 Schedule、Runner、Notifications、Retention 模型
实现 TaskStore 扫描、读取、创建、更新、删除
实现默认数据目录
实现原子写入
```

验收：

```text
新建任务会创建 task.json、run.sh、notes.md、runs/
修改任务名和启用状态会写回 task.json
重启 App 后任务仍能加载
损坏 task.json 不会导致 App 崩溃
```

关键测试：

```text
读取空目录
创建任务
重名任务
损坏 JSON
未来 schemaVersion
```

### Milestone A3：模板系统

范围：

```text
实现模板列表
实现模板生成 task.json + run.sh + notes.md
内置 7 个 P0 模板
任务目录为空时可创建 1-2 个默认停用的示例任务
```

验收：

```text
用户可从模板新建任务
模板生成的 run.sh 可编辑
模板不引入 Python/HTTP/Node 专用任务类型
示例任务默认停用，名称包含“示例”，可直接删除
```

### Milestone A4：Shell 编辑器

范围：

```text
用 NSTextView + NSViewRepresentable 实现编辑器
等宽字体
基础 Shell 高亮
Cmd+S 保存
查找
未保存状态
路径选择后插入 cd "..."
```

验收：

```text
打开任务显示 run.sh
编辑后有未保存状态
Cmd+S 写入文件
重开任务内容正确
常见注释、字符串、变量、命令有基础高亮
```

不做：

```text
自动补全
tree-sitter
终端模拟器
完整 bash parser
```

### Milestone A5：TaskRunner 与立即运行

范围：

```text
实现 TaskRunner
运行前创建 run directory
创建 run.sh.snapshot
执行 snapshot
捕获 stdout/stderr
写 meta.json
更新任务运行状态
UI 展示运行历史和日志
```

验收：

```text
echo hello 任务运行成功
exit 1 任务运行失败
stdout/stderr 文件写入正确
meta.json 记录 exitCode、startedAt、endedAt、durationMs
立即运行和历史展示一致
```

关键测试：

```text
成功脚本
失败脚本
大量 stdout
stderr 输出
运行中状态
脚本快照不受后续编辑影响
```

### Milestone A6：基础 Cron 与预览

范围：

```text
实现 5 段 cron parser
实现表达式验证
实现 next 5 runs 计算
实现简单模式到 cron 的转换
参考 crontab.guru 的即时解释、字段错误提示和常见示例
UI 展示下次运行预览
```

验收：

```text
合法 cron 能保存
非法 cron 显示中文错误
保存前显示下次 5 次运行时间
任务列表显示最近一次下次运行
```

关键测试：

```text
*/15 * * * *
0 8,12,18 * * *
0 9 * * 1-5
非法字段
越界数字
day-of-month 和 day-of-week 同时受限
```

## 4. P0-B Roadmap：后台调度与可靠性

P0-B 的目标是 App 关闭后任务仍能运行，并让错过运行、并发策略、失败通知和保留清理全部进入同一套状态模型。

### Milestone B1：Scheduler Core

范围：

```text
实现 Scheduler
每分钟扫描 enabled tasks
计算 due tasks
处理 missedRunPolicy
处理 concurrency = skip / allow
调用 TaskRunner
```

验收：

```text
每分钟任务能按时触发
长运行任务在 skip 策略下记录 skipped
错过运行在 30 分钟内补跑
超过窗口记录 stale
```

关键测试：

```text
due task
not due task
disabled task
skip concurrency
allow concurrency
skipIfLate
stale
```

### Milestone B2：后台调度进程

范围：

```text
创建 RunShelfScheduler helper target
复用 Core、Scheduler、TaskRunner
使用 SMAppService 注册后台调度进程
设置页显示后台调度进程状态
支持启动/停止后台调度进程
后台调度进程写心跳文件
```

验收：

```text
关闭主 App 后后台调度进程仍运行
定时任务产生 runs/
重新打开 App 后能看到后台调度进程写入的历史
设置页能显示后台调度进程是否已注册/运行
```

风险：

```text
SMAppService 签名和嵌入方式
本地开发调试路径
后台调度进程更新后的重载行为
```

### Milestone B3：通知与危险命令提示

范围：

```text
失败通知
通知授权状态展示
轻量危险命令检测
运行前风险提示
失败通知包含任务名、退出码或 timeout/cancelled 状态
```

验收：

```text
失败任务在授权后发送通知
用户拒绝通知不影响运行
通知能让用户回到 Run Shelf 查看失败日志
包含 rm -rf / sudo / chmod -R / chown -R / curl | sh 时提示风险
提示不阻止用户运行
```

### Milestone B4：保留策略与清理

范围：

```text
按 days 和 maxRuns 清理历史
清理 stdout/stderr/meta/snapshot
设置页可配置默认保留策略
```

验收：

```text
超过 maxRuns 的旧 runs 被清理
超过 days 的旧 runs 被清理
清理不影响正在运行的 run
```

### Milestone B5：P0 收尾

范围：

```text
中文文案统一
README
基本图标和 App metadata
打包脚本或手动发布说明
崩溃和错误状态排查文案
```

验收：

```text
干净 clone 后可以编译运行
README 能指导有权限的协作者构建
P0 验收标准全部通过
```

## 5. P1 Roadmap

P1 只在 P0 稳定后进入。不要把这些功能提前塞进 P0：

```text
crontab 导入
ShellCheck 集成
日志搜索
Keychain secret 管理
失败原因诊断
危险命令规则增强
任务导出/导入
脚本版本 diff
通知规则增强
XPC App-后台调度进程通信
```

推荐 P1 顺序：

```text
1. ShellCheck 集成
2. 日志搜索和过滤
3. Keychain secret 管理
4. crontab 导入
5. 任务导出/导入
6. 脚本版本 diff
```

原因：

```text
ShellCheck、日志搜索、secret 管理直接提升脚本可靠性和排障能力。
导入导出属于便利能力，不应早于核心可靠性。
```

## 6. 不进入 P0/P1 的边界

继续保持需求文档中的边界：

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

额外明确：

```text
不做自然语言计划解析
不做 Web 控制台
不做脚本云同步
不做内置终端
不做数据库作为 source of truth
```

## 7. 首轮实现建议

首轮实现只做 P0-A 的 A1 到 A5：

```text
A1 项目骨架
A2 任务文件模型
A3 模板系统
A4 Shell 编辑器
A5 TaskRunner 与立即运行
```

首轮不做：

```text
后台调度进程
真实定时调度
通知
保留清理
复杂设置页
发布打包
```

首轮完成标准：

```text
App 能编译运行
可以从模板新建任务
可以编辑 run.sh
可以立即运行
可以看到 stdout/stderr
可以看到运行历史
重启 App 后任务和历史仍存在
```

这能形成一个完整、可评审、可继续迭代的基础，而不是把调度、后台调度进程、编辑器和文件一致性同时压进第一版。

## 8. 开发验证闭环

实现阶段默认使用本机 Xcode 和系统 UI 做闭环验证，不只做静态代码检查。

每个可运行 milestone 至少执行：

```text
xcodebuild 编译
Xcode 或命令行启动 Run Shelf
用本机 UI 操作主流程
检查 Application Support 中的 task.json/run.sh/runs/
检查 stdout.log、stderr.log、meta.json
记录无法自动验证的系统权限或通知行为
```

首轮 P0-A 必须手动验证：

```text
从模板新建任务
编辑并保存 run.sh
立即运行成功脚本
立即运行失败脚本
查看 stdout/stderr
重启 App 后任务和历史仍可见
```

需要操作真实 App UI 时，使用 Codex 的 Computer Use 能力完成点击、输入、截图和状态核对。
