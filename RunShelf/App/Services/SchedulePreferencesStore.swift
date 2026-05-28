import Combine
import Foundation

/// 用户在每个任务里手动选择的「计划」编辑 tab（每天/每周/.../高级）。
/// 是纯 UI 偏好，存 UserDefaults——不写进 task.json，避免脏掉任务。
@MainActor
final class SchedulePreferencesStore: ObservableObject {
    @Published private(set) var modes: [String: String] = [:]

    private let defaultsKey = "ScheduleEditorModes"
    private var observer: NSObjectProtocol?

    init() {
        if let dict = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] {
            modes = dict
        }
        observer = NotificationCenter.default.addObserver(
            forName: .runShelfTaskDeleted,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let id = note.userInfo?[RunShelfNotificationUserInfoKey.taskID] as? String else { return }
            MainActor.assumeIsolated {
                self?.forget(taskID: id)
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func mode(for taskID: String) -> String? {
        modes[taskID]
    }

    func setMode(_ rawValue: String, for taskID: String) {
        guard modes[taskID] != rawValue else { return }
        modes[taskID] = rawValue
        UserDefaults.standard.set(modes, forKey: defaultsKey)
    }

    func forget(taskID: String) {
        guard modes.removeValue(forKey: taskID) != nil else { return }
        UserDefaults.standard.set(modes, forKey: defaultsKey)
    }
}

// Notification.Name + RunShelfNotificationUserInfoKey 现在统一在 Core/RunShelfNotifications.swift。
