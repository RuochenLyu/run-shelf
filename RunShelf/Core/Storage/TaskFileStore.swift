import Foundation

struct TaskLoadIssue: Equatable {
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

    func loadTasks() throws -> [RunShelfTask] {
        try loadTasksWithIssues().tasks
    }

    func loadTasksWithIssues() throws -> TaskLoadResult {
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
                tasks.append(try loadTask(at: directory))
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

    func loadTask(at directoryURL: URL) throws -> RunShelfTask {
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
            script: readText(at: scriptURL),
            notes: readText(at: directoryURL.appendingPathComponent("notes.md")),
            runs: loadRuns(for: directoryURL),
            isDirty: false
        )
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

        return runDirectories.compactMap { runDirectory -> RunRecord? in
            guard isDirectory(runDirectory) else { return nil }
            let metaURL = runDirectory.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL) else { return nil }
            return try? decoder.decode(RunRecord.self, from: data)
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    private func readText(at url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
