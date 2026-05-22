import Foundation

enum RunShelfPaths {
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
}
