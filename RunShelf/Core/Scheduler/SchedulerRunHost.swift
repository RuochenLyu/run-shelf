import Darwin
import Foundation

enum SchedulerRunHostError: LocalizedError {
    case invalidArguments(String)
    case hostExitedWithoutRecord(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message):
            return "调度运行宿主参数无效：\(message)"
        case .hostExitedWithoutRecord(let detail):
            return "调度运行宿主未写入运行记录就退出（\(detail)）。"
        }
    }
}

/// 计划运行的独立宿主。
///
/// 调度进程不再在自己进程里监督脚本，而是为每次计划运行 `posix_spawn(SETSID)`
/// 一个 `RunShelfScheduler __run-host`：宿主持有 claim、执行脚本、处理超时/取消、
/// 写入终态 meta 并在失败时写通知 outbox。调度进程崩溃、被 launchd 重启或随
/// App 升级重新注册时，宿主在自己的 session 里继续运行，在途任务最终落真实终态，
/// 而不是被下一次加载判成 stale。重启后的调度进程看到宿主仍持有活跃 claim，
/// 按并发策略处理（默认跳过），不会重复启动。
enum SchedulerRunHost {
    static let command = "__run-host"
    static let hostName = "scheduler-host"
    static let launcherHostName = "scheduler-launcher"

    struct Arguments: Equatable {
        var taskID: String
        var runID: String
        var scheduledAt: Date?
    }

    private static func dateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    static func arguments(taskID: String, runID: String, scheduledAt: Date?) -> [String] {
        var arguments = [command, "--task-id", taskID, "--run-id", runID]
        if let scheduledAt {
            arguments += ["--scheduled-at", dateFormatter().string(from: scheduledAt)]
        }
        return arguments
    }

    /// `arguments` 不含可执行文件路径（即 `CommandLine.arguments.dropFirst()`）。
    static func parseArguments(_ arguments: [String]) throws -> Arguments {
        guard arguments.first == command else {
            throw SchedulerRunHostError.invalidArguments("缺少 \(command)")
        }
        var taskID: String?
        var runID: String?
        var scheduledAt: Date?
        var index = 1
        while index < arguments.count {
            let flag = arguments[index]
            guard index + 1 < arguments.count else {
                throw SchedulerRunHostError.invalidArguments("\(flag) 缺少值")
            }
            let value = arguments[index + 1]
            switch flag {
            case "--task-id":
                taskID = value
            case "--run-id":
                runID = value
            case "--scheduled-at":
                guard let date = dateFormatter().date(from: value) else {
                    throw SchedulerRunHostError.invalidArguments("--scheduled-at 不是 ISO8601：\(value)")
                }
                scheduledAt = date
            default:
                throw SchedulerRunHostError.invalidArguments("未知参数 \(flag)")
            }
            index += 2
        }
        guard let taskID, UUID(uuidString: taskID) != nil else {
            throw SchedulerRunHostError.invalidArguments("--task-id 无效")
        }
        guard let runID, TaskFileStore.isSafeRunID(runID) else {
            throw SchedulerRunHostError.invalidArguments("--run-id 无效")
        }
        return Arguments(taskID: taskID, runID: runID, scheduledAt: scheduledAt)
    }

    /// 调度进程侧：抢 claim → 启动宿主 → 等宿主退出 → 读回宿主写的终态。
    ///
    /// claim 先由调度进程抢占，所以并发策略、"已有活动运行"跳过逻辑与进程内运行一致；
    /// 宿主启动后 claim 的 processID 改为宿主 pid，调度进程退出不会让 claim 失效。
    /// 宿主退出后不在这里释放 claim：宿主正常结束时自己已释放；宿主异常死亡而脚本
    /// 进程组还活着时，claim 必须继续挡住重复运行，交给进程组存活判定处理。
    static func launchAndWait(
        task: RunShelfTask,
        scheduledAt: Date,
        runID: String,
        executableURL: URL,
        stderrLogURL: URL?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> RunRecord {
        let lease = try TaskRunClaimManager.acquire(task: task, runID: runID, host: launcherHostName)
        let pid: pid_t
        do {
            pid = try DetachedProcessSpawner.spawn(
                executableURL: executableURL,
                arguments: arguments(taskID: task.id, runID: runID, scheduledAt: scheduledAt),
                environment: environment,
                stderrAppendURL: stderrLogURL
            )
        } catch {
            lease.release()
            throw error
        }
        // 宿主可能已经自己写过 processID，甚至已经跑完并释放 claim；两种情况都无需再写。
        try? lease.update(processID: pid, host: hostName)

        let status = DetachedProcessSpawner.waitForExit(pid: pid)
        let record = try TaskFileStore(
            tasksDirectoryURL: task.directoryURL.deletingLastPathComponent()
        ).loadRun(for: task.directoryURL, runID: runID)
        if let record, record.status != .running {
            return record
        }
        if record == nil {
            // 宿主在写 meta 之前就失败（任务读不到、脚本为空等），脚本从未启动，
            // 可以安全释放 claim，避免它挂到 stale 判定才能回收。
            lease.release()
        }
        throw SchedulerRunHostError.hostExitedWithoutRecord(describe(waitStatus: status))
    }

    /// 宿主进程侧。返回进程退出码：0 成功，1 运行失败/超时/取消，2 宿主自身出错。
    static func runHost(
        arguments: Arguments,
        tasksDirectoryURL: URL = RunShelfPaths.tasksDirectoryURL(),
        outbox: RunShelfNotificationOutbox = RunShelfNotificationOutbox(),
        errorOutput: (String) -> Void = { message in
            FileHandle.standardError.write(Data(message.utf8))
        }
    ) -> Int32 {
        let prefix = "[\(RunShelfFormatters.dateTimeWithSeconds(Date()))] scheduler run host \(arguments.runID)"
        do {
            let read = try TaskRepository(tasksDirectoryURL: tasksDirectoryURL)
                .loadTask(selector: .id(arguments.taskID), includeRuns: false)
            let record = try TaskRunner.run(
                task: read.task,
                trigger: .scheduled,
                scheduledAt: arguments.scheduledAt,
                runId: arguments.runID,
                host: hostName,
                claimMode: .existing
            )
            if record.status == .failed || record.status == .timeout {
                do {
                    try RunShelfNotifier.enqueueFailure(task: read.task, run: record, outbox: outbox)
                } catch {
                    errorOutput("\(prefix): failure notification enqueue failed: \(error.localizedDescription)\n")
                }
            }
            return record.status == .success ? 0 : 1
        } catch {
            errorOutput("\(prefix) failed: \(error.localizedDescription)\n")
            return 2
        }
    }

    static func describe(waitStatus: Int32?) -> String {
        guard let waitStatus else { return "无法回收宿主进程" }
        let signal = waitStatus & 0x7f
        if signal == 0 {
            return "退出码 \((waitStatus >> 8) & 0xff)"
        }
        return "被信号 \(signal) 终止"
    }
}
