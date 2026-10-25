import Foundation

enum RunShelfPaths {
    /// 开发预览/测试用临时数据目录时为 true；此时 App 不得改动系统里的后台调度注册。
    static var isAppSupportOverridden: Bool {
        guard let override = ProcessInfo.processInfo.environment["RUN_SHELF_APP_SUPPORT_DIR"] else { return false }
        return !override.isEmpty
    }

    static func appSupportDirectoryURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["RUN_SHELF_APP_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Run Shelf", isDirectory: true)
    }

    static func tasksDirectoryURL() -> URL {
        appSupportDirectoryURL()
            .appendingPathComponent("tasks", isDirectory: true)
    }

    static func schedulerStateURL() -> URL {
        appSupportDirectoryURL()
            .appendingPathComponent("scheduler-state.json")
    }

    static func schedulerHeartbeatURL() -> URL {
        appSupportDirectoryURL()
            .appendingPathComponent("scheduler-heartbeat.json")
    }

    static func schedulerLogURL() -> URL {
        appSupportDirectoryURL()
            .appendingPathComponent("scheduler.log")
    }

    /// 调度进程等无 .app bundle 的进程不能调用 UserNotifications，
    /// 失败通知先落到这里，由 App 进程转投系统通知中心。
    static func notificationOutboxURL(
        appSupportDirectoryURL: URL = RunShelfPaths.appSupportDirectoryURL()
    ) -> URL {
        appSupportDirectoryURL
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("outbox", isDirectory: true)
    }
}
