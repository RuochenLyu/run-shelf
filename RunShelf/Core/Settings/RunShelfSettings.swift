import Foundation

enum RunShelfSettings {
    static let defaultRetentionDaysKey = "defaultRetentionDays"
    static let defaultRetentionMaxRunsKey = "defaultRetentionMaxRuns"
    /// 菜单栏图标只是快捷入口；隐藏后 Dock 图标和主窗口仍可用，后台调度不受影响。
    static let showsMenuBarIconKey = "showsMenuBarIcon"
    static let showsMenuBarIconDefault = true

    static var defaultRetentionDays: Int {
        let value = UserDefaults.standard.integer(forKey: defaultRetentionDaysKey)
        return value > 0 ? value : 30
    }

    static var defaultRetentionMaxRuns: Int {
        let value = UserDefaults.standard.integer(forKey: defaultRetentionMaxRunsKey)
        return value > 0 ? value : 500
    }

    static var defaultRetentionPolicy: RetentionPolicy {
        RetentionPolicy(days: defaultRetentionDays, maxRuns: defaultRetentionMaxRuns)
    }
}
