import Foundation

struct SchedulerState: Codable {
    var schemaVersion: Int
    var lastCheckAt: Date?
    var lastScheduledMinuteByTaskID: [String: String]
    /// concurrency=queue 的任务在忙时被触发，记下最近一次计划时间；空闲后补跑一次。
    /// 可选字段：旧版本写出的状态文件没有它，旧版本读到它也会忽略。
    var pendingRunByTaskID: [String: Date]? = nil

    static let empty = SchedulerState(
        schemaVersion: 1,
        lastCheckAt: nil,
        lastScheduledMinuteByTaskID: [:]
    )
}

struct SchedulerHeartbeat: Codable {
    var schemaVersion: Int
    var pid: Int32
    var checkedAt: Date
    var runningTaskIDs: [String]
    var lastError: String?
}

final class SchedulerEngine {
    typealias ScheduledRun = (
        _ task: RunShelfTask,
        _ scheduledAt: Date,
        _ runID: String
    ) throws -> RunRecord
    typealias FailureNotifier = (_ task: RunShelfTask, _ run: RunRecord) -> Void

    private let queue = DispatchQueue(label: "com.aix4u.runshelf.scheduler")
    private let fileManager: FileManager
    private let taskFileStore: TaskFileStore
    private let appSupportDirectoryURL: URL
    private let stateURL: URL
    private let heartbeatURL: URL
    private let logURL: URL
    private let scheduledRun: ScheduledRun
    private let failureNotifier: FailureNotifier
    private let scheduledRunReportsFailures: Bool
    private let resetSystemTimeZone: () -> Void
    private var runningRunIDsByTaskID: [String: Set<String>] = [:]
    private var lastError: String?

    init(
        taskFileStore: TaskFileStore = TaskFileStore(),
        appSupportDirectoryURL: URL = RunShelfPaths.appSupportDirectoryURL(),
        stateURL: URL = RunShelfPaths.schedulerStateURL(),
        heartbeatURL: URL = RunShelfPaths.schedulerHeartbeatURL(),
        logURL: URL = RunShelfPaths.schedulerLogURL(),
        fileManager: FileManager = .default,
        scheduledRun: @escaping ScheduledRun = { task, scheduledAt, runID in
            try TaskRunner.run(
                task: task,
                trigger: .scheduled,
                scheduledAt: scheduledAt,
                runId: runID,
                host: "scheduler"
            )
        },
        failureNotifier: FailureNotifier? = nil,
        scheduledRunReportsFailures: Bool = false,
        resetSystemTimeZone: @escaping () -> Void = { NSTimeZone.resetSystemTimeZone() }
    ) {
        self.taskFileStore = taskFileStore
        self.appSupportDirectoryURL = appSupportDirectoryURL
        self.stateURL = stateURL
        self.heartbeatURL = heartbeatURL
        self.logURL = logURL
        self.fileManager = fileManager
        self.scheduledRun = scheduledRun
        // 调度进程是裸可执行文件，不能碰 UserNotifications（会断言 abort）。
        // 默认把失败通知写进 outbox，由 App 进程转投。
        self.failureNotifier = failureNotifier ?? Self.outboxFailureNotifier(
            outbox: RunShelfNotificationOutbox(
                directoryURL: RunShelfPaths.notificationOutboxURL(appSupportDirectoryURL: appSupportDirectoryURL),
                fileManager: fileManager
            ),
            logURL: logURL
        )
        // 独立宿主（SchedulerRunHost）自己写失败通知：调度进程中途重启时宿主仍能通知。
        // 此时引擎不再为宿主返回的记录重复通知，只负责宿主没写出记录时的兜底记录。
        self.scheduledRunReportsFailures = scheduledRunReportsFailures
        self.resetSystemTimeZone = resetSystemTimeZone
    }

    func tick(now: Date = Date()) {
        queue.async {
            self.performTick(now: now)
        }
    }

    private func performTick(now: Date) {
        do {
            resetSystemTimeZone()
            try fileManager.createDirectory(at: appSupportDirectoryURL, withIntermediateDirectories: true)

            var state = loadState()
            let loadResult = try taskFileStore.loadTasksWithIssues(includeRuns: false)
            for issue in loadResult.issues {
                appendLog("task load skipped: \(issue.logMessage)")
            }
            let existingTaskIDs = Set(loadResult.tasks.map(\.id))
            state.lastScheduledMinuteByTaskID = state.lastScheduledMinuteByTaskID.filter {
                existingTaskIDs.contains($0.key)
            }
            // 已删除、已停用或改成别的并发策略的任务，不再保留待补跑。
            let queueableTaskIDs = Set(loadResult.tasks.filter {
                $0.manifest.enabled && $0.manifest.runner.concurrency == TaskConcurrency.queue
            }.map(\.id))
            if let pending = state.pendingRunByTaskID {
                let kept = pending.filter { queueableTaskIDs.contains($0.key) }
                state.pendingRunByTaskID = kept.isEmpty ? nil : kept
            }

            for task in loadResult.tasks where task.manifest.enabled {
                try process(task: task, now: now, state: &state)
            }
            state.lastCheckAt = now
            try saveState(state)
            lastError = loadResult.issues.first?.logMessage
        } catch {
            lastError = error.localizedDescription
            appendLog("tick failed: \(error.localizedDescription)")
        }

        writeHeartbeat(now: now)
    }

    private func process(task: RunShelfTask, now: Date, state: inout SchedulerState) throws {
        guard task.manifest.schedule.type == "cron" else { return }
        try processScheduledTrigger(task: task, now: now, state: &state)
        try runPendingIfIdle(task: task, state: &state)
    }

    private func processScheduledTrigger(task: RunShelfTask, now: Date, state: inout SchedulerState) throws {

        let schedule: CronSchedule
        do {
            schedule = try CronSchedule.parse(task.manifest.schedule.expression)
        } catch {
            appendLog("invalid cron for \(task.manifest.name): \(error.localizedDescription)")
            return
        }

        let previousCheck = state.lastCheckAt ?? now.addingTimeInterval(-60)
        let scanStart = previousCheck > now ? now.addingTimeInterval(-60) : previousCheck
        let detailedStaleLimit = 19
        let summary = schedule.matchingRunSummary(
            after: scanStart,
            through: now,
            prefixLimit: detailedStaleLimit
        )
        guard let scheduledAt = summary.latest else { return }

        let scheduledMinuteKey = minuteKey(for: scheduledAt)
        guard state.lastScheduledMinuteByTaskID[task.id] != scheduledMinuteKey else { return }

        let precedingRunCount = max(summary.count - 1, 0)
        let detailedRuns = summary.prefix.filter { $0 != scheduledAt }.prefix(detailedStaleLimit)
        for missedAt in detailedRuns {
            writeSystemRecord(
                task: task,
                status: .stale,
                message: "计划运行时间 \(RunShelfFormatters.dateTimeWithSeconds(missedAt)) 未运行。",
                scheduledAt: missedAt
            )
        }
        let omittedRunCount = precedingRunCount - detailedRuns.count
        if omittedRunCount > 0 {
            writeSystemRecord(
                task: task,
                status: .stale,
                message: "另有 \(omittedRunCount) 次计划运行未运行。",
                scheduledAt: scheduledAt
            )
        }

        let maxDelay = TimeInterval(max(task.manifest.runner.missedRunPolicy.maxDelaySeconds, 0))
        if now.timeIntervalSince(scheduledAt) > maxDelay {
            writeSystemRecord(
                task: task,
                status: .stale,
                message: "计划运行时间 \(RunShelfFormatters.dateTimeWithSeconds(scheduledAt)) 已错过太久，未补跑。",
                scheduledAt: scheduledAt
            )
            state.lastScheduledMinuteByTaskID[task.id] = scheduledMinuteKey
            return
        }

        let concurrency = task.manifest.runner.concurrency
        if concurrency != TaskConcurrency.allow, isBusy(task) {
            state.lastScheduledMinuteByTaskID[task.id] = scheduledMinuteKey
            if concurrency == TaskConcurrency.queue {
                // 多次忙时触发合并成一次补跑，记最近的计划时间。
                var pending = state.pendingRunByTaskID ?? [:]
                pending[task.id] = scheduledAt
                state.pendingRunByTaskID = pending
                appendLog("queued \(task.manifest.name) at \(RunShelfFormatters.dateTimeWithSeconds(scheduledAt)): previous run still active")
                return
            }
            writeSystemRecord(
                task: task,
                status: .skipped,
                message: "上一次运行仍未结束，本次计划运行已跳过。",
                scheduledAt: scheduledAt
            )
            return
        }

        state.lastScheduledMinuteByTaskID[task.id] = scheduledMinuteKey
        // 空闲时的新触发已经覆盖了待补跑，不再额外多跑一次。
        removePendingRun(for: task.id, from: &state)
        try saveState(state)
        runScheduled(task: task, scheduledAt: scheduledAt)
    }

    /// 待补跑不受 missedRunPolicy 的迟到上限约束：它等的是上一次运行结束，而不是调度器停摆。
    private func runPendingIfIdle(task: RunShelfTask, state: inout SchedulerState) throws {
        guard let pendingAt = state.pendingRunByTaskID?[task.id] else { return }
        guard !isBusy(task) else { return }

        removePendingRun(for: task.id, from: &state)
        appendLog("running queued \(task.manifest.name) scheduled at \(RunShelfFormatters.dateTimeWithSeconds(pendingAt))")
        try saveState(state)
        runScheduled(task: task, scheduledAt: pendingAt)
    }

    private func removePendingRun(for taskID: String, from state: inout SchedulerState) {
        guard state.pendingRunByTaskID?[taskID] != nil else { return }
        state.pendingRunByTaskID?.removeValue(forKey: taskID)
        if state.pendingRunByTaskID?.isEmpty == true {
            state.pendingRunByTaskID = nil
        }
    }

    private func isBusy(_ task: RunShelfTask) -> Bool {
        runningRunIDsByTaskID[task.id]?.isEmpty == false || TaskRunClaimManager.activeClaim(for: task) != nil
    }

    func runScheduled(task: RunShelfTask, scheduledAt: Date) {
        let runID = TaskRunner.makeRunID(from: Date())
        runningRunIDsByTaskID[task.id, default: []].insert(runID)

        DispatchQueue.global(qos: .utility).async {
            let result = Result {
                try self.scheduledRun(task, scheduledAt, runID)
            }

            self.queue.async {
                self.runningRunIDsByTaskID[task.id]?.remove(runID)
                if self.runningRunIDsByTaskID[task.id]?.isEmpty == true {
                    self.runningRunIDsByTaskID.removeValue(forKey: task.id)
                }
                switch result {
                case .success(let run):
                    if !self.scheduledRunReportsFailures, run.status == .failed || run.status == .timeout {
                        self.failureNotifier(task, run)
                    }
                    // 有排队的补跑就不等下一个 30 秒 tick。
                    if self.loadState().pendingRunByTaskID?[task.id] != nil {
                        self.performTick(now: Date())
                        return
                    }
                case .failure(let error):
                    if Self.isActiveRunError(error) {
                        self.writeSystemRecord(
                            task: task,
                            status: .skipped,
                            message: "任务已有活动运行，本次计划运行已跳过。",
                            scheduledAt: scheduledAt
                        )
                        self.writeHeartbeat(now: Date())
                        return
                    }
                    self.appendLog("scheduled run failed before meta write for \(task.manifest.name): \(error.localizedDescription)")
                    let fallback = try? TaskRunner.writeSystemRecord(
                        task: task,
                        trigger: .scheduled,
                        status: .failed,
                        message: error.localizedDescription,
                        scheduledAt: scheduledAt
                    )
                    if let fallback {
                        self.failureNotifier(task, fallback)
                    }
                }
                self.writeHeartbeat(now: Date())
            }
        }
    }

    static func outboxFailureNotifier(outbox: RunShelfNotificationOutbox, logURL: URL) -> FailureNotifier {
        { task, run in
            do {
                try RunShelfNotifier.enqueueFailure(task: task, run: run, outbox: outbox)
            } catch {
                let line = "[\(RunShelfFormatters.dateTimeWithSeconds(Date()))] failure notification enqueue failed for \(task.manifest.name): \(error.localizedDescription)\n"
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: Data(line.utf8))
                }
            }
        }
    }

    private static func isActiveRunError(_ error: Error) -> Bool {
        if case TaskRunnerError.runAlreadyActive = error {
            return true
        }
        if case TaskRunClaimError.alreadyRunning = error {
            return true
        }
        return false
    }

    private func writeSystemRecord(task: RunShelfTask, status: TaskRunStatus, message: String, scheduledAt: Date) {
        do {
            let record = try TaskRunner.writeSystemRecord(
                task: task,
                trigger: .scheduled,
                status: status,
                message: message,
                scheduledAt: scheduledAt
            )
            if status == .failed || status == .timeout {
                failureNotifier(task, record)
            }
        } catch {
            appendLog("failed to write \(status.rawValue) record for \(task.manifest.name): \(error.localizedDescription)")
        }
    }

    private func loadState() -> SchedulerState {
        guard let data = try? Data(contentsOf: stateURL) else { return .empty }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(SchedulerState.self, from: data), state.schemaVersion == 1 else {
            return .empty
        }
        return state
    }

    private func saveState(_ state: SchedulerState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: stateURL, options: [.atomic])
    }

    private func writeHeartbeat(now: Date) {
        let heartbeat = SchedulerHeartbeat(
            schemaVersion: 1,
            pid: getpid(),
            checkedAt: now,
            runningTaskIDs: runningRunIDsByTaskID.keys.sorted(),
            lastError: lastError
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(heartbeat).write(to: heartbeatURL, options: [.atomic])
        } catch {
            appendLog("heartbeat write failed: \(error.localizedDescription)")
        }
    }

    private func minuteKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter.string(from: date)
    }

    private func appendLog(_ message: String) {
        let line = "[\(RunShelfFormatters.dateTimeWithSeconds(Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if let attributes = try? fileManager.attributesOfItem(atPath: logURL.path),
           let size = (attributes[.size] as? NSNumber)?.intValue,
           size >= 5 * 1_024 * 1_024 {
            let rotatedURL = logURL.appendingPathExtension("1")
            try? fileManager.removeItem(at: rotatedURL)
            try? fileManager.moveItem(at: logURL, to: rotatedURL)
        }

        if fileManager.fileExists(atPath: logURL.path), let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? fileManager.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: logURL)
        }
    }
}
