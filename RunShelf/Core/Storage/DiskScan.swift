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
            guard let mtime = values?.contentModificationDate, let size = values?.fileSize else {
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

/// `refreshRunsFromDisk` 启动时打包给后台 scan 的输入快照。
struct DiskScanInput: Sendable {
    let tasksDirectoryURL: URL
    let knownTasks: [KnownTask]
    let signatureCache: [String: TaskFileSignature]

    struct KnownTask: Sendable {
        let id: String
        let directoryURL: URL
        let isDirty: Bool
        let generation: Int
    }
}

/// 后台 scan 返回给 MainActor 的 patch list。
struct DiskScanResult: Sendable {
    var entries: [DiskScanEntry]
    var deletedTaskIDs: [String]
    var newSignatures: [String: TaskFileSignature]
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
            return DiskScanResult(entries: [], deletedTaskIDs: [], newSignatures: [:], errors: errors)
        }

        let knownByID = Dictionary(uniqueKeysWithValues: input.knownTasks.map { ($0.id, $0) })
        var resultEntries: [DiskScanEntry] = []
        var newSignatures: [String: TaskFileSignature] = [:]

        for id in diskTaskIDs {
            let dirURL = input.tasksDirectoryURL.appendingPathComponent(id, isDirectory: true)
            let currentSig = TaskFileSignature.capture(for: dirURL)

            let known = knownByID[id]
            let cachedSig = input.signatureCache[id]

            // Dirty 任务：永远只 merge runs，保护用户草稿不被外部覆盖
            if let known, known.isDirty {
                let runs = loader.loadRuns(for: dirURL)
                newSignatures[id] = currentSig
                resultEntries.append(.runsOnly(taskID: id, runs: runs, generation: known.generation))
                continue
            }

            // Signature 没变 + 任务已知 → 只刷新 runs
            if let known, let cachedSig, currentSig == cachedSig {
                let runs = loader.loadRuns(for: dirURL)
                newSignatures[id] = currentSig
                resultEntries.append(.runsOnly(taskID: id, runs: runs, generation: known.generation))
                continue
            }

            // Signature 变了或任务新出现 → 完整 reload
            do {
                let task = try loader.loadTask(at: dirURL)
                let generation = known?.generation ?? 0
                newSignatures[id] = currentSig
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
            errors: errors
        )
    }
}
