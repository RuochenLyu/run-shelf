import SwiftUI

struct TaskSidebarView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var selection: TaskSelectionState
    @ObservedObject var preferences: TaskListPreferencesStore
    @State private var editingTaskID: String? = nil

    var body: some View {
        taskList
            .onAppear {
                preferences.reconcile(taskIDs: store.sortedTasks.map(\.id))
            }
            .onChange(of: store.tasks.map(\.id)) { _, _ in
                preferences.reconcile(taskIDs: store.sortedTasks.map(\.id))
            }
            .sheet(item: editingTaskBinding) { task in
                TaskEditSheet(store: store, task: task)
            }
    }

    private var taskList: some View {
        List(selection: $selection.selectedTaskID) {
            ForEach(orderedTasks) { task in
                TaskSidebarRow(
                    task: task,
                    isRunning: store.runningTaskIDs.contains(task.id),
                    startedAt: store.runningStartedAt[task.id]
                )
                .tag(task.id)
                .contextMenu { contextMenu(for: task) }
            }
            .onMove { offsets, destination in
                preferences.move(
                    taskIDs: orderedTasks.map(\.id),
                    fromOffsets: offsets,
                    toOffset: destination
                )
            }
            .moveDisabled(preferences.sortMode != .manual)
        }
        .listStyle(.sidebar)
    }

    private var orderedTasks: [RunShelfTask] {
        preferences.orderedTasks(store.sortedTasks)
    }

    @ViewBuilder
    private func contextMenu(for task: RunShelfTask) -> some View {
        Button {
            store.runTask(id: task.id)
        } label: {
            Label("立即运行", systemImage: "play.fill")
        }
        .disabled(!store.canRunTask(task))

        Button(role: .destructive) {
            store.cancelTask(id: task.id)
        } label: {
            Label("停止运行", systemImage: "stop.fill")
        }
        .disabled(!store.runningTaskIDs.contains(task.id))

        Button {
            editingTaskID = task.id
        } label: {
            Label("重命名…", systemImage: "pencil")
        }

        Button {
            store.updateTask(id: task.id) { $0.manifest.enabled.toggle() }
            store.saveTask(id: task.id)
        } label: {
            if task.manifest.enabled {
                Label("停用", systemImage: "power")
            } else {
                Label("启用", systemImage: "power")
            }
        }

        Divider()

        Button {
            store.openTaskDirectory(id: task.id)
        } label: {
            Label("在 Finder 中显示", systemImage: "folder")
        }

        Divider()

        Button(role: .destructive) {
            store.deleteTask(id: task.id)
        } label: {
            Label("删除", systemImage: "trash")
        }
        .disabled(store.runningTaskIDs.contains(task.id))
    }

    private var editingTaskBinding: Binding<RunShelfTask?> {
        Binding(
            get: {
                guard let id = editingTaskID else { return nil }
                return store.task(withID: id)
            },
            set: { editingTaskID = $0?.id }
        )
    }
}

private struct TaskSidebarRow: View {
    var task: RunShelfTask
    var isRunning: Bool
    var startedAt: Date?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if status == .running {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
                    .accessibilityLabel("运行中")
            } else if let symbol = status.symbol {
                Image(systemName: symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(status.color)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 16, height: 16)
                    .accessibilityLabel(status.accessibilityLabel)
                    .help(status.accessibilityLabel)
            } else {
                Color.clear
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if status == .running, let effectiveStartedAt {
                RunningDurationText(startedAt: effectiveStartedAt)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.blue)
            }
        }
        .padding(.vertical, 3)
    }

    private var displayName: String {
        let name = task.manifest.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "未命名任务" : name
    }

    private var subtitle: String {
        switch status {
        case .quiet:
            return scheduleSubtitle
        case .waiting:
            return "等待中"
        case .running:
            return "运行中"
        case .success:
            return runStatusSubtitle("成功")
        case .failed:
            return runStatusSubtitle("失败")
        case .timeout:
            return runStatusSubtitle("超时")
        case .skipped:
            return runStatusSubtitle("已跳过")
        case .cancelled:
            return runStatusSubtitle("已取消")
        case .attention:
            if !task.hasValidSchedule { return "计划无效" }
            return runStatusSubtitle("已过期")
        case .disabled:
            return "未启用"
        }
    }

    private var scheduleSubtitle: String {
        guard let schedule = try? CronSchedule.parse(task.manifest.schedule.expression) else {
            return "计划无效"
        }

        if let next = try? schedule.nextRuns(count: 1).first {
            if schedule.summary == "高级 Cron 表达式" {
                return "下次 \(RunShelfFormatters.scheduleDateTime(next))"
            }
            return "\(schedule.summary) · \(RunShelfFormatters.scheduleDateTime(next))"
        }
        return schedule.summary
    }

    private var status: SidebarTaskStatus {
        if isRunning { return .running }
        if !task.manifest.enabled { return .disabled }
        if let latest = task.latestRun {
            switch latest.status {
            case .pending: return .waiting
            case .running: return .running
            case .success: return .success
            case .failed: return .failed
            case .timeout: return .timeout
            case .skipped: return .skipped
            case .cancelled: return .cancelled
            case .stale: return .attention
            }
        }
        if !task.hasValidSchedule { return .attention }
        return .quiet
    }

    private var effectiveStartedAt: Date? {
        startedAt ?? task.latestRun.flatMap { $0.status == .running ? $0.startedAt : nil }
    }

    private func runStatusSubtitle(_ label: String) -> String {
        guard let date = task.latestRun?.startedAt else { return label }
        return "\(label) · \(RunShelfFormatters.scheduleDateTime(date))"
    }
}

private enum SidebarTaskStatus: Equatable {
    case quiet
    case waiting
    case running
    case success
    case failed
    case timeout
    case skipped
    case cancelled
    case attention
    case disabled

    var symbol: String? {
        switch self {
        case .running: return nil
        case .quiet: return "calendar.badge.clock"
        case .waiting: return "clock.fill"
        case .success: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .timeout: return "clock.badge.exclamationmark.fill"
        case .skipped: return "forward.end.circle.fill"
        case .cancelled: return "stop.circle.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .disabled: return "pause.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .waiting, .running: return .blue
        case .failed, .timeout: return .red
        case .attention: return .orange
        case .quiet, .success, .skipped, .cancelled, .disabled: return .secondary
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .quiet: return "已计划"
        case .waiting: return "等待中"
        case .running: return "运行中"
        case .success: return "上次运行成功"
        case .failed: return "上次运行失败"
        case .timeout: return "上次运行超时"
        case .skipped: return "上次运行已跳过"
        case .cancelled: return "上次运行已取消"
        case .attention: return "需要注意"
        case .disabled: return "未启用"
        }
    }
}

struct RunningDurationText: View {
    var startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            Text(format(elapsed: context.date.timeIntervalSince(startedAt)))
        }
    }

    private func format(elapsed: TimeInterval) -> String {
        let secs = max(0, Int(elapsed))
        if secs < 60 {
            return "\(secs)秒"
        }
        if secs < 3600 {
            let m = secs / 60
            let s = secs % 60
            return s == 0 ? "\(m)分" : "\(m)分\(s)秒"
        }
        let h = secs / 3600
        let m = (secs % 3600) / 60
        return "\(h)时\(m)分"
    }
}
