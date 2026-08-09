# 任务书 02：日志视图与线程池修复

范围：`RunShelf/Core/Stores/TaskRunCoordinator.swift`、`RunShelf/App/Views/LogView.swift`、
`RunShelf/App/Views/LogTextView.swift`、`RunShelf/Core/Storage/LogContentLoader.swift`。

这些是 1.2.0–1.3.0 性能重构引入的回归。按 A→D 顺序实施，每项独立提交。

---

## A（P0）TaskRunCoordinator 在 Swift 并发协作线程池上同步阻塞跑脚本

位置：`TaskRunCoordinator.swift:27-36`。

现状：`Task.detached { TaskRunner.run(...) }`。`TaskRunner.run` 是同步阻塞的
`waitpid` + `Thread.sleep(0.2)` 轮询，会占住协作池一条线程直到脚本结束（可能数小
时）。协作池宽度 = CPU 核数且不增长。

失败场景：同时手动运行 ≥ 核数个长任务 → 协作池饿死 → `LogContentLoader.readTail`
（同为 `Task.detached`）和 `TaskDiskMonitor` 后台扫描全部挂起 → 日志、磁盘刷新、
UI 数据全冻结，直到某个脚本退出。

修法：与 `SchedulerEngine` 保持一致，用 `DispatchQueue.global(qos: .utility)`（或每
run 一条专用线程）执行 `TaskRunner.run`，完成后跳回 MainActor 发布结果。协作池只
允许放非阻塞工作。

测试：难以直接断言线程池，退而验证行为——起 N（> 核数，用 sleep 脚本）个并发手
动运行后，`LogContentLoader.readTail` 在限时内仍能返回。若不稳定则至少加代码注释
+ 在 PR 描述里附手工验证记录。

## B（P0）切换任务/run 时短暂显示上一个 run 的日志

位置：`LogView.swift:92`、`LogContentLoader.swift:61-63`、`TaskDetailView.swift:118`。

现状：1.3.0 为消除加载闪烁，切 key 时保留旧 stdout/stderr 不清空；占位视图只在旧
内容为空时显示；`@StateObject loader` 跨任务复用。结果：从任务 A 切到任务 B，B 的
标题和状态徽章下渲染的是 A 的日志，直到 tail 读取完成（大文件几十 ms，肉眼可见）。
这是内容归属错误，比闪烁严重。

修法：`isWaitingForContent == true` 时不渲染旧内容——立即清空并显示既有的延迟加
载指示器（150ms 内完成则无闪烁）；或保留旧内容但叠加不透明的"加载中"遮罩。推荐
前者，实现简单且语义正确。

测试：UI 层为主，核心可测部分：`LogContentLoader` 切 key 后、加载完成前，对外发布
的内容必须为空（或标记为不可展示）。补一条对应单测。

## C（P1）LogTextView 滚动位置恢复竞态 + 全量 layout 卡顿

位置：`LogTextView.swift:60-64, 79-96`。

三个问题：
1. 竞态：切到 run A 后 restore 经 `DispatchQueue.main.async` 延迟执行；期间若
   `updateNSView` 再次触发（`loader.isLoading` 翻转即会），:62 会把
   `scrollOrigins[A]` 覆写成尚未恢复的旧 run 偏移，下次回到 A 恢复错位。
   修法：加 `pendingRestoreKey`，restore 完成前不回写该 key 的 origin。
2. 卡顿：restore 里 `layoutManager?.ensureLayout(for: textContainer)` 对整个文档同步
   全量布局，1MB 日志在主线程一次卡顿，抵消 `allowsNonContiguousLayout = true`。
   修法：只 ensure 目标可视区域（`ensureLayout(forBoundingRect:)`）或直接把目标
   origin clamp 到 `documentView.frame` 范围内，不做全量 layout。
3. `scrollOrigins` 无上限增长。修法：LRU 截断（如保留最近 50 个 key）。

## D（P2）LogContentLoader 死代码与缓存契约

位置：`LogContentLoader.swift:45-46`。

1. :45 的条件被 :46 完全包含，删除死代码。
2. 缓存 key 为 `(taskID, runID, status)` 不含文件签名；目前依赖"终态日志不可变 +
   running 恒 force:true"的调用方纪律。修法：running 状态的结果不写入缓存（终态才
   缓存），并在类型注释里写明缓存契约。

## 测试补强（1.3.0 遗留）

`RunShelfTests/RunShelfCoreTests.swift` 的 `testStableDiskRefreshDoesNotPublishStoreChanges`
传入的是空 `DiskScanResult`，没有覆盖 `applyDiskScan` 中 fullReload/runsOnly 的
"相同内容不发布"分支（1.3.0 的主要改动）。用含 1 个任务 + 1 条 run 的扫描结果重复
应用两次，断言第二次不产生 objectWillChange。

## 验收

- `scripts/check.sh` 全绿。
- 手工验证（隔离数据目录）：两个任务各有 >1MB 日志，来回切换无上一任务内容残影、
  无主线程卡顿；滚动到中部 → 切走 → 切回，位置恢复正确（重复 5 次）。
- 并发 8 个 sleep 任务手动运行时，切换任务与查看日志仍流畅（A 的验证）。
