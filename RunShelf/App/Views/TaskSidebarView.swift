import SwiftUI

struct TaskSidebarView: View {
    @ObservedObject var store: TaskStore

    var body: some View {
        List(selection: $store.selectedTaskID) {
            ForEach(store.sortedTasks) { task in
                TaskSidebarRow(task: task, isRunning: store.runningTaskIDs.contains(task.id))
                    .tag(task.id)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("任务")
    }
}

private struct TaskSidebarRow: View {
    var task: RunShelfTask
    var isRunning: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
                .imageScale(.small)
                .frame(width: 14)

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
        }
        .padding(.vertical, 3)
    }

    private var displayName: String {
        let name = task.manifest.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "未命名任务" : name
    }

    private var subtitle: String {
        guard task.manifest.enabled else {
            return "已停用"
        }
        guard let schedule = try? CronSchedule.parse(task.manifest.schedule.expression) else {
            return task.manifest.schedule.expression
        }

        if let next = try? schedule.nextRuns(count: 1).first {
            return "\(schedule.summary) · \(RunShelfFormatters.scheduleDateTime(next))"
        }
        return schedule.summary
    }

    private var statusSymbol: String {
        if isRunning {
            return "arrow.triangle.2.circlepath"
        }
        if let latest = task.latestRun {
            return latest.status.statusSymbol
        }
        if task.manifest.enabled {
            return "circle.fill"
        }
        return "pause.circle.fill"
    }

    private var statusColor: Color {
        if isRunning {
            return .blue
        }
        if let latest = task.latestRun {
            return latest.status.badgeColor
        }
        return task.manifest.enabled ? .green : .secondary
    }
}
