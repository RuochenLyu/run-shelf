import Foundation

/// 文件指纹：mtime + size 两个维度，任一变化都触发 full reload。
/// 比单纯 mtime 更稳：mtime 秒级精度回滚到旧值时，size 通常还会不同。
struct TaskFileSignature: Sendable, Equatable {
    var manifestSig: FileSig?
    var scriptSig: FileSig?
    var notesSig: FileSig?

    struct FileSig: Sendable, Equatable {
        let mtime: Date
        let size: Int

        init?(at url: URL) {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            // URLResourceValues 在 macOS 上可能不给目录返回 fileSize；FileManager
            // attributes 仍会返回目录项大小，可用于捕获直接子目录增删。
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let mtime = values?.contentModificationDate ?? attributes?[.modificationDate] as? Date
            let size = values?.fileSize ?? (attributes?[.size] as? NSNumber)?.intValue
            guard let mtime, let size else {
                return nil
            }
            self.mtime = mtime
            self.size = size
        }
    }

    static func capture(for directoryURL: URL) -> TaskFileSignature {
        TaskFileSignature(
            manifestSig: FileSig(at: directoryURL.appendingPathComponent("task.json")),
            scriptSig: FileSig(at: directoryURL.appendingPathComponent("run.sh")),
            notesSig: FileSig(at: directoryURL.appendingPathComponent("notes.md"))
        )
    }
}

/// Runs 的轻量变化指纹。
///
/// `runs/` 的 mtime 能捕获 run 目录的新增与 retention 删除；仍处于 running
/// 状态的 `meta.json` 单独纳入指纹，捕获同一 run 从 running 到终态的原子替换；
/// claim 根目录变化则触发一次 reload，让遗留的 running 记录能及时 reconcile，
/// 同时兼容单 claim 与 `concurrency=allow` 的多 claim 布局。
/// 这样稳定状态下只需少量 stat，不必每 15 秒枚举并解码全部历史。
struct TaskRunsSignature: Sendable, Equatable {
    var runsDirectorySig: TaskFileSignature.FileSig?
    var claimDirectorySig: TaskFileSignature.FileSig?
    var runningMetaSigs: [String: TaskFileSignature.FileSig?]

    static func capture(for directoryURL: URL, runningRunIDs: [String]) -> TaskRunsSignature {
        let runsURL = directoryURL.appendingPathComponent("runs", isDirectory: true)
        let runningMetaSigs = Dictionary(uniqueKeysWithValues: runningRunIDs.map { runID in
            let metaURL = runsURL
                .appendingPathComponent(runID, isDirectory: true)
                .appendingPathComponent("meta.json")
            return (runID, TaskFileSignature.FileSig(at: metaURL))
        })
        return TaskRunsSignature(
            runsDirectorySig: TaskFileSignature.FileSig(at: runsURL),
            claimDirectorySig: TaskFileSignature.FileSig(
                at: directoryURL.appendingPathComponent(".run-claim", isDirectory: true)
            ),
            runningMetaSigs: runningMetaSigs
        )
    }
}

struct TaskRunsCache: Sendable {
    let signature: TaskRunsSignature
    let lastFullReloadAt: Date

    static func capture(for task: RunShelfTask, at date: Date = Date()) -> TaskRunsCache {
        capture(for: task.directoryURL, runs: task.runs, at: date)
    }

    static func capture(for directoryURL: URL, runs: [RunRecord], at date: Date = Date()) -> TaskRunsCache {
        TaskRunsCache(
            signature: TaskRunsSignature.capture(
                for: directoryURL,
                runningRunIDs: runs.filter { $0.status == .running }.map(\.runId)
            ),
            lastFullReloadAt: date
        )
    }
}

struct TaskLiveActivity: Sendable, Equatable {
    let claims: [TaskRunClaim]

    var earliestStartedAt: Date? { claims.map(\.startedAt).min() }
    var runIDs: [String] { claims.map(\.runId) }
    var hosts: [String] { Array(Set(claims.map(\.host))).sorted() }
}

/// `refreshRunsFromDisk` 启动时打包给后台 scan 的输入快照。
struct DiskScanInput: Sendable {
    let tasksDirectoryURL: URL
    let knownTasks: [KnownTask]
    let signatureCache: [String: TaskFileSignature]
    let runsCache: [String: TaskRunsCache]
    let now: Date
    let fullRunsReloadInterval: TimeInterval

    init(
        tasksDirectoryURL: URL,
        knownTasks: [KnownTask],
        signatureCache: [String: TaskFileSignature],
        runsCache: [String: TaskRunsCache],
        now: Date = Date(),
        fullRunsReloadInterval: TimeInterval = 5 * 60
    ) {
        self.tasksDirectoryURL = tasksDirectoryURL
        self.knownTasks = knownTasks
        self.signatureCache = signatureCache
        self.runsCache = runsCache
        self.now = now
        self.fullRunsReloadInterval = fullRunsReloadInterval
    }

    struct KnownTask: Sendable {
        let id: String
        let directoryURL: URL
        let isDirty: Bool
        let generation: Int
        let runningRunIDs: [String]
        let task: RunShelfTask?

        init(
            id: String,
            directoryURL: URL,
            isDirty: Bool,
            generation: Int,
            runningRunIDs: [String],
            task: RunShelfTask? = nil
        ) {
            self.id = id
            self.directoryURL = directoryURL
            self.isDirty = isDirty
            self.generation = generation
            self.runningRunIDs = runningRunIDs
            self.task = task
        }
    }
}

/// 后台 scan 返回给 MainActor 的 patch list。
struct DiskScanResult: Sendable {
    var entries: [DiskScanEntry]
    var deletedTaskIDs: [String]
    var newSignatures: [String: TaskFileSignature]
    var newRunsCache: [String: TaskRunsCache]
    var activities: [String: TaskLiveActivity]
    var errors: [String]
}

/// 每个任务的 scan 结果。`generation` 是 scan 启动时该任务在 store 里的 epoch，
/// apply 时用来检测期间是否被用户改动过。
enum DiskScanEntry: Sendable {
    /// 整个任务从盘上重新加载（首次出现 / signature 变化 / 缓存 miss）。
    case fullReload(RunShelfTask, generation: Int)
    /// 只有 runs 可能变化（signature 没变或任务是 dirty 的）。
    case runsOnly(taskID: String, runs: [RunRecord], generation: Int)
}

enum DiskScanner {
    /// 后台线程入口：用独立的 nonisolated TaskFileStore 实例避免触碰 MainActor。
    static func scan(_ input: DiskScanInput) -> DiskScanResult {
        let loader = TaskFileStore(
            tasksDirectoryURL: input.tasksDirectoryURL,
            fileManager: .default
        )

        // 列目录拿到 disk 上所有 task id
        var diskTaskIDs = Set<String>()
        var errors: [String] = []
        do {
            let entries = try FileManager.default.contentsOfDirectory(
                at: input.tasksDirectoryURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            for url in entries {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                guard isDir, url.lastPathComponent != "trash" else { continue }
                diskTaskIDs.insert(url.lastPathComponent)
            }
        } catch {
            errors.append("无法刷新任务目录：\(error.localizedDescription)")
            return DiskScanResult(
                entries: [],
                deletedTaskIDs: [],
                newSignatures: [:],
                newRunsCache: [:],
                activities: [:],
                errors: errors
            )
        }

        let knownByID = Dictionary(uniqueKeysWithValues: input.knownTasks.map { ($0.id, $0) })
        var resultEntries: [DiskScanEntry] = []
        var newSignatures: [String: TaskFileSignature] = [:]
        var newRunsCache: [String: TaskRunsCache] = [:]
        var activities: [String: TaskLiveActivity] = [:]

        for id in diskTaskIDs {
            let dirURL = input.tasksDirectoryURL.appendingPathComponent(id, isDirectory: true)
            let currentSig = TaskFileSignature.capture(for: dirURL)

            let known = knownByID[id]
            let cachedSig = input.signatureCache[id]

            if let activityTask = known?.task ?? (try? loader.loadTask(at: dirURL, includeRuns: false)) {
                let claims = TaskRunClaimManager.activeClaims(
                    for: activityTask,
                    now: input.now,
                    fileManager: .default
                )
                if !claims.isEmpty {
                    activities[id] = TaskLiveActivity(claims: claims)
                }
            }

            func loadRuns(generation: Int) {
                let runs = loader.loadRuns(for: dirURL)
                newRunsCache[id] = TaskRunsCache.capture(for: dirURL, runs: runs, at: input.now)
                resultEntries.append(.runsOnly(taskID: id, runs: runs, generation: generation))
            }

            let currentRunsSignature = TaskRunsSignature.capture(
                for: dirURL,
                runningRunIDs: known?.runningRunIDs ?? []
            )
            let cachedRuns = input.runsCache[id]
            let runsNeedFallbackReload = cachedRuns.map {
                input.now.timeIntervalSince($0.lastFullReloadAt) >= input.fullRunsReloadInterval
            } ?? true
            let runsChanged = cachedRuns?.signature != currentRunsSignature

            // Dirty 任务：永远只 merge runs，保护用户草稿不被外部覆盖
            if let known, known.isDirty {
                if runsChanged || runsNeedFallbackReload {
                    loadRuns(generation: known.generation)
                }
                continue
            }

            // Signature 没变 + 任务已知 → 只刷新 runs
            if let known, let cachedSig, currentSig == cachedSig {
                newSignatures[id] = currentSig
                if runsChanged || runsNeedFallbackReload {
                    loadRuns(generation: known.generation)
                }
                continue
            }

            // Signature 变了或任务新出现 → 完整 reload
            do {
                let task = try loader.loadTask(at: dirURL)
                let generation = known?.generation ?? 0
                newSignatures[id] = currentSig
                newRunsCache[id] = TaskRunsCache.capture(for: task, at: input.now)
                resultEntries.append(.fullReload(task, generation: generation))
            } catch {
                errors.append("无法读取任务 \(id)：\(error.localizedDescription)")
            }
        }

        // 内存有但盘上没有的任务（apply 时会处理 dirty 保护）
        let deleted = input.knownTasks.map(\.id).filter { !diskTaskIDs.contains($0) }

        return DiskScanResult(
            entries: resultEntries,
            deletedTaskIDs: deleted,
            newSignatures: newSignatures,
            newRunsCache: newRunsCache,
            activities: activities,
            errors: errors
        )
    }
}
