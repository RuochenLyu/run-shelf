import AppKit
import Combine
import Foundation

enum RunLogKind: String, CaseIterable, Identifiable {
    case combined
    case stdout
    case stderr

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .combined: return "合并"
        case .stdout: return "stdout"
        case .stderr: return "stderr"
        }
    }
}

@MainActor
final class TaskStore: ObservableObject {
    @Published private(set) var tasks: [RunShelfTask] = []
    @Published var selectedTaskID: String? {
        didSet {
            if oldValue != selectedTaskID {
                if let oldValue {
                    setScheduleDraftValidity(taskID: oldValue, isValid: true)
                }
                selectedRunID = nil
            }
        }
    }
    @Published var selectedRunID: String?
    @Published private(set) var runningTaskIDs: Set<String> = []
    @Published private var invalidScheduleDraftTaskIDs: Set<String> = []
    @Published var lastErrorMessage: String?

    let tasksDirectoryURL: URL

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        tasksDirectoryURL: URL = TaskStore.defaultTasksDirectoryURL(),
        fileManager: FileManager = .default
    ) {
        self.tasksDirectoryURL = tasksDirectoryURL
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        loadTasks()
    }

    nonisolated static func defaultTasksDirectoryURL() -> URL {
        RunShelfPaths.tasksDirectoryURL()
    }

    var sortedTasks: [RunShelfTask] {
        tasks.sorted { lhs, rhs in
            let lhsRank = statusRank(lhs)
            let rhsRank = statusRank(rhs)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhs.manifest.name.localizedStandardCompare(rhs.manifest.name) == .orderedAscending
        }
    }

    var selectedTask: RunShelfTask? {
        guard let selectedTaskID else { return nil }
        return task(withID: selectedTaskID)
    }

    func task(withID id: String) -> RunShelfTask? {
        tasks.first { $0.id == id }
    }

    func loadTasks() {
        do {
            try ensureTasksDirectory()
            try seedExamplesIfNeeded()

            let taskDirectories = try fileManager.contentsOfDirectory(
                at: tasksDirectoryURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            var loadedTasks: [RunShelfTask] = []
            for directory in taskDirectories {
                guard isDirectory(directory) else { continue }
                guard directory.lastPathComponent != "trash" else { continue }

                do {
                    loadedTasks.append(try loadTask(at: directory))
                } catch {
                    lastErrorMessage = "无法读取任务 \(directory.lastPathComponent)：\(error.localizedDescription)"
                }
            }

            tasks = loadedTasks
            invalidScheduleDraftTaskIDs.formIntersection(Set(loadedTasks.map(\.id)))
            if selectedTaskID == nil || task(withID: selectedTaskID ?? "") == nil {
                selectedTaskID = sortedTasks.first?.id
            }
        } catch {
            lastErrorMessage = "无法加载任务目录：\(error.localizedDescription)"
        }
    }

    func refreshRunsFromDisk() {
        var refreshedTasks = tasks
        for index in refreshedTasks.indices {
            refreshedTasks[index].runs = loadRuns(for: refreshedTasks[index].directoryURL)
        }

        if refreshedTasks != tasks {
            tasks = refreshedTasks
        }
    }

    @discardableResult
    func createTask(
        from template: TaskTemplate,
        name: String? = nil,
        scheduleExpression: String? = nil
    ) -> String? {
        do {
            let manifestName = normalizedName(name, fallback: template.name)
            var schedule = template.defaultSchedule
            if let expr = scheduleExpression?.trimmingCharacters(in: .whitespacesAndNewlines), !expr.isEmpty {
                schedule.expression = expr
            }
            let task = try makeTask(
                from: template,
                name: manifestName,
                enabled: template.enabledByDefault,
                schedule: schedule
            )
            tasks.append(task)
            selectedTaskID = task.id
            return task.id
        } catch {
            lastErrorMessage = "无法创建任务：\(error.localizedDescription)"
            return nil
        }
    }

    func updateTask(id: String, mutate: (inout RunShelfTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let originalTask = tasks[index]
        mutate(&tasks[index])
        if tasks[index] != originalTask {
            tasks[index].manifest.updatedAt = Date()
            tasks[index].isDirty = true
        }
    }

    @discardableResult
    func saveTask(id: String) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return false }
        guard validateScheduleBeforePersisting(tasks[index]) else {
            return false
        }

        do {
            tasks[index].manifest.updatedAt = Date()
            try writeTask(tasks[index])
            tasks[index].isDirty = false
            return true
        } catch {
            lastErrorMessage = "无法保存任务：\(error.localizedDescription)"
            return false
        }
    }

    func revertTask(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        do {
            tasks[index] = try loadTask(at: tasks[index].directoryURL)
            setScheduleDraftValidity(taskID: id, isValid: true)
        } catch {
            lastErrorMessage = "无法放弃更改：\(error.localizedDescription)"
        }
    }

    func deleteTask(id: String) {
        guard !runningTaskIDs.contains(id), let index = tasks.firstIndex(where: { $0.id == id }) else {
            lastErrorMessage = "运行中的任务不能删除。"
            return
        }

        let task = tasks[index]
        do {
            var resultingURL: NSURL?
            try fileManager.trashItem(at: task.directoryURL, resultingItemURL: &resultingURL)
            tasks.remove(at: index)
            setScheduleDraftValidity(taskID: id, isValid: true)
            selectedTaskID = sortedTasks.first?.id
        } catch {
            do {
                let trashURL = tasksDirectoryURL.appendingPathComponent("trash", isDirectory: true)
                try fileManager.createDirectory(at: trashURL, withIntermediateDirectories: true)
                let destination = trashURL.appendingPathComponent(task.id + "-" + UUID().uuidString, isDirectory: true)
                try fileManager.moveItem(at: task.directoryURL, to: destination)
                tasks.remove(at: index)
                setScheduleDraftValidity(taskID: id, isValid: true)
                selectedTaskID = sortedTasks.first?.id
            } catch {
                lastErrorMessage = "无法删除任务：\(error.localizedDescription)"
            }
        }
    }

    func runTask(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard !runningTaskIDs.contains(id) else { return }
        guard saveTask(id: id) else { return }

        let task = tasks[index]
        runningTaskIDs.insert(id)

        Task.detached(priority: .userInitiated) {
            let result = Result { try TaskRunner.run(task: task, trigger: .manual) }

            await MainActor.run {
                self.runningTaskIDs.remove(id)
                switch result {
                case .success(let run):
                    if run.status == .failed || run.status == .timeout {
                        RunShelfNotifier.notifyFailure(task: task, run: run)
                    }
                    self.refreshRuns(for: id)
                case .failure(let error):
                    self.lastErrorMessage = "任务运行失败：\(error.localizedDescription)"
                    self.refreshRuns(for: id)
                }
            }
        }
    }

    func setScheduleDraftValidity(taskID: String, isValid: Bool) {
        var next = invalidScheduleDraftTaskIDs
        if isValid {
            next.remove(taskID)
        } else {
            next.insert(taskID)
        }

        if next != invalidScheduleDraftTaskIDs {
            invalidScheduleDraftTaskIDs = next
        }
    }

    func isScheduleDraftValid(taskID: String) -> Bool {
        !invalidScheduleDraftTaskIDs.contains(taskID)
    }

    func canSaveTask(_ task: RunShelfTask) -> Bool {
        task.isDirty && canPersistTask(task)
    }

    func canRunTask(_ task: RunShelfTask) -> Bool {
        !runningTaskIDs.contains(task.id) && canPersistTask(task)
    }

    private func canPersistTask(_ task: RunShelfTask) -> Bool {
        task.hasValidSchedule && isScheduleDraftValid(taskID: task.id)
    }

    private func validateScheduleBeforePersisting(_ task: RunShelfTask) -> Bool {
        if let error = task.manifest.schedule.validationError {
            lastErrorMessage = "无法保存任务：\(error.localizedDescription)"
            return false
        }

        guard isScheduleDraftValid(taskID: task.id) else {
            lastErrorMessage = "无法保存任务：请先修正执行计划。"
            return false
        }

        return true
    }

    func openTasksDirectory() {
        NSWorkspace.shared.activateFileViewerSelecting([tasksDirectoryURL])
    }

    func openTaskDirectory(id: String) {
        guard let task = task(withID: id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([task.directoryURL])
    }

    func logText(for task: RunShelfTask, run: RunRecord?, kind: RunLogKind) -> String {
        guard let run else { return "暂无日志" }
        let runURL = task.directoryURL
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(run.runId, isDirectory: true)
        let stdoutURL = runURL.appendingPathComponent(run.stdoutPath)
        let stderrURL = runURL.appendingPathComponent(run.stderrPath)

        switch kind {
        case .stdout:
            return readText(at: stdoutURL)
        case .stderr:
            return readText(at: stderrURL)
        case .combined:
            let stdout = readText(at: stdoutURL)
            let stderr = readText(at: stderrURL)
            return """
            # stdout
            \(stdout.isEmpty ? "无输出" : stdout)

            # stderr
            \(stderr.isEmpty ? "无输出" : stderr)
            """
        }
    }

    private func ensureTasksDirectory() throws {
        try fileManager.createDirectory(at: tasksDirectoryURL, withIntermediateDirectories: true)
    }

    private func seedExamplesIfNeeded() throws {
        guard !fileManager.fileExists(atPath: exampleSeedMarkerURL.path) else { return }

        let contents = try fileManager.contentsOfDirectory(
            at: tasksDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let hasTaskDirectories = contents.contains { url in
            isDirectory(url) && url.lastPathComponent != "trash"
        }
        guard !hasTaskDirectories else {
            try markExamplesSeeded()
            return
        }

        for template in TaskTemplate.examples {
            _ = try makeTask(from: template, name: template.name, enabled: false)
        }
        try markExamplesSeeded()
    }

    private var exampleSeedMarkerURL: URL {
        tasksDirectoryURL.appendingPathComponent(".examples-seeded")
    }

    private func markExamplesSeeded() throws {
        try "seeded\n".write(to: exampleSeedMarkerURL, atomically: true, encoding: .utf8)
    }

    private func makeTask(
        from template: TaskTemplate,
        name: String,
        enabled: Bool,
        schedule: TaskSchedule? = nil
    ) throws -> RunShelfTask {
        let id = UUID().uuidString
        let directoryURL = tasksDirectoryURL.appendingPathComponent(id, isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: directoryURL.appendingPathComponent("runs", isDirectory: true), withIntermediateDirectories: true)

        let manifest = TaskManifest.create(
            id: id,
            name: name,
            description: template.description,
            enabled: enabled,
            schedule: schedule ?? template.defaultSchedule
        )
        let task = RunShelfTask(
            manifest: manifest,
            directoryURL: directoryURL,
            script: template.script,
            notes: template.notes,
            runs: [],
            isDirty: false
        )
        try writeTask(task)
        return task
    }

    private func loadTask(at directoryURL: URL) throws -> RunShelfTask {
        let manifestData = try Data(contentsOf: directoryURL.appendingPathComponent("task.json"))
        let manifest = try decoder.decode(TaskManifest.self, from: manifestData)
        guard manifest.schemaVersion == 1 else {
            throw CocoaError(.fileReadUnknown, userInfo: [
                NSLocalizedDescriptionKey: "不支持的 schemaVersion：\(manifest.schemaVersion)"
            ])
        }

        let script = normalizedTemplateScript(readText(at: directoryURL.appendingPathComponent("run.sh")))
        let notes = readText(at: directoryURL.appendingPathComponent("notes.md"))
        let runs = loadRuns(for: directoryURL)

        return RunShelfTask(
            manifest: manifest,
            directoryURL: directoryURL,
            script: script,
            notes: notes,
            runs: runs,
            isDirty: false
        )
    }

    private func writeTask(_ task: RunShelfTask) throws {
        try fileManager.createDirectory(at: task.directoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: task.directoryURL.appendingPathComponent("runs", isDirectory: true), withIntermediateDirectories: true)

        let manifestData = try encoder.encode(task.manifest)
        try manifestData.write(to: task.directoryURL.appendingPathComponent("task.json"), options: [.atomic])

        try task.script.write(
            to: task.directoryURL.appendingPathComponent("run.sh"),
            atomically: true,
            encoding: .utf8
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: task.directoryURL.appendingPathComponent("run.sh").path
        )

        try task.notes.write(
            to: task.directoryURL.appendingPathComponent("notes.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func refreshRuns(for id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].runs = loadRuns(for: tasks[index].directoryURL)
    }

    private func loadRuns(for taskDirectoryURL: URL) -> [RunRecord] {
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

    private func statusRank(_ task: RunShelfTask) -> Int {
        if runningTaskIDs.contains(task.id) { return 0 }
        if task.latestRun?.status == .failed || task.latestRun?.status == .timeout { return 1 }
        if task.manifest.enabled { return 2 }
        return 3
    }

    private func readText(at url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func normalizedName(_ name: String?, fallback: String) -> String {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func normalizedTemplateScript(_ script: String) -> String {
        script
            .replacingOccurrences(of: "# Write your xscript here", with: "# Write your script here")
            .replacingOccurrences(of: "# 在这里写脚本", with: "# Write your script here")
    }
}
