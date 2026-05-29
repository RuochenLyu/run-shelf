import AppKit
import Combine
import Foundation

enum RunLogKind: String, CaseIterable, Identifiable {
    case stdout
    case stderr

    var id: String { rawValue }

    var displayName: String {
        switch self {
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
    @Published private(set) var runningStartedAt: [String: Date] = [:]
    @Published private var invalidScheduleDraftTaskIDs: Set<String> = []
    @Published var lastErrorMessage: String?

    let tasksDirectoryURL: URL

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let diskLoader: TaskFileStore
    private let repository: TaskRepository

    // 异步 refresh 的状态：
    // - generations: 每个任务的 epoch，每次 mutation 都 +1；
    //   后台 scan 启动时打快照，apply 时比较 → 不一致就降级 runsOnly merge，
    //   避免 scan 期间用户保存的版本被旧 scan 结果回滚。
    // - signatureCache: 上次成功 scan 时的 file signature（task.json/run.sh/notes.md 各自 mtime+size），
    //   任一变化就 fullReload，否则只刷 runs。
    // - isRefreshingFromDisk: 重入保护，避免两个 detached scan 同时跑。
    private var taskGenerations: [String: Int] = [:]
    private var signatureCache: [String: TaskFileSignature] = [:]
    private var isRefreshingFromDisk = false
    private var runningCancellations: [String: TaskRunCancellation] = [:]

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

        self.diskLoader = TaskFileStore(tasksDirectoryURL: tasksDirectoryURL, fileManager: fileManager)
        self.repository = TaskRepository(tasksDirectoryURL: tasksDirectoryURL, fileManager: fileManager)

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
        loadTasks(includeRuns: false)
        refreshRunsFromDisk()
    }

    private func loadTasks(includeRuns: Bool) {
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
                    loadedTasks.append(try loadTask(at: directory, includeRuns: includeRuns))
                } catch {
                    lastErrorMessage = "无法读取任务 \(directory.lastPathComponent)：\(error.localizedDescription)"
                }
            }

            tasks = loadedTasks
            invalidScheduleDraftTaskIDs.formIntersection(Set(loadedTasks.map(\.id)))
            // 初始化 epoch 与 signature cache，让首次 refresh 能正确比较
            taskGenerations = Dictionary(uniqueKeysWithValues: loadedTasks.map { ($0.id, 0) })
            signatureCache = Dictionary(uniqueKeysWithValues: loadedTasks.map { task in
                (task.id, TaskFileSignature.capture(for: task.directoryURL))
            })
            if selectedTaskID == nil || task(withID: selectedTaskID ?? "") == nil {
                selectedTaskID = sortedTasks.first?.id
            }
        } catch {
            lastErrorMessage = "无法加载任务目录：\(error.localizedDescription)"
        }
    }

    /// 入口签名不变。内部把磁盘 IO 搬到后台线程，避免阻塞 UI。
    /// 重入保护：上一轮 scan 还没完成时直接跳过本次触发（避免 polling 雪崩）。
    func refreshRunsFromDisk() {
        guard !isRefreshingFromDisk else { return }
        isRefreshingFromDisk = true

        let input = DiskScanInput(
            tasksDirectoryURL: tasksDirectoryURL,
            knownTasks: tasks.map { task in
                DiskScanInput.KnownTask(
                    id: task.id,
                    directoryURL: task.directoryURL,
                    isDirty: task.isDirty,
                    generation: taskGenerations[task.id] ?? 0
                )
            },
            signatureCache: signatureCache
        )

        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                DiskScanner.scan(input)
            }.value
            guard !Task.isCancelled else {
                self?.isRefreshingFromDisk = false
                return
            }
            self?.applyDiskScan(result)
        }
    }

    /// MainActor 上把后台 scan 结果合并进 store。
    /// 关键不变量：
    /// - fullReload 必须 generation 一致 + 当前 clean 才能覆盖；否则降级 runsOnly merge
    /// - dirty 任务永远只更新 runs 字段
    /// - 删除只清 clean 任务，dirty 草稿保留让 saveTask 失败让用户感知
    private func applyDiskScan(_ result: DiskScanResult) {
        defer { isRefreshingFromDisk = false }

        for entry in result.entries {
            switch entry {
            case let .fullReload(diskTask, scanGeneration):
                if let index = tasks.firstIndex(where: { $0.id == diskTask.id }) {
                    let currentGeneration = taskGenerations[diskTask.id] ?? 0
                    if currentGeneration == scanGeneration && !tasks[index].isDirty {
                        tasks[index] = diskTask
                    } else {
                        // Race: scan 期间用户改了/保存了。只 merge runs，
                        // manifest/script/notes 保留内存版本（用户最新意图）
                        tasks[index].runs = mergedRuns(existing: tasks[index].runs, incoming: diskTask.runs)
                    }
                } else {
                    // 磁盘上新出现的任务（外部恢复 / sync / scheduler 直写不太可能但 defensive）
                    tasks.append(diskTask)
                    taskGenerations[diskTask.id] = 0
                }

            case let .runsOnly(taskID, runs, scanGeneration):
                guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { continue }
                let currentGeneration = taskGenerations[taskID] ?? 0
                if currentGeneration == scanGeneration && !tasks[index].isDirty {
                    tasks[index].runs = runs
                } else {
                    tasks[index].runs = mergedRuns(existing: tasks[index].runs, incoming: runs)
                }
            }
        }

        for id in result.deletedTaskIDs {
            guard let index = tasks.firstIndex(where: { $0.id == id }), !tasks[index].isDirty else {
                continue
            }
            tasks.remove(at: index)
            taskGenerations.removeValue(forKey: id)
        }

        // 更新 signature 缓存 + 清掉已不存在任务的 cache
        let aliveIDs = Set(tasks.map(\.id))
        for (id, sig) in result.newSignatures where aliveIDs.contains(id) {
            signatureCache[id] = sig
        }
        signatureCache = signatureCache.filter { aliveIDs.contains($0.key) }

        if let sel = selectedTaskID, !tasks.contains(where: { $0.id == sel }) {
            selectedTaskID = sortedTasks.first?.id
        }

        if let firstError = result.errors.first {
            lastErrorMessage = firstError
        }
    }

    /// 用户编辑/保存/创建/恢复任务时调用，让后台 scan 的 apply 能识别"我看到的版本是旧的"。
    private func bumpGeneration(_ taskID: String) {
        taskGenerations[taskID, default: 0] += 1
    }

    private func mergedRuns(existing: [RunRecord], incoming: [RunRecord]) -> [RunRecord] {
        var merged = Dictionary(uniqueKeysWithValues: existing.map { ($0.runId, $0) })
        for run in incoming {
            merged[run.runId] = run
        }
        return merged.values.sorted { $0.startedAt > $1.startedAt }
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
            taskGenerations[task.id] = 0
            signatureCache[task.id] = TaskFileSignature.capture(for: task.directoryURL)
            selectedTaskID = task.id
            return task.id
        } catch {
            lastErrorMessage = "无法创建任务：\(error.localizedDescription)"
            return nil
        }
    }

    func updateTask(id: String, mutate: (inout RunShelfTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }

        // 若当前任务是 clean 的，先把磁盘最新版 reload 进内存再 mutate；
        // 防止「右键切启停」这种 manifest-only 操作把过时的 script/notes 写回磁盘
        // （writeTask 是整 task 级别的写，会重写 task.json / run.sh / notes.md）。
        if !tasks[index].isDirty {
            do {
                let reloaded = try loadTaskDefinitionPreservingRuns(at: index)
                tasks[index] = reloaded
                bumpGeneration(id)
                signatureCache[id] = TaskFileSignature.capture(for: tasks[index].directoryURL)
            } catch {
                lastErrorMessage = taskLoadFailureMessage(directoryURL: tasks[index].directoryURL, error: error)
                return
            }
        }

        let originalTask = tasks[index]
        mutate(&tasks[index])
        if tasks[index] != originalTask {
            tasks[index].manifest.updatedAt = Date()
            tasks[index].isDirty = true
            bumpGeneration(id)
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
            let expectedRevision = signatureCache[id].map { TaskDefinitionRevision(signature: $0) }
            try writeTask(tasks[index], expectedRevision: expectedRevision)
            tasks[index].isDirty = false
            // 写盘成功 → bump generation + 更新 signature cache，
            // 让正在跑的 detached scan apply 时能识别"内存版本已经领先于它看到的"
            bumpGeneration(id)
            signatureCache[id] = TaskFileSignature.capture(for: tasks[index].directoryURL)
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
            bumpGeneration(id)
            signatureCache[id] = TaskFileSignature.capture(for: tasks[index].directoryURL)
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
            taskGenerations.removeValue(forKey: id)
            signatureCache.removeValue(forKey: id)
            setScheduleDraftValidity(taskID: id, isValid: true)
            NotificationCenter.default.post(
                name: .runShelfTaskDeleted,
                object: nil,
                userInfo: [RunShelfNotificationUserInfoKey.taskID: id]
            )
            selectedTaskID = sortedTasks.first?.id
        } catch {
            do {
                let trashURL = tasksDirectoryURL.appendingPathComponent("trash", isDirectory: true)
                try fileManager.createDirectory(at: trashURL, withIntermediateDirectories: true)
                let destination = trashURL.appendingPathComponent(task.id + "-" + UUID().uuidString, isDirectory: true)
                try fileManager.moveItem(at: task.directoryURL, to: destination)
                tasks.remove(at: index)
                taskGenerations.removeValue(forKey: id)
                signatureCache.removeValue(forKey: id)
                setScheduleDraftValidity(taskID: id, isValid: true)
                NotificationCenter.default.post(
                    name: .runShelfTaskDeleted,
                    object: nil,
                    userInfo: [RunShelfNotificationUserInfoKey.taskID: id]
                )
                selectedTaskID = sortedTasks.first?.id
            } catch {
                lastErrorMessage = "无法删除任务：\(error.localizedDescription)"
            }
        }
    }

    func runTask(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard canRunTask(tasks[index]) else { return }

        if tasks[index].isDirty {
            // 有 app 内未保存的草稿，先保存再跑（保留原 auto-save 行为）
            guard saveTask(id: id) else { return }
        } else {
            // 没有未保存改动：从磁盘重读一次，确保用上最新的外部修改
            do {
                let reloaded = try loadTaskDefinitionPreservingRuns(at: index)
                tasks[index] = reloaded
                bumpGeneration(id)
                signatureCache[id] = TaskFileSignature.capture(for: tasks[index].directoryURL)
            } catch {
                lastErrorMessage = "无法运行任务：\(taskLoadFailureMessage(directoryURL: tasks[index].directoryURL, error: error))"
                return
            }
        }

        let task = tasks[index]
        let cancellation = TaskRunCancellation()
        runningCancellations[id] = cancellation
        runningTaskIDs.insert(id)
        runningStartedAt[id] = Date()

        Task.detached(priority: .userInitiated) {
            let result = Result {
                try TaskRunner.run(task: task, trigger: .manual, host: "app", cancellation: cancellation)
            }

            await MainActor.run {
                self.runningTaskIDs.remove(id)
                self.runningStartedAt.removeValue(forKey: id)
                self.runningCancellations.removeValue(forKey: id)
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

    func cancelTask(id: String) {
        guard runningTaskIDs.contains(id), let cancellation = runningCancellations[id] else { return }
        cancellation.cancel()
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
        !runningTaskIDs.contains(task.id) &&
            TaskRunClaimManager.activeClaim(for: task) == nil &&
            canPersistTask(task)
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

    private func loadTask(at directoryURL: URL, includeRuns: Bool = true) throws -> RunShelfTask {
        try diskLoader.loadTask(at: directoryURL, includeRuns: includeRuns)
    }

    private func loadTaskDefinitionPreservingRuns(at index: Int) throws -> RunShelfTask {
        var reloaded = try diskLoader.loadTask(at: tasks[index].directoryURL, includeRuns: false)
        reloaded.runs = tasks[index].runs
        return reloaded
    }

    private func writeTask(_ task: RunShelfTask, expectedRevision: TaskDefinitionRevision? = nil) throws {
        try repository.writeTask(task, expectedRevision: expectedRevision)
    }

    private func refreshRuns(for id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].runs = diskLoader.loadRuns(for: tasks[index].directoryURL)
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

    private func taskLoadFailureMessage(directoryURL: URL, error: Error) -> String {
        "无法读取任务 \(directoryURL.lastPathComponent)：\(error.localizedDescription)"
    }

    private func normalizedName(_ name: String?, fallback: String) -> String {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

}
