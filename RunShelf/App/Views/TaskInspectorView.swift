import SwiftUI

struct TaskInspectorView: View {
    @ObservedObject var store: TaskStore
    var task: RunShelfTask

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                scheduleSection
                runnerSection
                historySection
                directoryButton
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var scheduleSection: some View {
        InspectorSection("计划") {
            VStack(alignment: .leading, spacing: 10) {
                ScheduleEditorView(expression: cronBinding) { isValid in
                    store.setScheduleDraftValidity(taskID: task.id, isValid: isValid)
                }
                .onDisappear {
                    store.setScheduleDraftValidity(taskID: task.id, isValid: true)
                }
                CronPreviewView(expression: task.manifest.schedule.expression, nextRunCount: 3)
            }
        }
    }

    private var runnerSection: some View {
        InspectorSection("运行配置") {
            InspectorGroup {
                InspectorValueRow(title: "并发", value: concurrencyText)
                Divider()
                InspectorValueRow(title: "超时", value: timeoutText)
                Divider()
                InspectorValueRow(title: "失败通知", value: task.manifest.notifications.onFailure ? "开启" : "关闭")
                Divider()
                InspectorValueRow(title: "日志保留", value: "\(task.manifest.retention.days) 天 / \(task.manifest.retention.maxRuns) 次")
            }
        }
    }

    private var historySection: some View {
        InspectorSection("运行历史") {
            InspectorGroup {
                if task.runs.isEmpty {
                    Text("暂无运行记录")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                } else {
                    let runs = Array(task.runs.prefix(12))
                    ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                        RunHistoryRow(
                            run: run,
                            isSelected: store.selectedRunID == run.runId,
                            onSelect: { store.selectedRunID = run.runId }
                        )
                        if index < runs.count - 1 {
                            Divider()
                                .padding(.leading, 38)
                        }
                    }
                }
            }
        }
    }

    private var directoryButton: some View {
        Button {
            store.openTaskDirectory(id: task.id)
        } label: {
            Label("显示任务目录", systemImage: "folder")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }

    private var concurrencyText: String {
        task.manifest.runner.concurrency == "allow" ? "允许重叠" : "跳过重叠"
    }

    private var timeoutText: String {
        task.manifest.runner.timeoutSeconds == 0 ? "不限制" : "\(task.manifest.runner.timeoutSeconds) 秒"
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
}

private struct InspectorSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InspectorGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct InspectorValueRow: View {
    var title: String
    var value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct RunHistoryRow: View {
    var run: RunRecord
    var isSelected: Bool
    var onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: run.status.statusSymbol)
                    .foregroundStyle(run.status.badgeColor)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(RunShelfFormatters.dateTime(run.startedAt))
                        .font(.callout)
                        .lineLimit(1)
                    Text(secondaryLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(selectionBackground, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private var selectionBackground: Color {
        isSelected ? Color.accentColor.opacity(0.10) : Color.clear
    }

    private var secondaryLine: String {
        var parts: [String] = [run.status.displayName, run.trigger.displayName]
        if let duration = run.durationMs {
            parts.append(RunShelfFormatters.duration(duration))
        }
        return parts.joined(separator: " · ")
    }
}
