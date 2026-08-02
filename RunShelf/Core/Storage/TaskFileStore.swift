import Foundation

struct TaskLoadIssue: Codable, Equatable, Sendable {
    var directoryName: String
    var errorDescription: String

    var logMessage: String {
        "无法读取任务 \(directoryName)：\(errorDescription)"
    }
}

struct TaskLoadResult: Equatable {
    var tasks: [RunShelfTask]
    var issues: [TaskLoadIssue]
}

struct TaskFileStore {
    var tasksDirectoryURL: URL = RunShelfPaths.tasksDirectoryURL()
    var fileManager: FileManager = .default

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func loadTasks(includeRuns: Bool = true) throws -> [RunShelfTask] {
        try loadTasksWithIssues(includeRuns: includeRuns).tasks
    }

    func loadTasksWithIssues(includeRuns: Bool = true) throws -> TaskLoadResult {
        try fileManager.createDirectory(at: tasksDirectoryURL, withIntermediateDirectories: true)
        let directories = try fileManager.contentsOfDirectory(
            at: tasksDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var tasks: [RunShelfTask] = []
        var issues: [TaskLoadIssue] = []

        for directory in directories {
            guard isDirectory(directory), directory.lastPathComponent != "trash" else { continue }
            do {
                tasks.append(try loadTask(at: directory, includeRuns: includeRuns))
            } catch {
                issues.append(TaskLoadIssue(
                    directoryName: directory.lastPathComponent,
                    errorDescription: error.localizedDescription
                ))
            }
        }

        return TaskLoadResult(
            tasks: tasks.sorted { $0.manifest.name.localizedStandardCompare($1.manifest.name) == .orderedAscending },
            issues: issues
        )
    }

    func loadTask(at directoryURL: URL, includeRuns: Bool = true) throws -> RunShelfTask {
        let directoryName = directoryURL.lastPathComponent
        return try TaskDefinitionFileLock.withLock(
            tasksDirectoryURL: directoryURL.deletingLastPathComponent(),
            taskID: directoryName,
            mode: .shared,
            fileManager: fileManager
        ) {
            guard UUID(uuidString: directoryName) != nil else {
                throw TaskRepositoryError.invalidTaskID(directoryName)
            }

            let manifestData = try Data(contentsOf: directoryURL.appendingPathComponent("task.json"))
            let manifest = try decodePersistedManifest(from: manifestData)
            guard manifest.id == directoryName else {
                throw TaskRepositoryError.taskIdentityMismatch(
                    directoryName: directoryName,
                    manifestID: manifest.id
                )
            }
            guard manifest.schemaVersion == 1 else {
                throw CocoaError(.fileReadUnknown, userInfo: [
                    NSLocalizedDescriptionKey: "不支持的 schemaVersion：\(manifest.schemaVersion)"
                ])
            }

            let scriptURL = directoryURL.appendingPathComponent("run.sh")
            guard fileManager.fileExists(atPath: scriptURL.path) else {
                throw NSError(domain: "RunShelf", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "任务缺少 run.sh：\(directoryName)"
                ])
            }

            return RunShelfTask(
                manifest: manifest,
                directoryURL: directoryURL,
                script: Self.normalizedTemplateScript(try readRequiredText(at: scriptURL)),
                notes: try readOptionalText(at: directoryURL.appendingPathComponent("notes.md")),
                runs: includeRuns ? loadRuns(for: directoryURL) : [],
                isDirty: false
            )
        }
    }

    /// 把旧版本（typo / 中文注释）的模板脚本统一成标准 placeholder。
    /// 之前只在 TaskStore 内调，挪到这里让 scheduler 进程也用同一套加载语义。
    static func normalizedTemplateScript(_ script: String) -> String {
        script
            .replacingOccurrences(of: "# Write your xscript here", with: "# Write your script here")
            .replacingOccurrences(of: "# 在这里写脚本", with: "# Write your script here")
    }

    func loadRuns(for taskDirectoryURL: URL, limit: Int? = nil) -> [RunRecord] {
        if let limit, limit <= 0 { return [] }
        let runsURL = taskDirectoryURL.appendingPathComponent("runs", isDirectory: true)
        guard let runDirectories = try? fileManager.contentsOfDirectory(
            at: runsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let claimTask = taskForRunClaim(at: taskDirectoryURL)

        let sortedDirectories = runDirectories.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending
        }
        var records: [RunRecord] = []
        for runDirectory in sortedDirectories {
            guard isDirectory(runDirectory) else { continue }
            let metaURL = runDirectory.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let record = try? decoder.decode(RunRecord.self, from: data)
            else {
                continue
            }
            records.append(reconcileRunningRecord(record, metaURL: metaURL, claimTask: claimTask))
            if let limit, records.count >= max(limit, 0) {
                break
            }
        }
        return records.sorted { $0.startedAt > $1.startedAt }
    }

    func loadLatestRun(for taskDirectoryURL: URL) -> RunRecord? {
        loadRuns(for: taskDirectoryURL, limit: 1).first
    }

    func loadRun(for taskDirectoryURL: URL, runID: String) throws -> RunRecord? {
        guard Self.isSafeRunID(runID) else {
            throw TaskRepositoryError.conflict("run id 不合法：\(runID)")
        }
        let runURL = taskDirectoryURL
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
        let metaURL = runURL.appendingPathComponent("meta.json")
        guard fileManager.fileExists(atPath: metaURL.path) else { return nil }
        let data = try Data(contentsOf: metaURL)
        let record = try decoder.decode(RunRecord.self, from: data)
        guard record.runId == runID else {
            throw TaskRepositoryError.conflict("运行目录与 meta 身份不一致：\(runID)")
        }
        return reconcileRunningRecord(
            record,
            metaURL: metaURL,
            claimTask: taskForRunClaim(at: taskDirectoryURL)
        )
    }

    static func isSafeRunID(_ runID: String) -> Bool {
        guard !runID.isEmpty, runID != ".", runID != "..", runID.count <= 160 else { return false }
        return runID.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "._-+".unicodeScalars.contains($0)
        }
    }

    private func reconcileRunningRecord(
        _ record: RunRecord,
        metaURL: URL,
        claimTask: RunShelfTask?
    ) -> RunRecord {
        guard record.status == .running, let claimTask else { return record }
        let activeClaim = TaskRunClaimManager.activeClaim(
            for: claimTask,
            runID: record.runId,
            fileManager: fileManager
        )
        guard activeClaim == nil else { return record }

        let endedAt = Date()
        var stale = record
        stale.status = .stale
        stale.endedAt = endedAt
        stale.durationMs = Int(endedAt.timeIntervalSince(record.startedAt) * 1000)
        stale.message = stale.message ?? "运行宿主已不存在，本次运行已标记为 stale。"
        try? writeRunRecord(stale, to: metaURL)
        return stale
    }

    private func taskForRunClaim(at directoryURL: URL) -> RunShelfTask? {
        guard let manifestData = try? Data(contentsOf: directoryURL.appendingPathComponent("task.json")),
              let manifest = try? decodePersistedManifest(from: manifestData)
        else {
            return nil
        }
        return RunShelfTask(
            manifest: manifest,
            directoryURL: directoryURL,
            script: "",
            notes: "",
            runs: [],
            isDirty: false
        )
    }

    private func decodePersistedManifest(from data: Data) throws -> TaskManifest {
        var manifest = try decoder.decode(TaskManifest.self, from: data)
        // schemaVersion 1 historically accepted arbitrary timezone strings while
        // the scheduler always evaluated cron expressions in the Mac's local
        // timezone. Canonicalize those persisted values on read so an existing
        // task remains editable and the next save records the real semantics.
        if manifest.schemaVersion == 1, manifest.schedule.timezone != "local" {
            manifest.schedule.timezone = "local"
        }
        return manifest
    }

    private func writeRunRecord(_ record: RunRecord, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: url, options: [.atomic])
    }

    private func readRequiredText(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func readOptionalText(at url: URL) throws -> String {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return ""
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
