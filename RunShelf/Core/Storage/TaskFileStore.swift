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
        let manifestData = try Data(contentsOf: directoryURL.appendingPathComponent("task.json"))
        let manifest = try decoder.decode(TaskManifest.self, from: manifestData)
        guard manifest.schemaVersion == 1 else {
            throw CocoaError(.fileReadUnknown, userInfo: [
                NSLocalizedDescriptionKey: "不支持的 schemaVersion：\(manifest.schemaVersion)"
            ])
        }

        let scriptURL = directoryURL.appendingPathComponent("run.sh")
        guard fileManager.fileExists(atPath: scriptURL.path) else {
            throw NSError(domain: "RunShelf", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "任务缺少 run.sh：\(directoryURL.lastPathComponent)"
            ])
        }

        return RunShelfTask(
            manifest: manifest,
            directoryURL: directoryURL,
            script: Self.normalizedTemplateScript(readText(at: scriptURL)),
            notes: readText(at: directoryURL.appendingPathComponent("notes.md")),
            runs: includeRuns ? loadRuns(for: directoryURL) : [],
            isDirty: false
        )
    }

    /// 把旧版本（typo / 中文注释）的模板脚本统一成标准 placeholder。
    /// 之前只在 TaskStore 内调，挪到这里让 scheduler 进程也用同一套加载语义。
    static func normalizedTemplateScript(_ script: String) -> String {
        script
            .replacingOccurrences(of: "# Write your xscript here", with: "# Write your script here")
            .replacingOccurrences(of: "# 在这里写脚本", with: "# Write your script here")
    }

    func loadRuns(for taskDirectoryURL: URL) -> [RunRecord] {
        let runsURL = taskDirectoryURL.appendingPathComponent("runs", isDirectory: true)
        guard let runDirectories = try? fileManager.contentsOfDirectory(
            at: runsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let claimTask = taskForRunClaim(at: taskDirectoryURL)

        return runDirectories.compactMap { runDirectory -> RunRecord? in
            guard isDirectory(runDirectory) else { return nil }
            let metaURL = runDirectory.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL) else { return nil }
            guard let record = try? decoder.decode(RunRecord.self, from: data) else { return nil }
            return reconcileRunningRecord(record, metaURL: metaURL, claimTask: claimTask)
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    private func reconcileRunningRecord(
        _ record: RunRecord,
        metaURL: URL,
        claimTask: RunShelfTask?
    ) -> RunRecord {
        guard record.status == .running, let claimTask else { return record }
        let activeClaim = TaskRunClaimManager.activeClaim(for: claimTask, fileManager: fileManager)
        guard activeClaim?.runId != record.runId else { return record }

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
              let manifest = try? decoder.decode(TaskManifest.self, from: manifestData)
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

    private func writeRunRecord(_ record: RunRecord, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: url, options: [.atomic])
    }

    private func readText(at url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
