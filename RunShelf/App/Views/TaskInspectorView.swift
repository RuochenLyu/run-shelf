import SwiftUI

struct TaskInspectorView: View {
    @ObservedObject var store: TaskStore
    var task: RunShelfTask

    @State private var isEditingSchedule = false
    @State private var isEditingTask = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                statusSection
                detailsSection
                historySection
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 28)
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("状态")

            HStack {
                TaskStatusBadge(store: store, task: task)
                Spacer()
                Toggle("", isOn: enabledBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel("启用任务")
            }

            InspectorRow(title: "下次运行", value: nextRunText)
            InspectorRow(title: "上次运行时间", value: latestRunText)
        }
    }

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("详情")

            InspectorRow(title: "计划", value: scheduleSummary)
            InspectorRow(title: "Cron", value: task.manifest.schedule.expression, monospaced: true)
            InspectorRow(title: "并发", value: task.manifest.runner.concurrency == "allow" ? "允许重叠" : "跳过重叠")
            InspectorRow(title: "超时", value: task.manifest.runner.timeoutSeconds == 0 ? "不限制" : "\(task.manifest.runner.timeoutSeconds) 秒")
            InspectorRow(title: "失败通知", value: task.manifest.notifications.onFailure ? "开启" : "关闭")
            InspectorRow(title: "保留", value: "\(task.manifest.retention.days) 天 / \(task.manifest.retention.maxRuns) 次")

            DisclosureGroup(isExpanded: $isEditingTask) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("任务名", text: nameBinding)
                        .textFieldStyle(.roundedBorder)
                    TextField("说明", text: descriptionBinding)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.top, 8)
            } label: {
                Label("编辑任务", systemImage: "slider.horizontal.3")
            }

            DisclosureGroup(isExpanded: $isEditingSchedule) {
                VStack(alignment: .leading, spacing: 10) {
                    ScheduleEditorView(expression: cronBinding)
                    CronPreviewView(expression: task.manifest.schedule.expression)
                }
                .padding(.top, 8)
            } label: {
                Label("编辑计划", systemImage: "calendar.badge.clock")
            }

            HStack {
                Button {
                    store.openTaskDirectory(id: task.id)
                } label: {
                    Label("任务目录", systemImage: "folder")
                }

                Button {
                    store.openTasksDirectory()
                } label: {
                    Label("数据目录", systemImage: "externaldrive")
                }
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("运行历史")

            if task.runs.isEmpty {
                Text("暂无运行记录")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(task.runs.prefix(12))) { run in
                        RunHistoryCompactRow(run: run)
                    }
                }
            }
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { store.task(withID: task.id)?.manifest.enabled ?? false },
            set: { value in
                store.updateTask(id: task.id) { task in
                    task.manifest.enabled = value
                }
            }
        )
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { store.task(withID: task.id)?.manifest.name ?? "" },
            set: { value in
                store.updateTask(id: task.id) { task in
                    task.manifest.name = value
                }
            }
        )
    }

    private var descriptionBinding: Binding<String> {
        Binding(
            get: { store.task(withID: task.id)?.manifest.description ?? "" },
            set: { value in
                store.updateTask(id: task.id) { task in
                    task.manifest.description = value
                }
            }
        )
    }

    private var cronBinding: Binding<String> {
        Binding(
            get: { store.task(withID: task.id)?.manifest.schedule.expression ?? "" },
            set: { value in
                store.updateTask(id: task.id) { task in
                    task.manifest.schedule.expression = value
                }
            }
        )
    }

    private var schedule: CronSchedule? {
        try? CronSchedule.parse(task.manifest.schedule.expression)
    }

    private var scheduleSummary: String {
        schedule?.summary ?? "表达式无效"
    }

    private var nextRunText: String {
        guard task.manifest.enabled else { return "已停用" }
        guard let schedule else { return "表达式无效" }
        let dates = try? schedule.nextRuns(count: 1)
        guard let date = dates?.first else { return "暂无" }
        return RunShelfFormatters.scheduleDateTime(date)
    }

    private var latestRunText: String {
        guard let latestRun = task.latestRun else { return "暂无" }
        return RunShelfFormatters.dateTime(latestRun.startedAt)
    }
}

private struct SectionTitle: View {
    var title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.secondary)
    }
}

private struct InspectorRow: View {
    var title: String
    var value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            Spacer(minLength: 16)
            Text(verbatim: value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

private struct RunHistoryCompactRow: View {
    var run: RunRecord

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(run.status.badgeColor)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                Text(RunShelfFormatters.dateTime(run.startedAt))
                    .lineLimit(1)
                Text("\(run.status.displayName) · \(run.trigger.displayName) · \(RunShelfFormatters.duration(run.durationMs))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
