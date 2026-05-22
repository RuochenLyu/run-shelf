import CryptoKit
import Darwin
import Foundation

enum TaskRunnerError: LocalizedError {
    case missingScript(URL)
    case processDidNotStart(String)

    var errorDescription: String? {
        switch self {
        case .missingScript(let url):
            return "找不到脚本：\(url.path)"
        case .processDidNotStart(let message):
            return "脚本未能启动：\(message)"
        }
    }
}

enum TaskRunner {
    static func run(task: RunShelfTask, trigger: RunTrigger, scheduledAt: Date? = nil) throws -> RunRecord {
        let fileManager = FileManager.default
        let startedAt = Date()
        let runId = makeRunID(from: startedAt)
        let runsURL = task.directoryURL.appendingPathComponent("runs", isDirectory: true)
        let runURL = runsURL.appendingPathComponent(runId, isDirectory: true)
        let snapshotURL = runURL.appendingPathComponent("run.sh.snapshot")
        let stdoutURL = runURL.appendingPathComponent("stdout.log")
        let stderrURL = runURL.appendingPathComponent("stderr.log")
        let metaURL = runURL.appendingPathComponent("meta.json")

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

        let process = Process()
        process.executableURL = snapshotURL
        process.currentDirectoryURL = task.directoryURL
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
        }

        do {
            try process.run()
        } catch {
            throw TaskRunnerError.processDidNotStart(error.localizedDescription)
        }

        var didTimeout = false
        let timeoutSeconds = task.manifest.runner.timeoutSeconds
        if timeoutSeconds > 0 {
            let result = semaphore.wait(timeout: .now() + .seconds(timeoutSeconds))
            if result == .timedOut {
                didTimeout = true
                let timeoutMessage = "\nRun Shelf：超过 \(timeoutSeconds) 秒未结束，正在终止进程。\n"
                if let data = timeoutMessage.data(using: .utf8) {
                    stderrHandle.write(data)
                }
                process.terminate()

                if semaphore.wait(timeout: .now() + .seconds(5)) == .timedOut {
                    let killMessage = "Run Shelf：进程收到终止信号后仍未退出，已强制结束。\n"
                    if let data = killMessage.data(using: .utf8) {
                        stderrHandle.write(data)
                    }
                    kill(process.processIdentifier, SIGKILL)
                    semaphore.wait()
                }
            }
        } else {
            semaphore.wait()
        }

        let endedAt = Date()
        let exitCode = Int(process.terminationStatus)
        let status: TaskRunStatus = didTimeout ? .timeout : (exitCode == 0 ? .success : .failed)
        let durationMs = Int(endedAt.timeIntervalSince(startedAt) * 1000)
        let scriptSha256 = try sha256Hex(for: snapshotURL)

        let record = RunRecord(
            runId: runId,
            taskId: task.id,
            trigger: trigger,
            status: status,
            exitCode: exitCode,
            scheduledAt: scheduledAt,
            startedAt: startedAt,
            endedAt: endedAt,
            durationMs: durationMs,
            scriptSha256: scriptSha256,
            stdoutPath: "stdout.log",
            stderrPath: "stderr.log",
            message: didTimeout ? "超过 \(timeoutSeconds) 秒未结束" : nil
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

    private static func makeRunID(from date: Date) -> String {
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
