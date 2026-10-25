import Darwin
import Foundation

enum TaskDefinitionFileLock {
    enum Mode {
        case shared
        case exclusive

        var operation: Int32 {
            switch self {
            case .shared: return LOCK_SH
            case .exclusive: return LOCK_EX
            }
        }
    }

    static func withLock<T>(
        tasksDirectoryURL: URL,
        taskID: String,
        mode: Mode,
        fileManager: FileManager = .default,
        _ body: () throws -> T
    ) throws -> T {
        guard UUID(uuidString: taskID) != nil else {
            throw TaskRepositoryError.invalidTaskID(taskID)
        }
        let locksURL = try stableLocksDirectory(
            tasksDirectoryURL: tasksDirectoryURL,
            fileManager: fileManager
        )
        let lockURL = locksURL.appendingPathComponent("task-\(taskID).lock")
        return try withFileLock(at: lockURL, operation: mode.operation, body)
    }
}

enum TaskRepositoryFileLock {
    static func withExclusiveLock<T>(
        tasksDirectoryURL: URL,
        fileManager: FileManager = .default,
        _ body: () throws -> T
    ) throws -> T {
        let locksURL = try stableLocksDirectory(
            tasksDirectoryURL: tasksDirectoryURL,
            fileManager: fileManager
        )
        return try withFileLock(
            at: locksURL.appendingPathComponent("repository.lock"),
            operation: LOCK_EX,
            body
        )
    }
}

private func stableLocksDirectory(tasksDirectoryURL: URL, fileManager: FileManager) throws -> URL {
    try fileManager.createDirectory(at: tasksDirectoryURL, withIntermediateDirectories: true)
    let locksURL = tasksDirectoryURL.appendingPathComponent(".locks", isDirectory: true)
    try fileManager.createDirectory(at: locksURL, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locksURL.path)
    return locksURL
}

private func withFileLock<T>(at lockURL: URL, operation: Int32, _ body: () throws -> T) throws -> T {
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }

        guard flock(descriptor, operation) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
}

struct TaskDefinitionRevision: Codable, Equatable, Sendable {
    var manifest: FileRevision?
    var script: FileRevision?
    var notes: FileRevision?

    struct FileRevision: Codable, Equatable, Sendable {
        var mtimeNanoseconds: Int64
        var size: Int

        init(_ signature: TaskFileSignature.FileSig) {
            self.mtimeNanoseconds = Int64((signature.mtime.timeIntervalSince1970 * 1_000_000_000).rounded())
            self.size = signature.size
        }

        init(mtimeNanoseconds: Int64, size: Int) {
            self.mtimeNanoseconds = mtimeNanoseconds
            self.size = size
        }
    }

    init(signature: TaskFileSignature) {
        self.manifest = signature.manifestSig.map(FileRevision.init)
        self.script = signature.scriptSig.map(FileRevision.init)
        self.notes = signature.notesSig.map(FileRevision.init)
    }

    init(token: String) throws {
        let parts = token.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else {
            throw TaskRepositoryError.invalidRevision(token)
        }
        self.manifest = try Self.fileRevision(from: parts[0])
        self.script = try Self.fileRevision(from: parts[1])
        self.notes = try Self.fileRevision(from: parts[2])
    }

    static func capture(for directoryURL: URL) -> TaskDefinitionRevision {
        TaskDefinitionRevision(signature: TaskFileSignature.capture(for: directoryURL))
    }

    var token: String {
        [
            Self.tokenPart(for: manifest),
            Self.tokenPart(for: script),
            Self.tokenPart(for: notes)
        ].joined(separator: ";")
    }

    private static func tokenPart(for revision: FileRevision?) -> String {
        guard let revision else { return "-" }
        return "\(revision.mtimeNanoseconds):\(revision.size)"
    }

    private static func fileRevision(from tokenPart: String) throws -> FileRevision? {
        guard tokenPart != "-" else { return nil }
        let pieces = tokenPart.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              let mtimeNanoseconds = Int64(pieces[0]),
              let size = Int(pieces[1])
        else {
            throw TaskRepositoryError.invalidRevision(tokenPart)
        }
        return FileRevision(mtimeNanoseconds: mtimeNanoseconds, size: size)
    }
}

struct TaskSpec: Codable, Equatable, Sendable {
    var id: String? = nil
    var slug: String? = nil
    var name: String? = nil
    var description: String? = nil
    var enabled: Bool? = nil
    var schedule: TaskSchedule? = nil
    var timeoutSeconds: Int? = nil
    var concurrency: String? = nil
    var priority: String? = nil
    var script: String? = nil
    var notes: String? = nil

    init(
        id: String? = nil,
        slug: String? = nil,
        name: String? = nil,
        description: String? = nil,
        enabled: Bool? = nil,
        schedule: TaskSchedule? = nil,
        timeoutSeconds: Int? = nil,
        concurrency: String? = nil,
        priority: String? = nil,
        script: String? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.slug = slug
        self.name = name
        self.description = description
        self.enabled = enabled
        self.schedule = schedule
        self.timeoutSeconds = timeoutSeconds
        self.concurrency = concurrency
        self.priority = priority
        self.script = script
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case slug
        case name
        case description
        case enabled
        case schedule
        case timeoutSeconds
        case concurrency
        case priority
        case script
        case notes
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownKeys(in: decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        slug = try container.decodeIfPresent(String.self, forKey: .slug)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        schedule = try container.decodeIfPresent(TaskSchedule.self, forKey: .schedule)
        timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds)
        concurrency = try container.decodeIfPresent(String.self, forKey: .concurrency)
        priority = try container.decodeIfPresent(String.self, forKey: .priority)
        script = try container.decodeIfPresent(String.self, forKey: .script)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
    }
}

struct TaskRepositoryReadResult: Sendable {
    var task: RunShelfTask
    var revision: TaskDefinitionRevision
}

struct TaskRepositoryWriteResult: Sendable {
    var task: RunShelfTask
    var revision: TaskDefinitionRevision
}

enum TaskRepositorySelector: Sendable {
    case id(String)
    case slug(String)
    case name(String)
    case idOrSlug(String)
}

enum TaskRepositoryError: LocalizedError, Equatable {
    case notFound(String)
    case ambiguous(String, [String])
    case conflict(String)
    case invalidSlug(String)
    case reservedSlug(String)
    case invalidSchedule(String)
    case invalidTimeoutSeconds(Int)
    case invalidConcurrency(String)
    case invalidPriority(String)
    case invalidTaskID(String)
    case invalidRevision(String)
    case missingRequiredField(String)
    case taskDirectoryMissing(String)
    case taskIdentityMismatch(directoryName: String, manifestID: String)
    case taskRunning(String, [String])

    var errorDescription: String? {
        switch self {
        case .notFound(let value):
            return "找不到任务：\(value)"
        case .ambiguous(let value, let matches):
            return "任务选择器不唯一：\(value)，匹配到 \(matches.joined(separator: ", "))"
        case .conflict(let message):
            return message
        case .invalidSlug(let slug):
            return "slug 不合法：\(slug)。只能使用小写字母、数字、点、短横线和下划线，且必须以字母或数字开头。"
        case .reservedSlug(let slug):
            return "slug 是 CLI 保留字：\(slug)。请换一个 slug。"
        case .invalidSchedule(let message):
            return "执行计划不合法：\(message)"
        case .invalidTimeoutSeconds(let value):
            return "timeoutSeconds 不能小于 0：\(value)"
        case .invalidConcurrency(let value):
            return "concurrency 不合法：\(value)。可选 \(TaskConcurrency.all.joined(separator: " / "))。"
        case .invalidPriority(let value):
            return "priority 不合法：\(value)。可选 \(TaskPriority.all.joined(separator: " / "))。"
        case .invalidTaskID(let taskID):
            return "任务 id 不合法：\(taskID)"
        case .invalidRevision(let revision):
            return "revision 不合法：\(revision)"
        case .missingRequiredField(let field):
            return "缺少必填字段：\(field)"
        case .taskDirectoryMissing(let taskID):
            return "任务目录已不存在：\(taskID)"
        case .taskIdentityMismatch(let directoryName, let manifestID):
            return "任务目录与 manifest 身份不一致：目录=\(directoryName)，manifest.id=\(manifestID)"
        case .taskRunning(let taskID, let runIDs):
            return "运行中的任务不能删除：\(taskID)，runId=\(runIDs.joined(separator: ", "))"
        }
    }
}

struct TaskRepository {
    var tasksDirectoryURL: URL = RunShelfPaths.tasksDirectoryURL()
    var fileManager: FileManager = .default

    private var loader: TaskFileStore {
        TaskFileStore(tasksDirectoryURL: tasksDirectoryURL, fileManager: fileManager)
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    func loadTasks(includeRuns: Bool = true) throws -> [RunShelfTask] {
        try loader.loadTasks(includeRuns: includeRuns)
    }

    func loadTasksWithIssues(includeRuns: Bool = true) throws -> TaskLoadResult {
        try loader.loadTasksWithIssues(includeRuns: includeRuns)
    }

    func loadTasksWithLatestRun() throws -> [RunShelfTask] {
        try loader.loadTasks(includeRuns: false).map { task in
            var task = task
            task.runs = loader.loadLatestRun(for: task.directoryURL).map { [$0] } ?? []
            return task
        }
    }

    func loadTask(selector: TaskRepositorySelector, includeRuns: Bool = true) throws -> TaskRepositoryReadResult {
        let task = try resolve(selector: selector, includeRuns: includeRuns)
        return try loadTaskConsistently(at: task.directoryURL, includeRuns: includeRuns)
    }

    func loadTaskWithLatestRun(selector: TaskRepositorySelector) throws -> TaskRepositoryReadResult {
        var read = try loadTask(selector: selector, includeRuns: false)
        read.task.runs = loader.loadLatestRun(for: read.task.directoryURL).map { [$0] } ?? []
        return read
    }

    func loadRun(task: RunShelfTask, runID: String) throws -> RunRecord? {
        try loader.loadRun(for: task.directoryURL, runID: runID)
    }

    func loadTaskConsistently(
        at directoryURL: URL,
        includeRuns: Bool = true,
        maxRetries: Int = 3
    ) throws -> TaskRepositoryReadResult {
        let attempts = max(maxRetries, 1)
        for _ in 0..<attempts {
            let before = TaskDefinitionRevision.capture(for: directoryURL)
            let task = try loader.loadTask(at: directoryURL, includeRuns: includeRuns)
            let after = TaskDefinitionRevision.capture(for: directoryURL)
            if before == after {
                return TaskRepositoryReadResult(task: task, revision: after)
            }
        }
        throw TaskRepositoryError.conflict("任务文件正在被修改，请重新读取后再试。")
    }

    func createTask(from spec: TaskSpec, origin: TaskOrigin? = nil) throws -> TaskRepositoryWriteResult {
        try TaskRepositoryFileLock.withExclusiveLock(
            tasksDirectoryURL: tasksDirectoryURL,
            fileManager: fileManager
        ) {
            let id = try normalizedTaskID(spec.id ?? UUID().uuidString)
            let directoryURL = tasksDirectoryURL.appendingPathComponent(id, isDirectory: true)
            guard !fileManager.fileExists(atPath: directoryURL.path) else {
                throw TaskRepositoryError.conflict("任务目录已存在：\(id)")
            }

            let name = try nonEmpty(spec.name, field: "name")
            let slug = try normalizedSlug(spec.slug)
            if let slug {
                try ensureUniqueSlugWhileRepositoryLocked(slug, excludingID: nil)
            }
            let schedule = try validatedSchedule(spec.schedule ?? .defaultDaily)
            var manifest = TaskManifest.create(
                id: id,
                slug: slug,
                origin: origin,
                name: name,
                description: spec.description ?? "",
                enabled: spec.enabled ?? true,
                schedule: schedule
            )
            manifest.runner.timeoutSeconds = max(spec.timeoutSeconds ?? manifest.runner.timeoutSeconds, 0)
            manifest.runner.concurrency = try validatedConcurrency(spec.concurrency) ?? manifest.runner.concurrency
            manifest.runner.priority = try validatedPriority(spec.priority) ?? manifest.runner.priority

            let task = RunShelfTask(
                manifest: manifest,
                directoryURL: directoryURL,
                script: normalizedScript(spec.script),
                notes: spec.notes ?? "",
                runs: [],
                isDirty: false
            )
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: false)
            do {
                let revision = try TaskDefinitionFileLock.withLock(
                    tasksDirectoryURL: tasksDirectoryURL,
                    taskID: id,
                    mode: .exclusive,
                    fileManager: fileManager
                ) {
                    try writeTaskWhileLocked(task, expectedRevision: nil, isCreating: true)
                }
                return TaskRepositoryWriteResult(task: task, revision: revision)
            } catch {
                try? fileManager.removeItem(at: directoryURL)
                throw error
            }
        }
    }

    func updateTask(
        selector: TaskRepositorySelector,
        with spec: TaskSpec,
        expectedRevision: TaskDefinitionRevision? = nil
    ) throws -> TaskRepositoryWriteResult {
        let read = try loadTask(selector: selector, includeRuns: true)
        var task = read.task

        if let id = spec.id, id != task.id {
            throw TaskRepositoryError.invalidTaskID(id)
        }
        if spec.slug != nil {
            let slug = try normalizedSlug(spec.slug)
            task.manifest.slug = slug
        }
        if let name = spec.name {
            task.manifest.name = try nonEmpty(name, field: "name")
        }
        if let description = spec.description {
            task.manifest.description = description
        }
        if let enabled = spec.enabled {
            task.manifest.enabled = enabled
        }
        if let schedule = spec.schedule {
            task.manifest.schedule = try validatedSchedule(schedule)
        }
        if let timeoutSeconds = spec.timeoutSeconds {
            task.manifest.runner.timeoutSeconds = max(timeoutSeconds, 0)
        }
        if let concurrency = try validatedConcurrency(spec.concurrency) {
            task.manifest.runner.concurrency = concurrency
        }
        if let priority = try validatedPriority(spec.priority) {
            task.manifest.runner.priority = priority
        }
        if let script = spec.script {
            task.script = TaskFileStore.normalizedTemplateScript(script)
        }
        if let notes = spec.notes {
            task.notes = notes
        }
        task.manifest.updatedAt = Date()
        task.isDirty = false

        let revision = try writeTask(task, expectedRevision: expectedRevision ?? read.revision)
        return TaskRepositoryWriteResult(task: task, revision: revision)
    }

    @discardableResult
    func writeTask(_ task: RunShelfTask, expectedRevision: TaskDefinitionRevision? = nil) throws -> TaskDefinitionRevision {
        try TaskRepositoryFileLock.withExclusiveLock(
            tasksDirectoryURL: tasksDirectoryURL,
            fileManager: fileManager
        ) {
            if let slug = task.manifest.slug {
                _ = try normalizedSlug(slug)
                try ensureUniqueSlugWhileRepositoryLocked(slug, excludingID: task.id)
            }
            return try TaskDefinitionFileLock.withLock(
                tasksDirectoryURL: tasksDirectoryURL,
                taskID: task.id,
                mode: .exclusive,
                fileManager: fileManager
            ) {
                try writeTaskWhileLocked(task, expectedRevision: expectedRevision, isCreating: false)
            }
        }
    }

    func deleteTask(selector: TaskRepositorySelector) throws -> String {
        try TaskRepositoryFileLock.withExclusiveLock(
            tasksDirectoryURL: tasksDirectoryURL,
            fileManager: fileManager
        ) {
            let task = try resolve(selector: selector, includeRuns: false)
            return try TaskDefinitionFileLock.withLock(
                tasksDirectoryURL: tasksDirectoryURL,
                taskID: task.id,
                mode: .exclusive,
                fileManager: fileManager
            ) {
                try revalidateTaskRootWhileLocked(task)
                let activeRunIDs = TaskRunClaimManager.activeClaims(for: task, fileManager: fileManager)
                    .map(\.runId)
                    .sorted()
                if !activeRunIDs.isEmpty {
                    throw TaskRepositoryError.taskRunning(task.id, activeRunIDs)
                }

                do {
                    var resultingURL: NSURL?
                    try fileManager.trashItem(at: task.directoryURL, resultingItemURL: &resultingURL)
                } catch {
                    let trashURL = tasksDirectoryURL.appendingPathComponent("trash", isDirectory: true)
                    try fileManager.createDirectory(at: trashURL, withIntermediateDirectories: true)
                    let destination = trashURL.appendingPathComponent(task.id + "-" + UUID().uuidString, isDirectory: true)
                    try fileManager.moveItem(at: task.directoryURL, to: destination)
                }
                return task.id
            }
        }
    }

    func resolve(selector: TaskRepositorySelector, includeRuns: Bool = true) throws -> RunShelfTask {
        switch selector {
        case .id(let id):
            let directoryURL = tasksDirectoryURL.appendingPathComponent(id, isDirectory: true)
            guard fileManager.fileExists(atPath: directoryURL.path) else {
                throw TaskRepositoryError.notFound(id)
            }
            return try loader.loadTask(at: directoryURL, includeRuns: includeRuns)
        case .slug(let slug):
            return try uniqueTask(matching: slug, includeRuns: includeRuns) { $0.manifest.slug == slug }
        case .name(let name):
            return try uniqueTask(matching: name, includeRuns: includeRuns) { $0.manifest.name == name }
        case .idOrSlug(let value):
            let directoryURL = tasksDirectoryURL.appendingPathComponent(value, isDirectory: true)
            if fileManager.fileExists(atPath: directoryURL.path) {
                return try loader.loadTask(at: directoryURL, includeRuns: includeRuns)
            }
            return try uniqueTask(matching: value, includeRuns: includeRuns) { $0.manifest.slug == value }
        }
    }

    func validate(spec: TaskSpec, creating: Bool) throws -> [CommandRisk] {
        if creating {
            _ = try nonEmpty(spec.name, field: "name")
        }
        if let slug = spec.slug {
            _ = try normalizedSlug(slug)
        }
        if let schedule = spec.schedule {
            _ = try validatedSchedule(schedule)
        }
        if let timeoutSeconds = spec.timeoutSeconds, timeoutSeconds < 0 {
            throw TaskRepositoryError.invalidTimeoutSeconds(timeoutSeconds)
        }
        _ = try validatedConcurrency(spec.concurrency)
        _ = try validatedPriority(spec.priority)
        return DangerousCommandScanner.scan(spec.script ?? "")
    }

    private func validatedConcurrency(_ value: String?) throws -> String? {
        guard let value else { return nil }
        guard TaskConcurrency.isValid(value) else {
            throw TaskRepositoryError.invalidConcurrency(value)
        }
        return value
    }

    private func validatedPriority(_ value: String?) throws -> String? {
        guard let value else { return nil }
        guard TaskPriority.isValid(value) else {
            throw TaskRepositoryError.invalidPriority(value)
        }
        return value
    }

    private func uniqueTask(
        matching value: String,
        includeRuns: Bool,
        predicate: (RunShelfTask) -> Bool
    ) throws -> RunShelfTask {
        let matches = try loader.loadTasks(includeRuns: includeRuns).filter(predicate)
        if matches.isEmpty {
            throw TaskRepositoryError.notFound(value)
        }
        if matches.count > 1 {
            throw TaskRepositoryError.ambiguous(value, matches.map(\.id).sorted())
        }
        return matches[0]
    }

    private func writeTaskWhileLocked(
        _ inputTask: RunShelfTask,
        expectedRevision: TaskDefinitionRevision?,
        isCreating: Bool
    ) throws -> TaskDefinitionRevision {
        var task = inputTask
        guard fileManager.fileExists(atPath: task.directoryURL.path) else {
            throw TaskRepositoryError.taskDirectoryMissing(task.id)
        }
        guard task.directoryURL.lastPathComponent == task.id else {
            throw TaskRepositoryError.invalidTaskID(task.id)
        }
        _ = try validatedSchedule(task.manifest.schedule)
        if !isCreating {
            let persistedManifest = try revalidateTaskRootWhileLocked(task)
            task.manifest.origin = persistedManifest.origin
        }
        if let expectedRevision {
            let currentRevision = TaskDefinitionRevision.capture(for: task.directoryURL)
            guard currentRevision == expectedRevision else {
                throw TaskRepositoryError.conflict("任务文件已被其他进程修改，请重新读取后再保存。")
            }
        }

        let runsURL = task.directoryURL.appendingPathComponent("runs", isDirectory: true)
        if !fileManager.fileExists(atPath: runsURL.path) {
            try fileManager.createDirectory(at: runsURL, withIntermediateDirectories: false)
        }

        let manifestData = try encoder.encode(task.manifest)
        try manifestData.write(to: task.directoryURL.appendingPathComponent("task.json"), options: [.atomic])

        let scriptURL = task.directoryURL.appendingPathComponent("run.sh")
        try TaskFileStore.normalizedTemplateScript(task.script).write(
            to: scriptURL,
            atomically: true,
            encoding: .utf8
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: scriptURL.path
        )
        try task.notes.write(
            to: task.directoryURL.appendingPathComponent("notes.md"),
            atomically: true,
            encoding: .utf8
        )
        try? fileManager.removeItem(at: task.directoryURL.appendingPathComponent(".definition-lock"))
        return TaskDefinitionRevision.capture(for: task.directoryURL)
    }

    @discardableResult
    private func revalidateTaskRootWhileLocked(_ task: RunShelfTask) throws -> TaskManifest {
        guard fileManager.fileExists(atPath: task.directoryURL.path) else {
            throw TaskRepositoryError.taskDirectoryMissing(task.id)
        }
        guard task.directoryURL.lastPathComponent == task.id else {
            throw TaskRepositoryError.invalidTaskID(task.id)
        }
        let data = try Data(contentsOf: task.directoryURL.appendingPathComponent("task.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(TaskManifest.self, from: data)
        guard manifest.id == task.id else {
            throw TaskRepositoryError.taskIdentityMismatch(
                directoryName: task.id,
                manifestID: manifest.id
            )
        }
        return manifest
    }

    private func ensureUniqueSlugWhileRepositoryLocked(_ slug: String, excludingID: String?) throws {
        let matches = try loader.loadTasks(includeRuns: false).filter { task in
            task.manifest.slug == slug && task.id != excludingID
        }
        guard matches.isEmpty else {
            throw TaskRepositoryError.conflict("slug 已被使用：\(slug)")
        }
    }

    private func nonEmpty(_ value: String?, field: String) throws -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TaskRepositoryError.missingRequiredField(field)
        }
        return trimmed
    }

    private func normalizedTaskID(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: trimmed) != nil else {
            throw TaskRepositoryError.invalidTaskID(value)
        }
        return trimmed
    }

    private func normalizedSlug(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let pattern = #"^[a-z0-9][a-z0-9._-]{0,62}$"#
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        let regex = try! NSRegularExpression(pattern: pattern)
        guard regex.firstMatch(in: trimmed, range: range) != nil else {
            throw TaskRepositoryError.invalidSlug(value)
        }
        if ["status", "log", "cancel", "stop"].contains(trimmed) {
            throw TaskRepositoryError.reservedSlug(trimmed)
        }
        return trimmed
    }

    private func validatedSchedule(_ schedule: TaskSchedule) throws -> TaskSchedule {
        if let error = schedule.validationError {
            throw TaskRepositoryError.invalidSchedule(error.localizedDescription)
        }
        return schedule
    }

    private func normalizedScript(_ script: String?) -> String {
        let trimmed = (script ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return """
            #!/bin/zsh
            set -euo pipefail

            # Write your script here
            """
        }
        return TaskFileStore.normalizedTemplateScript(script ?? "")
    }
}
