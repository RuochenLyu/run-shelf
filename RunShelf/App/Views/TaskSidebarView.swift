import SwiftUI

struct TaskSidebarView: View {
    @ObservedObject var store: TaskStore

    var body: some View {
        List(selection: $store.selectedTaskID) {
            ForEach(store.sortedTasks) { task in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(statusColor(for: task))
                            .frame(width: 7, height: 7)

                        Text(displayName(for: task))
                            .font(.body.weight(.medium))
                            .lineLimit(1)

                        Spacer()
                    }

                    Text(verbatim: subtitle(for: task))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.vertical, 5)
                .tag(task.id)
            }
        }
        .navigationTitle("任务")
    }

    private func displayName(for task: RunShelfTask) -> String {
        let name = task.manifest.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "未命名任务" : name
    }

    private func subtitle(for task: RunShelfTask) -> String {
        guard task.manifest.enabled else {
            return "已停用"
        }
        guard let schedule = try? CronSchedule.parse(task.manifest.schedule.expression) else {
            return task.manifest.schedule.expression
        }

        let nextRuns = try? schedule.nextRuns(count: 1)
        if let nextRun = nextRuns?.first {
            return "\(schedule.summary) · \(RunShelfFormatters.scheduleDateTime(nextRun))"
        }
        return schedule.summary
    }

    private func statusColor(for task: RunShelfTask) -> Color {
        if store.runningTaskIDs.contains(task.id) {
            return .blue
        }
        if let latestRun = task.latestRun {
            return latestRun.status.badgeColor
        }
        return task.manifest.enabled ? .green : .secondary
    }
}
