import Foundation

enum RunShelfSettings {
    static let defaultRetentionDaysKey = "defaultRetentionDays"
    static let defaultRetentionMaxRunsKey = "defaultRetentionMaxRuns"

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
