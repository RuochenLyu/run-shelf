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

            statusAccessory
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var statusAccessory: some View {
        if status == .running {
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.small)
                if let effectiveStartedAt {
                    RunningDurationText(startedAt: effectiveStartedAt)
                        .font(.caption.monospacedDigit())
                }
            }
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel("运行中")
        } else if let presentation = statusPresentation {
            Image(systemName: presentation.symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(presentation.color)
                .imageScale(.medium)
                .accessibilityLabel(presentation.accessibilityLabel)
                .help(presentation.help)
        }
    }

    private var displayName: String {
        let name = task.manifest.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "未命名任务" : name
    }

    private var subtitle: String {
        switch status {
        case .scheduled:
            return nextRunSubtitle
        case .waiting:
            return "等待运行"
        case .running:
            return "运行中"
        case .failed:
            return runStatusSubtitle("上次失败")
        case .timeout:
            return runStatusSubtitle("上次超时")
        case .skipped:
            return runStatusSubtitle("上次跳过")
        case .cancelled:
            return runStatusSubtitle("上次取消")
        case .attention:
            if !task.hasValidSchedule { return "计划无效" }
            return runStatusSubtitle("运行记录已过期")
        case .disabled:
            return "已停用"
        }
    }

    private var nextRunSubtitle: String {
        guard let schedule = try? CronSchedule.parse(task.manifest.schedule.expression) else {
            return "计划无效"
        }

        if let next = try? schedule.nextRuns(count: 1).first {
            return "下次 \(RunShelfFormatters.scheduleDateTime(next))"
        }
        return "暂无下次运行"
    }

    private var statusPresentation: SidebarStatusPresentation? {
        switch status {
        case .scheduled:
            guard let latest = task.latestRun, latest.status == .success else { return nil }
            let text = runStatusSubtitle("上次运行成功")
            return SidebarStatusPresentation(
                symbol: "checkmark.circle.fill",
                color: .green,
                accessibilityLabel: "上次运行成功",
                help: text
            )
        case .waiting:
            return SidebarStatusPresentation(
                symbol: "clock.fill",
                color: .accentColor,
                accessibilityLabel: "等待运行",
                help: "等待运行"
            )
        case .running:
            return nil
        case .failed:
            return SidebarStatusPresentation(
                symbol: "xmark.circle.fill",
                color: .red,
                accessibilityLabel: "上次运行失败",
                help: runStatusSubtitle("上次运行失败")
            )
        case .timeout:
            return SidebarStatusPresentation(
                symbol: "clock.badge.exclamationmark.fill",
                color: .red,
                accessibilityLabel: "上次运行超时",
                help: runStatusSubtitle("上次运行超时")
            )
        case .skipped:
            return SidebarStatusPresentation(
                symbol: "forward.end.circle.fill",
                color: .secondary,
                accessibilityLabel: "上次运行已跳过",
                help: runStatusSubtitle("上次运行已跳过")
            )
        case .cancelled:
            return SidebarStatusPresentation(
                symbol: "stop.circle.fill",
                color: .secondary,
                accessibilityLabel: "上次运行已取消",
                help: runStatusSubtitle("上次运行已取消")
            )
        case .attention:
            let help = task.hasValidSchedule
                ? runStatusSubtitle("运行记录已过期")
                : "计划无效"
            return SidebarStatusPresentation(
                symbol: "exclamationmark.triangle.fill",
                color: .orange,
                accessibilityLabel: "需要注意",
                help: help
            )
        case .disabled:
            return SidebarStatusPresentation(
                symbol: "pause.circle.fill",
                color: .secondary,
                accessibilityLabel: "任务已停用",
                help: "任务已停用"
            )
        }
    }

    private var status: SidebarTaskStatus {
        if isRunning { return .running }
        if !task.manifest.enabled { return .disabled }
        if !task.hasValidSchedule { return .attention }
        if let latest = task.latestRun {
            switch latest.status {
            case .pending: return .waiting
            case .running: return .running
            case .success: return .scheduled
            case .failed: return .failed
            case .timeout: return .timeout
            case .skipped: return .skipped
            case .cancelled: return .cancelled
            case .stale: return .attention
            }
        }
        return .scheduled
    }

    private var effectiveStartedAt: Date? {
        startedAt ?? task.latestRun.flatMap { $0.status == .running ? $0.startedAt : nil }
    }

    private func runStatusSubtitle(_ label: String) -> String {
        guard let date = task.latestRun?.startedAt else { return label }
        return "\(label) · \(RunShelfFormatters.scheduleDateTime(date))"
    }
}

private struct SidebarStatusPresentation {
    var symbol: String
    var color: Color
    var accessibilityLabel: String
    var help: String
}

private enum SidebarTaskStatus: Equatable {
    case scheduled
    case waiting
    case running
    case failed
    case timeout
    case skipped
    case cancelled
    case attention
    case disabled
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
