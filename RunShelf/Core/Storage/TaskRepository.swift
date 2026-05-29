import Foundation

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
    var script: String? = nil
    var notes: String? = nil
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
    case invalidSchedule(String)
    case invalidTaskID(String)
    case invalidRevision(String)
    case missingRequiredField(String)
    case taskDirectoryMissing(String)

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
        case .invalidSchedule(let message):
            return "执行计划不合法：\(message)"
        case .invalidTaskID(let taskID):
            return "任务 id 不合法：\(taskID)"
        case .invalidRevision(let revision):
            return "revision 不合法：\(revision)"
        case .missingRequiredField(let field):
            return "缺少必填字段：\(field)"
        case .taskDirectoryMissing(let taskID):
            return "任务目录已不存在：\(taskID)"
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

    func loadTask(selector: TaskRepositorySelector, includeRuns: Bool = true) throws -> TaskRepositoryReadResult {
        let task = try resolve(selector: selector, includeRuns: includeRuns)
        return try loadTaskConsistently(at: task.directoryURL, includeRuns: includeRuns)
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

    func createTask(from spec: TaskSpec) throws -> TaskRepositoryWriteResult {
        let id = try normalizedTaskID(spec.id ?? UUID().uuidString)
        let directoryURL = tasksDirectoryURL.appendingPathComponent(id, isDirectory: true)
        guard !fileManager.fileExists(atPath: directoryURL.path) else {
            throw TaskRepositoryError.conflict("任务目录已存在：\(id)")
        }

        let name = try nonEmpty(spec.name, field: "name")
        let slug = try normalizedSlug(spec.slug)
        if let slug {
            try ensureUniqueSlug(slug, excludingID: nil)
        }
        let schedule = try validatedSchedule(spec.schedule ?? .defaultDaily)
        var manifest = TaskManifest.create(
            id: id,
            slug: slug,
            name: name,
            description: spec.description ?? "",
            enabled: spec.enabled ?? true,
            schedule: schedule
        )
        manifest.runner.timeoutSeconds = max(spec.timeoutSeconds ?? manifest.runner.timeoutSeconds, 0)

        let task = RunShelfTask(
            manifest: manifest,
            directoryURL: directoryURL,
            script: normalizedScript(spec.script),
            notes: spec.notes ?? "",
            runs: [],
            isDirty: false
        )
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: false)
        try writeTask(task, expectedRevision: nil)
        let read = try loadTaskConsistently(at: directoryURL)
        return TaskRepositoryWriteResult(task: read.task, revision: read.revision)
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
            if let slug {
                try ensureUniqueSlug(slug, excludingID: task.id)
            }
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
        if let script = spec.script {
            task.script = TaskFileStore.normalizedTemplateScript(script)
        }
        if let notes = spec.notes {
            task.notes = notes
        }
        task.manifest.updatedAt = Date()
        task.isDirty = false

        try writeTask(task, expectedRevision: expectedRevision ?? read.revision)
        let updated = try loadTaskConsistently(at: task.directoryURL)
        return TaskRepositoryWriteResult(task: updated.task, revision: updated.revision)
    }

    func writeTask(_ task: RunShelfTask, expectedRevision: TaskDefinitionRevision? = nil) throws {
        guard fileManager.fileExists(atPath: task.directoryURL.path) else {
            throw TaskRepositoryError.taskDirectoryMissing(task.id)
        }

        if task.directoryURL.lastPathComponent != task.id {
            throw TaskRepositoryError.invalidTaskID(task.id)
        }

        if let expectedRevision {
            let currentRevision = TaskDefinitionRevision.capture(for: task.directoryURL)
            guard currentRevision == expectedRevision else {
                throw TaskRepositoryError.conflict("任务文件已被其他进程修改，请重新读取后再保存。")
            }
        }

        _ = try validatedSchedule(task.manifest.schedule)
        if let slug = task.manifest.slug {
            _ = try normalizedSlug(slug)
        }

        try fileManager.createDirectory(
            at: task.directoryURL.appendingPathComponent("runs", isDirectory: true),
            withIntermediateDirectories: true
        )

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
    }

    func deleteTask(selector: TaskRepositorySelector) throws -> String {
        let read = try loadTask(selector: selector, includeRuns: false)
        let task = read.task

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
            throw TaskRepositoryError.conflict("timeoutSeconds 不能小于 0。")
        }
        return DangerousCommandScanner.scan(spec.script ?? "")
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

    private func ensureUniqueSlug(_ slug: String, excludingID: String?) throws {
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
