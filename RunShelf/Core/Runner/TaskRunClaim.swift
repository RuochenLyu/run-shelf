import Darwin
import Foundation

struct TaskProcessIdentity: Codable, Equatable, Sendable {
    var startTimeSeconds: UInt64
    var startTimeMicroseconds: UInt64
}

struct TaskRunClaim: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var runId: String
    var taskId: String
    var processID: Int32
    var processGroupID: Int32?
    var processIdentity: TaskProcessIdentity? = nil
    var processGroupLeaderIdentity: TaskProcessIdentity? = nil
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
    let isLegacy: Bool

    var claimURL: URL {
        claimDirectoryURL.appendingPathComponent("claim.json")
    }

    /// 读-改-写在 claim 锁内完成：启动方（CLI/调度进程）写宿主 pid 与宿主自己写
    /// 进程组可能并发，不加锁时后写者会用旧快照覆盖掉对方的字段。
    /// 调用方不能已持有同一 `.claim-lock`（flock 不可重入）。
    func update(processID: Int32? = nil, processGroupID: Int32? = nil, host: String? = nil) throws {
        try TaskRunClaimManager.withClaimLock(rootURL: claimRootURL) {
            var claim = try readClaim()
            if let processID {
                claim.processID = processID
                claim.processIdentity = TaskRunClaimManager.processIdentity(for: processID)
            }
            if let processGroupID {
                claim.processGroupID = processGroupID
                claim.processGroupLeaderIdentity = TaskRunClaimManager.processIdentity(for: processGroupID)
            }
            if let host {
                claim.host = host
            }
            try TaskRunClaimManager.write(claim: claim, to: claimURL)
        }
    }

    private var claimRootURL: URL {
        isLegacy ? claimDirectoryURL : claimDirectoryURL.deletingLastPathComponent()
    }

    func release() {
        guard let claim = try? readClaim(), claim.runId == runID else { return }
        if isLegacy {
            try? fileManager.removeItem(at: claimURL)
        } else {
            try? fileManager.removeItem(at: claimDirectoryURL)
        }
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
        try TaskDefinitionFileLock.withLock(
            tasksDirectoryURL: task.directoryURL.deletingLastPathComponent(),
            taskID: task.id,
            mode: .shared,
            fileManager: fileManager
        ) {
            try revalidateTaskRoot(task, fileManager: fileManager)
            let rootURL = claimDirectoryURL(for: task)
            if !fileManager.fileExists(atPath: rootURL.path) {
                do {
                    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: false)
                } catch {
                    let isDirectory = (try? rootURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    guard isDirectory else { throw error }
                }
            }

            return try withClaimLock(rootURL: rootURL) {
                try reclaimStaleClaims(task: task, rootURL: rootURL, now: now, fileManager: fileManager)

                let active = activeClaims(for: task, now: now, fileManager: fileManager)
                if task.manifest.runner.concurrency != "allow", let existing = active.first {
                    throw TaskRunClaimError.alreadyRunning(existing)
                }

                let runDirectoryURL = rootURL.appendingPathComponent(runID, isDirectory: true)
                do {
                    try fileManager.createDirectory(at: runDirectoryURL, withIntermediateDirectories: false)
                } catch {
                    if let existing = readClaim(at: runDirectoryURL.appendingPathComponent("claim.json")) {
                        throw TaskRunClaimError.alreadyRunning(existing)
                    }
                    throw TaskRunClaimError.corruptActiveClaim(runDirectoryURL.path)
                }

                let claim = TaskRunClaim(
                    schemaVersion: 1,
                    runId: runID,
                    taskId: task.id,
                    processID: getpid(),
                    processGroupID: nil,
                    processIdentity: processIdentity(for: getpid()),
                    host: host,
                    startedAt: now
                )
                let claimURL = runDirectoryURL.appendingPathComponent("claim.json")
                do {
                    try write(claim: claim, to: claimURL)
                } catch {
                    try? fileManager.removeItem(at: runDirectoryURL)
                    throw error
                }
                return TaskRunClaimLease(
                    taskID: task.id,
                    runID: runID,
                    claimDirectoryURL: runDirectoryURL,
                    fileManager: fileManager,
                    isLegacy: false
                )
            }
        }
    }

    private static func revalidateTaskRoot(_ task: RunShelfTask, fileManager: FileManager) throws {
        guard task.directoryURL.lastPathComponent == task.id,
              fileManager.fileExists(atPath: task.directoryURL.path)
        else {
            throw TaskRepositoryError.taskDirectoryMissing(task.id)
        }
        let manifestURL = task.directoryURL.appendingPathComponent("task.json")
        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(TaskManifest.self, from: data)
        guard manifest.id == task.id else {
            throw TaskRepositoryError.taskIdentityMismatch(
                directoryName: task.id,
                manifestID: manifest.id
            )
        }
    }

    static func existing(
        task: RunShelfTask,
        runID: String,
        fileManager: FileManager = .default
    ) throws -> TaskRunClaimLease {
        let rootURL = claimDirectoryURL(for: task)
        let runDirectoryURL = rootURL.appendingPathComponent(runID, isDirectory: true)
        let runClaimURL = runDirectoryURL.appendingPathComponent("claim.json")
        if let claim = readClaim(at: runClaimURL) {
            guard claim.runId == runID else {
                throw TaskRunClaimError.claimMismatch(expected: runID, actual: claim.runId)
            }
            return TaskRunClaimLease(
                taskID: task.id,
                runID: runID,
                claimDirectoryURL: runDirectoryURL,
                fileManager: fileManager,
                isLegacy: false
            )
        }

        let legacyClaimURL = rootURL.appendingPathComponent("claim.json")
        guard let claim = readClaim(at: legacyClaimURL) else {
            throw TaskRunClaimError.claimNotFound(runID)
        }
        guard claim.runId == runID else {
            throw TaskRunClaimError.claimMismatch(expected: runID, actual: claim.runId)
        }
        return TaskRunClaimLease(
            taskID: task.id,
            runID: runID,
            claimDirectoryURL: rootURL,
            fileManager: fileManager,
            isLegacy: true
        )
    }

    static func activeClaim(
        for task: RunShelfTask,
        runID: String,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> TaskRunClaim? {
        activeClaims(for: task, now: now, fileManager: fileManager).first { $0.runId == runID }
    }

    static func activeClaim(
        for task: RunShelfTask,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> TaskRunClaim? {
        activeClaims(for: task, now: now, fileManager: fileManager).first
    }

    static func activeClaims(
        for task: RunShelfTask,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> [TaskRunClaim] {
        let rootURL = claimDirectoryURL(for: task)
        var claims: [TaskRunClaim] = []

        let legacyClaimURL = rootURL.appendingPathComponent("claim.json")
        if let claim = readClaim(at: legacyClaimURL), !isStale(claim: claim, task: task, now: now) {
            claims.append(claim)
        }

        let directories = (try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for directory in directories {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let claim = readClaim(at: directory.appendingPathComponent("claim.json")),
                  !isStale(claim: claim, task: task, now: now)
            else {
                continue
            }
            claims.append(claim)
        }

        return claims.sorted { lhs, rhs in
            if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
            return lhs.runId < rhs.runId
        }
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

    private static func reclaimStaleClaims(
        task: RunShelfTask,
        rootURL: URL,
        now: Date,
        fileManager: FileManager
    ) throws {
        let legacyClaimURL = rootURL.appendingPathComponent("claim.json")
        if let claim = readClaim(at: legacyClaimURL) {
            if isStale(claim: claim, task: task, now: now), readClaim(at: legacyClaimURL) == claim {
                try? fileManager.removeItem(at: legacyClaimURL)
            }
        } else if fileManager.fileExists(atPath: legacyClaimURL.path) {
            throw TaskRunClaimError.corruptActiveClaim(legacyClaimURL.path)
        }

        let directories = (try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for directory in directories {
            let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values?.isDirectory == true else { continue }
            let claimURL = directory.appendingPathComponent("claim.json")
            if let claim = readClaim(at: claimURL) {
                guard isStale(claim: claim, task: task, now: now), readClaim(at: claimURL) == claim else { continue }
                try? fileManager.removeItem(at: directory)
            } else {
                let modifiedAt = values?.contentModificationDate ?? now
                if now.timeIntervalSince(modifiedAt) > 60 {
                    try? fileManager.removeItem(at: directory)
                } else {
                    throw TaskRunClaimError.corruptActiveClaim(directory.path)
                }
            }
        }
    }

    static func canSafelySignal(_ claim: TaskRunClaim) -> Bool {
        if let processGroupID = claim.processGroupID {
            guard isProcessGroupAlive(processGroupID),
                  let expected = claim.processGroupLeaderIdentity,
                  let current = processIdentity(for: processGroupID)
            else {
                return false
            }
            return current == expected
        }
        guard isProcessAlive(claim.processID),
              let expected = claim.processIdentity,
              let current = processIdentity(for: claim.processID)
        else {
            return false
        }
        return current == expected
    }

    static func processIdentity(for pid: Int32) -> TaskProcessIdentity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.size
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(expectedSize))
        guard result == Int32(expectedSize) else { return nil }
        return TaskProcessIdentity(
            startTimeSeconds: info.pbi_start_tvsec,
            startTimeMicroseconds: info.pbi_start_tvusec
        )
    }

    private static func isStale(claim: TaskRunClaim, task: RunShelfTask, now: Date) -> Bool {
        if let processGroupID = claim.processGroupID {
            guard isProcessGroupAlive(processGroupID) else { return true }
            if let expected = claim.processGroupLeaderIdentity {
                return processIdentity(for: processGroupID) != expected
            }
        } else {
            guard isProcessAlive(claim.processID) else { return true }
            if let expected = claim.processIdentity {
                return processIdentity(for: claim.processID) != expected
            }
        }

        return now.timeIntervalSince(claim.startedAt) > staleInterval(for: task)
    }

    private static func staleInterval(for task: RunShelfTask) -> TimeInterval {
        let timeout = task.manifest.runner.timeoutSeconds
        if timeout > 0 {
            return TimeInterval(timeout + 600)
        }
        return 24 * 60 * 60
    }

    static func withClaimLock<T>(rootURL: URL, operation: () throws -> T) throws -> T {
        let lockURL = rootURL.appendingPathComponent(".claim-lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, mode_t(0o600))
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
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
