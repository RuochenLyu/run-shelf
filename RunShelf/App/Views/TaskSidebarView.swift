import SwiftUI

struct TaskSidebarView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var selection: TaskSelectionState
    @State private var editingTaskID: String? = nil

    var body: some View {
        List(selection: $selection.selectedTaskID) {
            ForEach(store.sortedTasks) { task in
                TaskSidebarRow(
                    task: task,
                    isRunning: store.runningTaskIDs.contains(task.id),
                    startedAt: store.runningStartedAt[task.id]
                )
                .tag(task.id)
                .contextMenu { contextMenu(for: task) }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("任务")
        .sheet(item: editingTaskBinding) { task in
            TaskEditSheet(store: store, task: task)
        }
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
            if isRunning {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 14)
            } else {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusColor)
                    .imageScale(.small)
                    .frame(width: 14)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(displayName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    TaskOriginBadge(origin: task.manifest.origin)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let startedAt {
                RunningDurationText(startedAt: startedAt)
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
        guard task.manifest.enabled else {
            return "未启用"
        }
        guard let schedule = try? CronSchedule.parse(task.manifest.schedule.expression) else {
            return task.manifest.schedule.expression
        }

        if let next = try? schedule.nextRuns(count: 1).first {
            return "\(schedule.summary) · \(RunShelfFormatters.scheduleDateTime(next))"
        }
        return schedule.summary
    }

    // 状态优先级：
    //   1. 运行中
    //   2. 已停用（覆盖历史 run 状态，避免「已停用 + 绿色✓」歧义）
    //   3. 上次失败/超时
    //   4. 上次跳过/过期
    //   5. 启用且正常
    private var statusSymbol: String {
        if isRunning { return "arrow.triangle.2.circlepath" }
        if !task.manifest.enabled { return "pause.circle.fill" }
        if let latest = task.latestRun {
            switch latest.status {
            case .failed, .timeout:    return "exclamationmark.circle.fill"
            case .skipped, .stale:     return "exclamationmark.triangle.fill"
            case .cancelled:           return "stop.circle.fill"
            case .success, .running, .pending:
                return "circle.fill"
            }
        }
        return "circle.fill"
    }

    private var statusColor: Color {
        if isRunning { return .blue }
        if !task.manifest.enabled { return .secondary }
        if let latest = task.latestRun {
            switch latest.status {
            case .failed, .timeout:    return .red
            case .skipped, .stale:     return .orange
            case .cancelled:           return .secondary
            case .success, .running, .pending:
                return .green
            }
        }
        return .green
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
