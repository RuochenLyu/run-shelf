import SwiftUI

struct TaskHeaderView: View {
    @ObservedObject var store: TaskStore
    var task: RunShelfTask

    @State private var isShowingEditSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            titleRow
            descriptionRow
            statusRow

            let risks = DangerousCommandScanner.scan(task.script)
            if !risks.isEmpty {
                CommandRiskWarningView(risks: risks)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $isShowingEditSheet) {
            TaskEditSheet(store: store, task: task)
        }
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(displayName)
                .font(.title2.weight(.semibold))
                .lineLimit(1)

            taskMenu

            if task.isDirty {
                dirtyBadge
            }

            Spacer()

            HStack(spacing: 8) {
                Text("启用")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle("", isOn: enabledBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
        }
    }

    private var descriptionRow: some View {
        Text(descriptionDisplay)
            .font(.callout)
            .foregroundStyle(hasDescription ? .secondary : .tertiary)
            .lineLimit(2)
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            statusChip
            divider
            Label(scheduleSummary, systemImage: "calendar")
            divider
            Label(nextRunText, systemImage: "arrow.right.circle")
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
    }

    private var divider: some View {
        Text("·")
            .foregroundStyle(.tertiary)
    }

    private var taskMenu: some View {
        Menu {
            Button {
                isShowingEditSheet = true
            } label: {
                Label("编辑任务", systemImage: "pencil")
            }

            Divider()

            Button {
                store.saveTask(id: task.id)
            } label: {
                Label("保存更改", systemImage: "square.and.arrow.down")
            }
            .disabled(!store.canSaveTask(task))

            Button(role: .destructive) {
                store.revertTask(id: task.id)
            } label: {
                Label("放弃更改", systemImage: "arrow.uturn.backward")
            }
            .disabled(!task.isDirty)

            Divider()

            Button {
                store.openTaskDirectory(id: task.id)
            } label: {
                Label("显示任务目录", systemImage: "folder")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.callout.weight(.semibold))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("更多")
    }

    private var statusChip: some View {
        let (text, color, symbol) = currentStatus()
        return Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var dirtyBadge: some View {
        Text("未保存")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.orange.opacity(0.12), in: Capsule())
    }

    private var displayName: String {
        let name = task.manifest.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "未命名任务" : name
    }

    private var scheduleSummary: String {
        (try? CronSchedule.parse(task.manifest.schedule.expression).summary) ?? task.manifest.schedule.expression
    }

    private var nextRunText: String {
        guard task.manifest.enabled else { return "已停用" }
        guard let schedule = try? CronSchedule.parse(task.manifest.schedule.expression) else {
            return "表达式无效"
        }
        let dates = try? schedule.nextRuns(count: 1)
        guard let date = dates?.first else { return "暂无" }
        return RunShelfFormatters.scheduleDateTime(date)
    }

    private func currentStatus() -> (String, Color, String) {
        if store.runningTaskIDs.contains(task.id) {
            return ("运行中", .blue, "arrow.triangle.2.circlepath")
        }
        if !task.manifest.enabled {
            return ("已停用", .secondary, "pause.circle.fill")
        }
        if let latest = task.latestRun {
            switch latest.status {
            case .failed, .timeout:
                return ("上次\(latest.status.displayName)", .red, latest.status.statusSymbol)
            case .stale:
                return ("已过期", .orange, latest.status.statusSymbol)
            case .skipped:
                return ("上次跳过", .orange, latest.status.statusSymbol)
            case .cancelled:
                return ("上次已取消", .secondary, latest.status.statusSymbol)
            case .success, .running, .pending:
                return ("已启用", .green, "circle.fill")
            }
        }
        return ("已启用", .green, "circle.fill")
    }

    private var hasDescription: Bool {
        !task.manifest.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var descriptionDisplay: String {
        hasDescription ? task.manifest.description : "无描述"
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
}

private struct TaskEditSheet: View {
    @ObservedObject var store: TaskStore
    @Environment(\.dismiss) private var dismiss

    let taskID: String
    @State private var name: String
    @State private var description: String

    init(store: TaskStore, task: RunShelfTask) {
        self.store = store
        self.taskID = task.id
        _name = State(initialValue: task.manifest.name)
        _description = State(initialValue: task.manifest.description)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("编辑任务")
                    .font(.title2.weight(.semibold))
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("名称")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("任务名称", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("描述")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextEditor(text: $description)
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .frame(height: 92)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.7))
                    }
            }

            HStack {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("保存") {
                    commit()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func commit() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        store.updateTask(id: taskID) { task in
            task.manifest.name = trimmedName
            task.manifest.description = trimmedDescription
        }
    }
}

struct CommandRiskWarningView: View {
    var risks: [CommandRisk]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("脚本包含需要复核的命令", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)

            ForEach(risks) { risk in
                Text("• \(risk.message)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

extension TaskRunStatus {
    var statusSymbol: String {
        switch self {
        case .pending: return "circle"
        case .running: return "arrow.triangle.2.circlepath"
        case .success: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .skipped: return "minus.circle.fill"
        case .timeout: return "clock.badge.exclamationmark.fill"
        case .cancelled: return "stop.circle.fill"
        case .stale: return "exclamationmark.triangle.fill"
        }
    }
}
