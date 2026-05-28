import Foundation

struct SchedulerState: Codable {
    var schemaVersion: Int
    var lastCheckAt: Date?
    var lastScheduledMinuteByTaskID: [String: String]

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
    private let queue = DispatchQueue(label: "com.aix4u.runshelf.scheduler")
    private let fileManager: FileManager
    private let taskFileStore: TaskFileStore
    private let stateURL: URL
    private let heartbeatURL: URL
    private let logURL: URL
    private var runningTaskIDs: Set<String> = []
    private var lastError: String?

    init(
        taskFileStore: TaskFileStore = TaskFileStore(),
        stateURL: URL = RunShelfPaths.schedulerStateURL(),
        heartbeatURL: URL = RunShelfPaths.schedulerHeartbeatURL(),
        logURL: URL = RunShelfPaths.schedulerLogURL(),
        fileManager: FileManager = .default
    ) {
        self.taskFileStore = taskFileStore
        self.stateURL = stateURL
        self.heartbeatURL = heartbeatURL
        self.logURL = logURL
        self.fileManager = fileManager
    }

    func tick(now: Date = Date()) {
        queue.async {
            self.performTick(now: now)
        }
    }

    private func performTick(now: Date) {
        do {
            try fileManager.createDirectory(at: RunShelfPaths.appSupportDirectoryURL(), withIntermediateDirectories: true)

            var state = loadState()
            let loadResult = try taskFileStore.loadTasksWithIssues()
            for issue in loadResult.issues {
                appendLog("task load skipped: \(issue.logMessage)")
            }

            for task in loadResult.tasks where task.manifest.enabled {
                process(task: task, now: now, state: &state)
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

    private func process(task: RunShelfTask, now: Date, state: inout SchedulerState) {
        guard task.manifest.schedule.type == "cron" else { return }

        let schedule: CronSchedule
        do {
            schedule = try CronSchedule.parse(task.manifest.schedule.expression)
        } catch {
            appendLog("invalid cron for \(task.manifest.name): \(error.localizedDescription)")
            return
        }

        let scanStart = state.lastCheckAt ?? now.addingTimeInterval(-60)
        guard let scheduledAt = schedule.matchingRuns(after: scanStart, through: now).last else { return }

        let scheduledMinuteKey = minuteKey(for: scheduledAt)
        guard state.lastScheduledMinuteByTaskID[task.id] != scheduledMinuteKey else { return }

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

        let allowsConcurrentRun = task.manifest.runner.concurrency == "allow"
        if runningTaskIDs.contains(task.id), !allowsConcurrentRun {
            writeSystemRecord(
                task: task,
                status: .skipped,
                message: "上一次运行仍未结束，本次计划运行已跳过。",
                scheduledAt: scheduledAt
            )
            state.lastScheduledMinuteByTaskID[task.id] = scheduledMinuteKey
            return
        }

        state.lastScheduledMinuteByTaskID[task.id] = scheduledMinuteKey
        runScheduled(task: task, scheduledAt: scheduledAt)
    }

    private func runScheduled(task: RunShelfTask, scheduledAt: Date) {
        runningTaskIDs.insert(task.id)

        DispatchQueue.global(qos: .utility).async {
            let result = Result {
                try TaskRunner.run(task: task, trigger: .scheduled, scheduledAt: scheduledAt)
            }

            self.queue.async {
                self.runningTaskIDs.remove(task.id)
                switch result {
                case .success(let run):
                    if run.status == .failed || run.status == .timeout {
                        RunShelfNotifier.notifyFailure(task: task, run: run)
                    }
                case .failure(let error):
                    self.appendLog("scheduled run failed before meta write for \(task.manifest.name): \(error.localizedDescription)")
                    let fallback = try? TaskRunner.writeSystemRecord(
                        task: task,
                        trigger: .scheduled,
                        status: .failed,
                        message: error.localizedDescription,
                        scheduledAt: scheduledAt
                    )
                    if let fallback {
                        RunShelfNotifier.notifyFailure(task: task, run: fallback)
                    }
                }
                self.writeHeartbeat(now: Date())
            }
        }
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
                RunShelfNotifier.notifyFailure(task: task, run: record)
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
            runningTaskIDs: runningTaskIDs.sorted(),
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
