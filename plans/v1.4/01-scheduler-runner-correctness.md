# 任务书 01：调度器与 Runner 正确性修复

范围：`RunShelf/Core/Scheduler/SchedulerEngine.swift`、`RunShelf/Core/Runner/TaskRunner.swift`、
`RunShelf/Core/Runner/RetentionCleaner.swift`、`RunShelf/Core/Storage/TaskFileStore.swift`、
`RunShelf/Core/Cron/CronSchedule.swift`。

除 F 项外均为已确认的逻辑缺陷。按 A→G 顺序实施，每项独立提交。

---

## A（P0）`runningTaskIDs` 泄漏导致任务被永久跳过

位置：`SchedulerEngine.swift:127`（无条件 insert）与 `:139-142`（完成回调）。

现状：完成回调只在 `TaskRunClaimManager.activeClaims(for: task).isEmpty` 时才
`runningTaskIDs.remove(task.id)`。`activeClaims` 统计的是磁盘上所有进程（App 手动
运行、CLI）的 claim，不只是 scheduler 自己的。

失败场景（concurrency = "skip" 默认值）：
1. scheduled run 结束（claim 已释放），完成回调尚未在 queue 上执行；
2. 此刻 App/CLI 对同一任务发起手动运行，新 claim 出现；
3. 回调看到 claim 非空 → 不移除 task.id；类内没有其他移除路径；
4. 之后 `process()`（:111）永远命中 `runningTaskIDs.contains` → 每个 cron 触发点
   写一条 skipped 记录，任务直到 scheduler 重启前永不再被调度执行。

`TaskRunner.run` 抛错走 failure 分支时若对方 claim 存活，同样泄漏。

修法：按 runID 记账。`runningRunIDs: Set<String>`（或 `[taskID: runID]`），dispatch 前
insert 本次 runID，完成回调**无条件**移除本次 runID；`process()` 的并发预检只依赖
claim（跨进程互斥的唯一事实源）+ 本进程在飞 runID。禁止用 `activeClaims.isEmpty`
作为"我的运行结束"的判据。

测试：模拟 scheduled run 完成时磁盘上存在另一个进程的 claim（手工创建 claim 目录
即可），断言下一个调度点该任务仍会被执行而不是写 skipped。

## B（P0）claim 竞争被误记为 failed 并发失败通知

位置：`SchedulerEngine.swift:111` 预检与 `:148-159` failure 分支。

场景：预检通过后、`TaskRunner.run` 内部 acquire 前，App 恰好启动手动运行 →
`TaskRunnerError.runAlreadyActive` 抛出 → 走 failure 分支 → 写 **failed** 系统记录并
`notifyFailure`。语义上这等价于 skipped（:112-120），不应打扰用户。

修法：failure 分支模式匹配 `TaskRunnerError.runAlreadyActive`（以及
`TaskRunClaimError` 中表示"已有活动运行"的 case），改写 skipped 记录、不发通知。

测试：预置一个活动 claim，直接调用 runScheduled 路径，断言产生 skipped 记录且无
failed 记录。

## C（P1）reconcile TOCTOU：成功记录可能被覆写成 stale

位置：`TaskFileStore.swift:176-197`（`reconcileRunningRecord`）。

场景：读者读到 meta `running` → 运行宿主写入最终 meta（success）并释放 claim →
读者检查 claim 已消失 → 用旧的 running 记录构造 stale 写回。成功运行的最终状态被
永久覆盖。

修法：写回前持有 `.run-claim/.claim-lock`（与 acquire 同一把 flock），锁内**重读
meta**，仍为 running 才覆写 stale。

测试：构造"meta 已终态但入参记录为 running"的调用，断言不覆写。

## D（P1）RetentionCleaner 删除 meta 损坏的 run 目录

位置：`RetentionCleaner.swift:28-35, 50-62`；配合 `TaskFileStore.swift:131-134`。

现状：meta.json 解码失败的目录不进 `records`，落入孤儿分支，mtime 超 5 分钟即删，
连同 stdout/stderr。前向兼容一旦破坏（新版 App 写了新字段、旧版 scheduler 还在
跑），旧进程会把整段 run 历史静默删光。

修法：孤儿删除只针对**不存在 meta.json 文件**的半成品目录；meta.json 存在但解码
失败的目录一律保留，并输出诊断日志。

测试：放置一个含损坏 meta.json 的 run 目录（mtime 旧于宽限期），跑清理，断言目录
仍在；再放一个无 meta.json 的旧目录，断言被删。

## E（P1）超时使用墙钟，睡眠唤醒后误杀

位置：`TaskRunner.swift:325, 364`（`deadline = Date().addingTimeInterval`）。

场景：timeout=600s 的脚本跑了 30s，机器睡眠 2 小时，唤醒瞬间被 SIGTERM/SIGKILL
记为 timeout。系统时钟前调同样误杀。

修法：改用单调时钟。macOS 上 `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` 睡眠不计
时，正合"实际运行时长"语义（`DispatchTime.now()` 同源，也可）。轮询循环里的
elapsed 计算一并替换。

测试：单调时钟无法在单测里模拟睡眠，做接缝注入（把"当前时刻"抽象成可注入的
closure），用注入时钟验证超时判定只依赖单调增量。

## F（P2）missed run 只处理最后一个，其余无声消失

位置：`SchedulerEngine.swift:91-107`。

现状：睡眠跨越 N 个调度点后 `latestMatchingRun` 只取最后一个（补跑或 stale），前
N-1 个没有任何记录，用户无法从 UI 得知漏跑。另外 `lastCheckAt > now`（时钟回拨）
时 `start < end` guard 使调度静默停摆。

修法：用 `matchingRuns(after:through:)` 枚举窗口内全部错过点，除最后一个外每个写
一条 stale 记录（封顶，比如最多 20 条，避免长期关机后刷屏——超出部分合并成一条
"另有 N 次未运行" 的 stale message）；`scanStart = min(lastCheckAt, now)` 防回拨停摆。

测试：lastCheckAt 落后 3 个调度点，断言产生 2 条 stale + 1 次补跑（窗口内）。

## G（P2）DST 春季跳变日任务静默不跑

位置：`CronSchedule.swift:170-188`（`date(on:hour:minute:)`）。

现状：不存在的时刻（如 02:30 被跳过的那天）`calendar.date(from:)` 返回平移后时间，
`actual.hour == hour` 校验失败返回 nil → 该天所有落在跳变时段的触发点被丢弃，无
任何记录。标准 cron 会在跳变后补跑。

修法：检测到平移（返回时间的 hour/minute 与请求不符且当天确有 DST 跳变）时，返回
跳变后的首个有效时刻，保证当天恰好触发一次。next-fire 预览与 `matchingRuns` 使用
同一路径，行为自动一致。

测试：固定一个含春季跳变的时区与日期（用 `TimeZone(identifier: "America/Los_Angeles")`
注入而非 `.current`；CronSchedule 计算入口需要允许注入时区，仅测试使用），断言
`30 2 * * *` 在跳变日返回 03:30（或跳变后首个有效时刻）而不是没有匹配。

---

## 低优先级（本轮顺手修，不单独展开）

- `TaskRunner.swift:307-312, 342-346`：抛错路径 SIGTERM 后未 `waitpid` 回收也未升级
  SIGKILL，长寿进程里留 zombie。补带超时的回收。
- `SchedulerEngine.swift:122, 194-199`：dispatch 后、`saveState` 前崩溃会导致重启后同
  一分钟重复触发。dispatch 前先持久化该分钟标记。
- `SchedulerEngine` tick 前调用 `NSTimeZone.resetSystemTimeZone()`，避免 launchd 长驻
  进程感知不到系统时区变更。
- state 修剪：`lastScheduledMinuteByTaskID` 按现存 task id 集合清理已删任务的键。

## 验收

- `scripts/check.sh` 全绿。
- A/B/C/D/F/G 各有对应回归测试；E 有注入时钟测试。
- 隔离数据目录手工验证：scheduled 任务在存在并发手动运行后仍能继续按计划执行（A）。
