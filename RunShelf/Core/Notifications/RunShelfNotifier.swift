import Foundation
import UserNotifications

/// 系统通知中心的唯一入口。
///
/// `UNUserNotificationCenter.current()` 在没有 .app bundle 的进程里会触发
/// `NSInternalInconsistencyException`（断言失败直接 abort）。RunShelfScheduler 和
/// `runshelf` CLI 都是裸可执行文件，所以这里的每个入口都先过 bundle 检查：
/// 非 App 进程里查询类 API 降级为“未授权”，投递类 API 什么也不做。
/// 非 App 进程要发失败通知，应写入 `RunShelfNotificationOutbox`，由 App 转投。
enum RunShelfNotifier {
    /// 纯函数，方便单测：只有真正的 .app bundle 才有 UserNotifications 需要的 bundle proxy。
    static func canUseUserNotifications(bundleURL: URL, bundleIdentifier: String?) -> Bool {
        guard bundleURL.pathExtension == "app" else { return false }
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return false }
        return true
    }

    static var isUserNotificationContextAvailable: Bool {
        canUseUserNotifications(
            bundleURL: Bundle.main.bundleURL,
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
    }

    static func requestAuthorization(completion: ((Bool) -> Void)? = nil) {
        guard isUserNotificationContextAvailable else {
            completion?(false)
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            completion?(granted)
        }
    }

    static func notificationSettings(completion: @escaping (UNAuthorizationStatus) -> Void) {
        guard isUserNotificationContextAvailable else {
            completion(.notDetermined)
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            completion(settings.authorizationStatus)
        }
    }

    /// App 进程内直投。非 App 进程调用时静默丢弃（不崩溃）；
    /// 调度进程请改用 `enqueueFailure(task:run:outbox:)`。
    static func notifyFailure(task: RunShelfTask, run: RunRecord) {
        guard task.manifest.notifications.onFailure else { return }
        deliver(RunShelfFailureNotification(task: task, run: run))
    }

    /// 非 App 进程的失败通知入口：只写文件，不碰 UserNotifications。
    static func enqueueFailure(
        task: RunShelfTask,
        run: RunRecord,
        outbox: RunShelfNotificationOutbox
    ) throws {
        guard task.manifest.notifications.onFailure else { return }
        try outbox.enqueue(RunShelfFailureNotification(task: task, run: run))
    }

    /// App 进程转投 outbox。授权不足时条目同样被消费掉，与直投路径行为一致
    /// （未授权时直投也不会补发）。
    static func drainOutbox(_ outbox: RunShelfNotificationOutbox, completion: (() -> Void)? = nil) {
        guard isUserNotificationContextAvailable, !outbox.pending().isEmpty else {
            completion?()
            return
        }

        notificationSettings { status in
            let canDeliver = canDeliverNotifications(status)
            outbox.drain { notification in
                if canDeliver {
                    add(notification)
                }
            }
            completion?()
        }
    }

    static func deliver(_ notification: RunShelfFailureNotification) {
        guard isUserNotificationContextAvailable else { return }
        notificationSettings { status in
            guard canDeliverNotifications(status) else { return }
            add(notification)
        }
    }

    private static func add(_ notification: RunShelfFailureNotification) {
        let content = UNMutableNotificationContent()
        content.title = "任务运行失败"
        content.subtitle = notification.taskName
        content.body = notification.body
        content.sound = .default
        content.userInfo = [
            "taskId": notification.taskId,
            "runId": notification.runId
        ]

        let request = UNNotificationRequest(
            identifier: notification.identifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private static func canDeliverNotifications(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        default:
            return false
        }
    }
}
