import Combine
import Foundation

enum TaskListSortMode: String, CaseIterable, Identifiable {
    case manual
    case nextRun

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .manual: return "手动顺序"
        case .nextRun: return "下次运行"
        }
    }
}
/// 侧边栏的纯展示偏好。排序不会写入 task.json，也不改变 CLI 或 Scheduler 的行为。
@MainActor
final class TaskListPreferencesStore: ObservableObject {
    @Published private(set) var sortMode: TaskListSortMode
    @Published private(set) var manualOrder: [String]

    private let defaults: UserDefaults
    private let sortModeKey: String
    private let manualOrderKey: String
    private var observer: NSObjectProtocol?

    init(
        defaults: UserDefaults = .standard,
        sortModeKey: String = "TaskListSortMode",
        manualOrderKey: String = "TaskListManualOrder"
    ) {
        self.defaults = defaults
        self.sortModeKey = sortModeKey
        self.manualOrderKey = manualOrderKey
        sortMode = defaults.string(forKey: sortModeKey)
            .flatMap(TaskListSortMode.init(rawValue:)) ?? .manual
        manualOrder = defaults.stringArray(forKey: manualOrderKey) ?? []

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

    func setSortMode(_ mode: TaskListSortMode) {
        guard sortMode != mode else { return }
        sortMode = mode
        defaults.set(mode.rawValue, forKey: sortModeKey)
    }

    func reconcile(taskIDs: [String]) {
        let available = Set(taskIDs)
        let known = Set(manualOrder)
        let nextOrder = manualOrder.filter(available.contains) + taskIDs.filter { !known.contains($0) }
        guard nextOrder != manualOrder else { return }
        manualOrder = nextOrder
        persistManualOrder()
    }

    func move(taskIDs: [String], fromOffsets: IndexSet, toOffset: Int) {
        guard sortMode == .manual else { return }
        var reordered = taskIDs
        let moving = fromOffsets.sorted().map { reordered[$0] }
        for index in fromOffsets.sorted(by: >) {
            reordered.remove(at: index)
        }
        let adjustedDestination = toOffset - fromOffsets.filter { $0 < toOffset }.count
        reordered.insert(contentsOf: moving, at: adjustedDestination)
        guard reordered != manualOrder else { return }
        manualOrder = reordered
        persistManualOrder()
    }

    func orderedTasks(_ tasks: [RunShelfTask], now: Date = Date()) -> [RunShelfTask] {
        let ranks = Dictionary(uniqueKeysWithValues: manualOrder.enumerated().map { ($0.element, $0.offset) })
        let fallbackStart = manualOrder.count
        let fallbackRanks = Dictionary(uniqueKeysWithValues: tasks.enumerated().map { ($0.element.id, fallbackStart + $0.offset) })
        let manualRank: (RunShelfTask) -> Int = { task in
            ranks[task.id] ?? fallbackRanks[task.id] ?? Int.max
        }

        switch sortMode {
        case .manual:
            return tasks.sorted { lhs, rhs in
                manualRank(lhs) < manualRank(rhs)
            }
        case .nextRun:
            let nextRuns = Dictionary(uniqueKeysWithValues: tasks.map { task in
                (task.id, Self.nextRun(for: task, after: now))
            })
            return tasks.sorted { lhs, rhs in
                switch (nextRuns[lhs.id] ?? nil, nextRuns[rhs.id] ?? nil) {
                case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
                    return lhsDate < rhsDate
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return manualRank(lhs) < manualRank(rhs)
                }
            }
        }
    }

    func forget(taskID: String) {
        guard manualOrder.contains(taskID) else { return }
        manualOrder.removeAll { $0 == taskID }
        persistManualOrder()
    }

    private func persistManualOrder() {
        defaults.set(manualOrder, forKey: manualOrderKey)
    }

    private static func nextRun(for task: RunShelfTask, after date: Date) -> Date? {
        guard task.manifest.enabled,
              let schedule = try? CronSchedule.parse(task.manifest.schedule.expression) else {
            return nil
        }
        return try? schedule.nextRuns(after: date, count: 1).first
    }
}
