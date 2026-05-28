import Foundation

/// 任务生命周期事件。后续增加事件类型时往这里加，
/// 避免 Core 和 App 两边各自硬编码字符串、typo 风险扩散。
extension Notification.Name {
    static let runShelfTaskDeleted = Notification.Name("RunShelf.taskDidDelete")
}

enum RunShelfNotificationUserInfoKey {
    static let taskID = "taskID"
}
