import CryptoKit
import Darwin
import Foundation

enum TaskRunnerError: LocalizedError {
    case missingScript(URL)
    case processDidNotStart(String)
    case runAlreadyActive(TaskRunClaim)

    var errorDescription: String? {
        switch self {
        case .missingScript(let url):
            return "找不到脚本：\(url.path)"
        case .processDidNotStart(let message):
            return "脚本未能启动：\(message)"
        case .runAlreadyActive(let claim):
            return "任务正在运行：runId=\(claim.runId)，pid=\(claim.processID)"
        }
    }
}

final class TaskRunCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellationHandler: (() -> Void)?
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        let handler: (() -> Void)?
        lock.lock()
        cancelled = true
        handler = cancellationHandler
        lock.unlock()
        handler?()
    }

    func setCancellationHandler(_ handler: (() -> Void)?) {
        let shouldCall: Bool
        lock.lock()
        cancellationHandler = handler
        shouldCall = cancelled && handler != nil
        lock.unlock()
        if shouldCall {
            handler?()
        }
    }
}

enum TaskRunner {
    static func run(
        task: RunShelfTask,
        trigger: RunTrigger,
        scheduledAt: Date? = nil,
        runId requestedRunId: String? = nil,
        host: String = "runner",
        claimMode: TaskRunClaimMode = .acquire,
        cancellation: TaskRunCancellation? = nil,
        terminationGraceSeconds: TimeInterval = 5
    ) throws -> RunRecord {
        let fileManager = FileManager.default
        let startedAt = Date()
        let runId = requestedRunId ?? makeRunID(from: startedAt)
        let runsURL = task.directoryURL.appendingPathComponent("runs", isDirectory: true)
        let runURL = runsURL.appendingPathComponent(runId, isDirectory: true)
        let snapshotURL = runURL.appendingPathComponent("run.sh.snapshot")
        let stdoutURL = runURL.appendingPathComponent("stdout.log")
        let stderrURL = runURL.appendingPathComponent("stderr.log")
        let metaURL = runURL.appendingPathComponent("meta.json")
        let cancellationURL = runURL.appendingPathComponent("cancel-requested")

        let claimLease: TaskRunClaimLease
        do {
            switch claimMode {
            case .acquire:
                claimLease = try TaskRunClaimManager.acquire(
                    task: task,
                    runID: runId,
                    host: host,
                    now: startedAt,
                    fileManager: fileManager
                )
            case .existing:
                claimLease = try TaskRunClaimManager.existing(
                    task: task,
                    runID: runId,
                    fileManager: fileManager
                )
                try claimLease.update(processID: getpid(), host: host)
            }
        } catch TaskRunClaimError.alreadyRunning(let claim) {
            throw TaskRunnerError.runAlreadyActive(claim)
        }
        defer { claimLease.release() }

        try fileManager.createDirectory(at: runURL, withIntermediateDirectories: true)

        guard !task.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TaskRunnerError.missingScript(task.directoryURL.appendingPathComponent("run.sh"))
        }

        try task.script.write(to: snapshotURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: snapshotURL.path
        )

        fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        fileManager.createFile(atPath: stderrURL.path, contents: nil)

        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        let scriptSha256 = try sha256Hex(for: snapshotURL)
        var runningRecord = RunRecord(
            runId: runId,
            taskId: task.id,
            trigger: trigger,
            status: .running,
            exitCode: nil,
            scheduledAt: scheduledAt,
            startedAt: startedAt,
            endedAt: nil,
            durationMs: nil,
            scriptSha256: scriptSha256,
            stdoutPath: "stdout.log",
            stderrPath: "stderr.log",
            message: nil,
            processID: getpid(),
            processGroupID: nil
        )
        try write(record: runningRecord, to: metaURL)

        let execution: ExecutionResult
        do {
            execution = try runSnapshot(
                snapshotURL: snapshotURL,
                workingDirectoryURL: task.directoryURL,
                stdoutHandle: stdoutHandle,
                stderrHandle: stderrHandle,
                timeoutSeconds: task.manifest.runner.timeoutSeconds,
                cancellation: cancellation,
                externalCancellationURL: cancellationURL,
                terminationGraceSeconds: terminationGraceSeconds,
                onProcessStarted: { processGroupID in
                    try claimLease.update(processGroupID: processGroupID)
                    runningRecord.processGroupID = processGroupID
                    try write(record: runningRecord, to: metaURL)
                }
            )
        } catch {
            let endedAt = Date()
            let record = RunRecord(
                runId: runId,
                taskId: task.id,
                trigger: trigger,
                status: .failed,
                exitCode: nil,
                scheduledAt: scheduledAt,
                startedAt: startedAt,
                endedAt: endedAt,
                durationMs: Int(endedAt.timeIntervalSince(startedAt) * 1000),
                scriptSha256: scriptSha256,
                stdoutPath: "stdout.log",
                stderrPath: "stderr.log",
                message: error.localizedDescription,
                processID: getpid(),
                processGroupID: runningRecord.processGroupID
            )
            try write(record: record, to: metaURL)
            RetentionCleaner.clean(taskDirectoryURL: task.directoryURL, policy: task.manifest.retention, preserving: record.runId)
            return record
        }

        let endedAt = Date()
        let status: TaskRunStatus
        if execution.didTimeout {
            status = .timeout
        } else if execution.wasCancelled {
            status = .cancelled
        } else {
            status = execution.exitCode == 0 ? .success : .failed
        }
        let durationMs = Int(endedAt.timeIntervalSince(startedAt) * 1000)

        let record = RunRecord(
            runId: runId,
            taskId: task.id,
            trigger: trigger,
            status: status,
            exitCode: execution.exitCode,
            scheduledAt: scheduledAt,
            startedAt: startedAt,
            endedAt: endedAt,
            durationMs: durationMs,
            scriptSha256: scriptSha256,
            stdoutPath: "stdout.log",
            stderrPath: "stderr.log",
            message: execution.message,
            processID: getpid(),
            processGroupID: runningRecord.processGroupID
        )

        try write(record: record, to: metaURL)
        RetentionCleaner.clean(taskDirectoryURL: task.directoryURL, policy: task.manifest.retention, preserving: record.runId)

        return record
    }

    static func writeSystemRecord(
        task: RunShelfTask,
        trigger: RunTrigger,
        status: TaskRunStatus,
        message: String,
        scheduledAt: Date? = nil
    ) throws -> RunRecord {
        let fileManager = FileManager.default
        let startedAt = Date()
        let runId = makeRunID(from: startedAt)
        let runURL = task.directoryURL
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(runId, isDirectory: true)
        let stdoutURL = runURL.appendingPathComponent("stdout.log")
        let stderrURL = runURL.appendingPathComponent("stderr.log")
        let metaURL = runURL.appendingPathComponent("meta.json")

        try fileManager.createDirectory(at: runURL, withIntermediateDirectories: true)
        try "".write(to: stdoutURL, atomically: true, encoding: .utf8)
        try (message + "\n").write(to: stderrURL, atomically: true, encoding: .utf8)

        let endedAt = Date()
        let record = RunRecord(
            runId: runId,
            taskId: task.id,
            trigger: trigger,
            status: status,
            exitCode: nil,
            scheduledAt: scheduledAt,
            startedAt: startedAt,
            endedAt: endedAt,
            durationMs: Int(endedAt.timeIntervalSince(startedAt) * 1000),
            scriptSha256: "",
            stdoutPath: "stdout.log",
            stderrPath: "stderr.log",
            message: message
        )

        try write(record: record, to: metaURL)
        RetentionCleaner.clean(taskDirectoryURL: task.directoryURL, policy: task.manifest.retention, preserving: record.runId)
        return record
    }

    static func makeRunID(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ssZZZZZ"
        let timestamp = formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
        return "\(timestamp)-\(UUID().uuidString.prefix(8))"
    }

    private static func sha256Hex(for url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func write(record: RunRecord, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: url, options: [.atomic])
    }
}

private extension TaskRunner {
    struct ExecutionResult {
        var exitCode: Int
        var didTimeout: Bool
        var wasCancelled: Bool
        var message: String?
    }

    static func runSnapshot(
        snapshotURL: URL,
        workingDirectoryURL: URL,
        stdoutHandle: FileHandle,
        stderrHandle: FileHandle,
        timeoutSeconds: Int,
        cancellation: TaskRunCancellation?,
        externalCancellationURL: URL?,
        terminationGraceSeconds: TimeInterval,
        onProcessStarted: ((pid_t) throws -> Void)? = nil
    ) throws -> ExecutionResult {
        let pid = try spawnProcessGroup(
            executableURL: snapshotURL,
            workingDirectoryURL: workingDirectoryURL,
            stdoutHandle: stdoutHandle,
            stderrHandle: stderrHandle
        )
        do {
            try onProcessStarted?(pid)
        } catch {
            terminateProcessGroup(pid: pid, signal: SIGTERM)
            throw error
        }
        cancellation?.setCancellationHandler {
            terminateProcessGroup(pid: pid, signal: SIGTERM)
        }
        defer {
            cancellation?.setCancellationHandler(nil)
        }

        var status: Int32 = 0
        var didTimeout = false
        var wasCancelled = false
        var sentKill = false
        var terminationRequestedAt: Date?
        let deadline = timeoutSeconds > 0 ? Date().addingTimeInterval(TimeInterval(timeoutSeconds)) : nil
        let graceSeconds = max(terminationGraceSeconds, 0)

        while true {
            let waitResult = waitpid(pid, &status, WNOHANG)
            if waitResult == pid {
                if !wasCancelled, cancellation?.isCancelled == true {
                    wasCancelled = true
                }
                if !wasCancelled, let externalCancellationURL, FileManager.default.fileExists(atPath: externalCancellationURL.path) {
                    wasCancelled = true
                }
                if (didTimeout || wasCancelled), !sentKill {
                    terminateProcessGroup(pid: pid, signal: SIGKILL)
                }
                break
            }
            if waitResult == -1 {
                if errno == EINTR {
                    continue
                }
                throw TaskRunnerError.processDidNotStart(String(cString: strerror(errno)))
            }

            let now = Date()
            if !wasCancelled, cancellation?.isCancelled == true {
                wasCancelled = true
                terminationRequestedAt = now
                writeLine("Run Shelf：用户取消了运行，正在终止进程组。", to: stderrHandle)
                terminateProcessGroup(pid: pid, signal: SIGTERM)
            }

            if !wasCancelled, let externalCancellationURL, FileManager.default.fileExists(atPath: externalCancellationURL.path) {
                wasCancelled = true
                terminationRequestedAt = now
                writeLine("Run Shelf：CLI 请求取消运行，正在终止进程组。", to: stderrHandle)
                terminateProcessGroup(pid: pid, signal: SIGTERM)
            }

            if !didTimeout, let deadline, now >= deadline {
                didTimeout = true
                terminationRequestedAt = now
                writeLine("Run Shelf：超过 \(timeoutSeconds) 秒未结束，正在终止进程组。", to: stderrHandle)
                terminateProcessGroup(pid: pid, signal: SIGTERM)
            }

            if let terminationRequestedAt, !sentKill, now.timeIntervalSince(terminationRequestedAt) >= graceSeconds {
                sentKill = true
                writeLine("Run Shelf：进程组收到终止信号后仍未退出，已强制结束。", to: stderrHandle)
                terminateProcessGroup(pid: pid, signal: SIGKILL)
            }

            Thread.sleep(forTimeInterval: 0.05)
        }

        let exitCode = exitCode(fromWaitStatus: status)
        let message: String?
        if didTimeout {
            message = "超过 \(timeoutSeconds) 秒未结束"
        } else if wasCancelled {
            message = "用户取消了运行"
        } else {
            message = nil
        }

        return ExecutionResult(
            exitCode: exitCode,
            didTimeout: didTimeout,
            wasCancelled: wasCancelled,
            message: message
        )
    }

    static func spawnProcessGroup(
        executableURL: URL,
        workingDirectoryURL: URL,
        stdoutHandle: FileHandle,
        stderrHandle: FileHandle
    ) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        var fileActions: posix_spawn_file_actions_t?
        var pid = pid_t()

        guard posix_spawnattr_init(&attributes) == 0 else {
            throw TaskRunnerError.processDidNotStart("无法初始化进程属性")
        }
        defer { posix_spawnattr_destroy(&attributes) }

        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw TaskRunnerError.processDidNotStart("无法初始化进程文件动作")
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        let flags = Int16(POSIX_SPAWN_SETSID)
        guard posix_spawnattr_setflags(&attributes, flags) == 0 else {
            throw TaskRunnerError.processDidNotStart("无法设置进程组")
        }

        let chdirResult = workingDirectoryURL.path.withCString {
            posix_spawn_file_actions_addchdir_np(&fileActions, $0)
        }
        guard chdirResult == 0 else {
            throw TaskRunnerError.processDidNotStart(String(cString: strerror(chdirResult)))
        }

        guard posix_spawn_file_actions_adddup2(&fileActions, stdoutHandle.fileDescriptor, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&fileActions, stderrHandle.fileDescriptor, STDERR_FILENO) == 0
        else {
            throw TaskRunnerError.processDidNotStart("无法连接 stdout/stderr")
        }

        let executablePath = strdup(executableURL.path)
        guard let executablePath else {
            throw TaskRunnerError.processDidNotStart("无法编码脚本路径")
        }
        defer { free(executablePath) }

        var argv: [UnsafeMutablePointer<CChar>?] = [executablePath, nil]
        var environment = makeEnvironment()
        defer {
            for entry in environment where entry != nil {
                free(entry)
            }
        }

        let spawnResult = argv.withUnsafeMutableBufferPointer { argvBuffer in
            environment.withUnsafeMutableBufferPointer { environmentBuffer in
                posix_spawn(
                    &pid,
                    executablePath,
                    &fileActions,
                    &attributes,
                    argvBuffer.baseAddress,
                    environmentBuffer.baseAddress
                )
            }
        }
        guard spawnResult == 0 else {
            throw TaskRunnerError.processDidNotStart(String(cString: strerror(spawnResult)))
        }

        return pid
    }

    static func terminateProcessGroup(pid: pid_t, signal: Int32) {
        _ = kill(-pid, signal)
    }

    static func writeLine(_ line: String, to handle: FileHandle) {
        if let data = ("\n" + line + "\n").data(using: .utf8) {
            handle.write(data)
        }
    }

    static func exitCode(fromWaitStatus status: Int32) -> Int {
        let value = Int(status)
        let terminationSignal = value & 0x7f
        if terminationSignal == 0 {
            return (value >> 8) & 0xff
        }
        return 128 + terminationSignal
    }

    static func makeEnvironment() -> [UnsafeMutablePointer<CChar>?] {
        var entries = ProcessInfo.processInfo.environment.map { key, value in
            strdup("\(key)=\(value)")
        }
        entries.append(nil)
        return entries
    }
}
