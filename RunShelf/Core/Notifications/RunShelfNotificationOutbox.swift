import Foundation

/// 一条待投递的失败通知。字段只放展示所需内容，投递方不再回读任务目录。
struct RunShelfFailureNotification: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var taskId: String
    var runId: String
    var taskName: String
    var status: TaskRunStatus
    var body: String
    var createdAt: Date

    /// 与 App 直投路径相同的 identifier：重复投递只会替换，不会叠加。
    var identifier: String {
        "run-shelf-\(taskId)-\(runId)"
    }

    init(task: RunShelfTask, run: RunRecord, createdAt: Date = Date()) {
        schemaVersion = Self.currentSchemaVersion
        taskId = task.id
        runId = run.runId
        taskName = task.manifest.name
        status = run.status
        body = Self.body(for: run)
        self.createdAt = createdAt
    }

    static func body(for run: RunRecord) -> String {
        switch run.status {
        case .timeout:
            return run.message ?? "运行超时"
        case .failed:
            return "退出码：\(run.exitCode.map(String.init) ?? "-")"
        case .stale, .skipped, .cancelled:
            return run.message ?? run.status.displayName
        default:
            return run.status.displayName
        }
    }
}

/// 文件型通知队列。
///
/// 写入方（调度进程）：原子写入 `<taskId>--<runId>.json`，顺手修剪过期和超量条目，
/// 保证 App 长期不运行时目录也不会无界增长。
/// 读取方（App 进程）：按创建时间顺序取出、投递、删除。
/// 过期条目（默认 24 小时）直接丢弃——迟到一天的失败弹窗比没有更误导。
struct RunShelfNotificationOutbox {
    static let defaultMaxAge: TimeInterval = 24 * 60 * 60
    static let defaultMaxEntries = 200

    let directoryURL: URL
    let maxAge: TimeInterval
    let maxEntries: Int
    private let fileManager: FileManager

    init(
        directoryURL: URL = RunShelfPaths.notificationOutboxURL(),
        maxAge: TimeInterval = RunShelfNotificationOutbox.defaultMaxAge,
        maxEntries: Int = RunShelfNotificationOutbox.defaultMaxEntries,
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.maxAge = maxAge
        self.maxEntries = maxEntries
        self.fileManager = fileManager
    }

    func enqueue(_ notification: RunShelfFailureNotification, now: Date = Date()) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(notification)

        let fileName = Self.fileName(for: notification)
        let destinationURL = directoryURL.appendingPathComponent(fileName)
        // 临时文件以 "." 开头，读取方只认非隐藏的 .json，读不到半截内容。
        let temporaryURL = directoryURL.appendingPathComponent(".\(fileName).\(UUID().uuidString).tmp")
        try data.write(to: temporaryURL)
        if rename(temporaryURL.path, destinationURL.path) != 0 {
            let code = errno
            try? fileManager.removeItem(at: temporaryURL)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }

        prune(now: now)
    }

    /// 依次交给 `deliver`，交付后删除文件。返回本次交付的条目。
    @discardableResult
    func drain(
        now: Date = Date(),
        deliver: (RunShelfFailureNotification) -> Void
    ) -> [RunShelfFailureNotification] {
        let entries = pendingEntries(now: now)
        for entry in entries {
            deliver(entry.notification)
            try? fileManager.removeItem(at: entry.url)
        }
        return entries.map(\.notification)
    }

    /// 只读当前队列（已剔除过期/损坏条目）。
    func pending(now: Date = Date()) -> [RunShelfFailureNotification] {
        pendingEntries(now: now).map(\.notification)
    }

    func prune(now: Date = Date()) {
        let entries = pendingEntries(now: now)
        guard entries.count > maxEntries else { return }
        for entry in entries.prefix(entries.count - maxEntries) {
            try? fileManager.removeItem(at: entry.url)
        }
    }

    private struct Entry {
        var url: URL
        var notification: RunShelfFailureNotification
    }

    /// 读取全部条目，按创建时间升序；过期、损坏、残留临时文件在这里被删除。
    private func pendingEntries(now: Date) -> [Entry] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var entries: [Entry] = []

        for url in urls {
            let name = url.lastPathComponent
            if name.hasPrefix(".") {
                // 写入方崩溃留下的临时文件：超过 maxAge 才清，避免误删正在写的文件。
                if isOlderThanMaxAge(url: url, now: now) {
                    try? fileManager.removeItem(at: url)
                }
                continue
            }
            guard url.pathExtension == "json" else { continue }

            guard let data = try? Data(contentsOf: url),
                  let notification = try? decoder.decode(RunShelfFailureNotification.self, from: data),
                  notification.schemaVersion == RunShelfFailureNotification.currentSchemaVersion
            else {
                try? fileManager.removeItem(at: url)
                continue
            }

            if now.timeIntervalSince(notification.createdAt) > maxAge {
                try? fileManager.removeItem(at: url)
                continue
            }
            entries.append(Entry(url: url, notification: notification))
        }

        return entries.sorted {
            if $0.notification.createdAt != $1.notification.createdAt {
                return $0.notification.createdAt < $1.notification.createdAt
            }
            return $0.url.lastPathComponent < $1.url.lastPathComponent
        }
    }

    private func isOlderThanMaxAge(url: URL, now: Date) -> Bool {
        guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
            return false
        }
        return now.timeIntervalSince(modified) > maxAge
    }

    static func fileName(for notification: RunShelfFailureNotification) -> String {
        "\(sanitize(notification.taskId))--\(sanitize(notification.runId)).json"
    }

    private static func sanitize(_ component: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_+"))
        let scalars = component.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let result = String(scalars)
        return result.isEmpty ? "_" : result
    }
}
