import Foundation

enum RunShelfSettings {
    static let previewDefaultsSuiteName = "com.aix4u.runshelf.preview"

    /// App 偏好的唯一入口。开发预览和测试（`RUN_SHELF_APP_SUPPORT_DIR`）与正式 App
    /// 同一个 bundle id，若共用 `.standard` 会把临时数据目录里的状态写回用户的
    /// 真实偏好（例如用示例任务裁掉手动排序），所以改用独立的 suite。
    static let defaults: UserDefaults = {
        guard RunShelfPaths.isAppSupportOverridden,
              let preview = UserDefaults(suiteName: previewDefaultsSuiteName) else {
            return .standard
        }
        return preview
    }()

    static let defaultRetentionDaysKey = "defaultRetentionDays"
    static let defaultRetentionMaxRunsKey = "defaultRetentionMaxRuns"
    /// 菜单栏图标只是快捷入口；隐藏后 Dock 图标和主窗口仍可用，后台调度不受影响。
    static let showsMenuBarIconKey = "showsMenuBarIcon"
    static let showsMenuBarIconDefault = true

    static var defaultRetentionDays: Int {
        let value = defaults.integer(forKey: defaultRetentionDaysKey)
        return value > 0 ? value : 30
    }

    static var defaultRetentionMaxRuns: Int {
        let value = defaults.integer(forKey: defaultRetentionMaxRunsKey)
        return value > 0 ? value : 500
    }

    static var defaultRetentionPolicy: RetentionPolicy {
        RetentionPolicy(days: defaultRetentionDays, maxRuns: defaultRetentionMaxRuns)
    }
}
