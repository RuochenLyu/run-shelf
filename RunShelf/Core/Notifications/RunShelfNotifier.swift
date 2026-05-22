import Foundation
import UserNotifications

enum RunShelfNotifier {
    static func requestAuthorization(completion: ((Bool) -> Void)? = nil) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            completion?(granted)
        }
    }

    static func notificationSettings(completion: @escaping (UNAuthorizationStatus) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            completion(settings.authorizationStatus)
        }
    }

    static func notifyFailure(task: RunShelfTask, run: RunRecord) {
        guard task.manifest.notifications.onFailure else { return }

        notificationSettings { status in
            guard canDeliverNotifications(status) else { return }
            let content = UNMutableNotificationContent()
            content.title = "Run Shelf 任务失败"
            content.subtitle = task.manifest.name
            content.body = failureBody(for: run)
            content.sound = .default
            content.userInfo = [
                "taskId": task.id,
                "runId": run.runId
            ]

            let request = UNNotificationRequest(
                identifier: "run-shelf-\(task.id)-\(run.runId)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    private static func canDeliverNotifications(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        default:
            return false
        }
    }

    private static func failureBody(for run: RunRecord) -> String {
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
