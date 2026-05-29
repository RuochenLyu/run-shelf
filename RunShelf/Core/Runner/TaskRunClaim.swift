import Darwin
import Foundation

struct TaskRunClaim: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var runId: String
    var taskId: String
    var processID: Int32
    var processGroupID: Int32?
    var host: String
    var startedAt: Date
}

enum TaskRunClaimMode: Sendable {
    case acquire
    case existing
}

enum TaskRunClaimError: LocalizedError {
    case alreadyRunning(TaskRunClaim)
    case claimNotFound(String)
    case claimMismatch(expected: String, actual: String)
    case corruptActiveClaim(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning(let claim):
            return "任务正在运行：runId=\(claim.runId)，pid=\(claim.processID)"
        case .claimNotFound(let runId):
            return "找不到运行 claim：\(runId)"
        case .claimMismatch(let expected, let actual):
            return "运行 claim 不匹配：期望 \(expected)，实际 \(actual)"
        case .corruptActiveClaim(let path):
            return "运行 claim 正在初始化或内容损坏：\(path)"
        }
    }
}

struct TaskRunClaimLease {
    let taskID: String
    let runID: String
    let claimDirectoryURL: URL
    let fileManager: FileManager

    var claimURL: URL {
        claimDirectoryURL.appendingPathComponent("claim.json")
    }

    func update(processID: Int32? = nil, processGroupID: Int32? = nil, host: String? = nil) throws {
        var claim = try readClaim()
        if let processID {
            claim.processID = processID
        }
        if let processGroupID {
            claim.processGroupID = processGroupID
        }
        if let host {
            claim.host = host
        }
        try TaskRunClaimManager.write(claim: claim, to: claimURL)
    }

    func release() {
        guard let claim = try? readClaim(), claim.runId == runID else { return }
        try? fileManager.removeItem(at: claimDirectoryURL)
    }

    private func readClaim() throws -> TaskRunClaim {
        guard let claim = TaskRunClaimManager.readClaim(at: claimURL) else {
            throw TaskRunClaimError.claimNotFound(runID)
        }
        guard claim.runId == runID else {
            throw TaskRunClaimError.claimMismatch(expected: runID, actual: claim.runId)
        }
        return claim
    }
}

enum TaskRunClaimManager {
    static func claimDirectoryURL(for task: RunShelfTask) -> URL {
        task.directoryURL.appendingPathComponent(".run-claim", isDirectory: true)
    }

    static func acquire(
        task: RunShelfTask,
        runID: String,
        host: String,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> TaskRunClaimLease {
        let claimDirectoryURL = claimDirectoryURL(for: task)
        let claimURL = claimDirectoryURL.appendingPathComponent("claim.json")

        for _ in 0..<2 {
            do {
                try fileManager.createDirectory(at: claimDirectoryURL, withIntermediateDirectories: false)
                let claim = TaskRunClaim(
                    schemaVersion: 1,
                    runId: runID,
                    taskId: task.id,
                    processID: getpid(),
                    processGroupID: nil,
                    host: host,
                    startedAt: now
                )
                try write(claim: claim, to: claimURL)
                return TaskRunClaimLease(
                    taskID: task.id,
                    runID: runID,
                    claimDirectoryURL: claimDirectoryURL,
                    fileManager: fileManager
                )
            } catch {
                if fileManager.fileExists(atPath: claimDirectoryURL.path) {
                    try reclaimIfStale(
                        task: task,
                        claimDirectoryURL: claimDirectoryURL,
                        claimURL: claimURL,
                        now: now,
                        fileManager: fileManager
                    )
                } else {
                    throw error
                }
            }
        }

        if let claim = readClaim(at: claimURL) {
            throw TaskRunClaimError.alreadyRunning(claim)
        }
        throw TaskRunClaimError.corruptActiveClaim(claimDirectoryURL.path)
    }

    static func existing(
        task: RunShelfTask,
        runID: String,
        fileManager: FileManager = .default
    ) throws -> TaskRunClaimLease {
        let claimDirectoryURL = claimDirectoryURL(for: task)
        let claimURL = claimDirectoryURL.appendingPathComponent("claim.json")
        guard let claim = readClaim(at: claimURL) else {
            throw TaskRunClaimError.claimNotFound(runID)
        }
        guard claim.runId == runID else {
            throw TaskRunClaimError.claimMismatch(expected: runID, actual: claim.runId)
        }
        return TaskRunClaimLease(
            taskID: task.id,
            runID: runID,
            claimDirectoryURL: claimDirectoryURL,
            fileManager: fileManager
        )
    }

    static func activeClaim(
        for task: RunShelfTask,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> TaskRunClaim? {
        let claimDirectoryURL = claimDirectoryURL(for: task)
        let claimURL = claimDirectoryURL.appendingPathComponent("claim.json")
        guard let claim = readClaim(at: claimURL) else { return nil }
        return isStale(claim: claim, task: task, now: now) ? nil : claim
    }

    static func write(claim: TaskRunClaim, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(claim).write(to: url, options: [.atomic])
    }

    static func readClaim(at url: URL) -> TaskRunClaim? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TaskRunClaim.self, from: data)
    }

    private static func reclaimIfStale(
        task: RunShelfTask,
        claimDirectoryURL: URL,
        claimURL: URL,
        now: Date,
        fileManager: FileManager
    ) throws {
        if let claim = readClaim(at: claimURL) {
            if isStale(claim: claim, task: task, now: now) {
                try? fileManager.removeItem(at: claimDirectoryURL)
                return
            }
            throw TaskRunClaimError.alreadyRunning(claim)
        }

        let values = try? claimDirectoryURL.resourceValues(forKeys: [.contentModificationDateKey])
        let modifiedAt = values?.contentModificationDate ?? now
        if now.timeIntervalSince(modifiedAt) > 60 {
            try? fileManager.removeItem(at: claimDirectoryURL)
            return
        }
        throw TaskRunClaimError.corruptActiveClaim(claimDirectoryURL.path)
    }

    private static func isStale(claim: TaskRunClaim, task: RunShelfTask, now: Date) -> Bool {
        let age = now.timeIntervalSince(claim.startedAt)
        if age > staleInterval(for: task) {
            return true
        }

        if let processGroupID = claim.processGroupID {
            return !isProcessGroupAlive(processGroupID)
        }

        return !isProcessAlive(claim.processID)
    }

    private static func staleInterval(for task: RunShelfTask) -> TimeInterval {
        let timeout = task.manifest.runner.timeoutSeconds
        if timeout > 0 {
            return TimeInterval(timeout + 600)
        }
        return 24 * 60 * 60
    }

    private static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private static func isProcessGroupAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(-pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }
}
