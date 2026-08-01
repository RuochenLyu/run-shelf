import SwiftUI

struct TaskHeaderView: View {
    @ObservedObject var store: TaskStore
    var task: RunShelfTask
    var titleLeadingInset: CGFloat = 0

    @State private var isShowingEditSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleRow
                .frame(height: 50, alignment: .center)
            if hasDescription {
                descriptionRow
            }
            statusRow

            let risks = DangerousCommandScanner.scan(task.script)
            if !risks.isEmpty {
                CommandRiskWarningView(risks: risks)
                    .padding(.top, 4)
            }
        }
        .padding(.leading, 24 + titleLeadingInset)
        .padding(.trailing, 24)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(nil, value: titleLeadingInset)
        .transaction { transaction in
            transaction.animation = nil
        }
        .sheet(isPresented: $isShowingEditSheet) {
            TaskEditSheet(store: store, task: task)
        }
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(displayName)
                .font(.title3.weight(.semibold))
                .lineLimit(1)

            moreMenu

            if task.isDirty {
                dirtyBadge
            }

            Spacer()

            Toggle(isOn: enabledBinding) {
                Text("启用")
                    .font(.callout)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    private var descriptionRow: some View {
        Text(task.manifest.description)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            if let startedAt = store.runningStartedAt[task.id] {
                runningChip(startedAt: startedAt)
                divider
            } else if let chip = abnormalStatusChip {
                chip
                divider
            }
            Label(scheduleSummary, systemImage: "calendar")
                .font(.callout)
                .foregroundStyle(.secondary)
            divider
            Label(nextRunText, systemImage: "arrow.right.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
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

    private var divider: some View {
        Text("·")
            .foregroundStyle(.tertiary)
    }

    private func runningChip(startedAt: Date) -> some View {
        HStack(spacing: 4) {
            ProgressView()
                .controlSize(.mini)
            Text("运行中")
            Text("·")
                .foregroundStyle(.tertiary)
            RunningDurationText(startedAt: startedAt)
                .monospacedDigit()
            Button {
                store.cancelTask(id: task.id)
            } label: {
                Image(systemName: "stop.fill")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("停止运行")
            .help("停止运行")
            .disabled(!store.canCancelTask(id: task.id))
        }
        .font(.callout)
        .foregroundStyle(.blue)
    }

    private var abnormalStatusChip: AnyView? {
        guard let status = abnormalStatus() else { return nil }
        return AnyView(
            Label(status.text, systemImage: status.symbol)
                .font(.callout)
                .foregroundStyle(status.color)
                .labelStyle(.titleAndIcon)
        )
    }

    private var scheduleSummary: String {
        (try? CronSchedule.parse(task.manifest.schedule.expression).summary) ?? task.manifest.schedule.expression
    }

    private var nextRunText: String {
        guard task.manifest.enabled else { return "未启用" }
        guard let schedule = try? CronSchedule.parse(task.manifest.schedule.expression) else {
            return "计划无效"
        }
        let dates = try? schedule.nextRuns(count: 1)
        guard let date = dates?.first else { return "暂无" }
        return "\(RunShelfFormatters.scheduleDateTime(date)) · \(RunShelfFormatters.relativeFuture(date))"
    }

    private func abnormalStatus() -> (text: String, color: Color, symbol: String)? {
        if store.runningTaskIDs.contains(task.id) {
            return nil
        }
        if !task.manifest.enabled {
            return ("未启用", .secondary, "pause.circle.fill")
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
                return nil
            }
        }
        return nil
    }

    private var displayName: String {
        let name = task.manifest.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "未命名任务" : name
    }

    private var hasDescription: Bool {
        !task.manifest.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var moreMenu: some View {
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
                Label("保存更改", systemImage: "checkmark.circle")
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
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("更多操作")
        .accessibilityIdentifier("task-more-actions")
        .help("更多")
    }

    private var dirtyBadge: some View {
        Text("未保存")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.orange.opacity(0.12), in: Capsule())
    }
}

struct TaskEditSheet: View {
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
        VStack(spacing: 0) {
            HStack {
                Text("编辑任务")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 4)

            Form {
                Section {
                    LabeledContent {
                        TextField("", text: $name, prompt: Text("任务名称"))
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                    } label: {
                        Text("名称")
                    }

                    LabeledContent {
                        TextField("", text: $description, prompt: Text("无"), axis: .vertical)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.leading)
                            .lineLimit(1...4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text("描述")
                    }
                }
            }
            .formStyle(.grouped)

            HStack(spacing: 10) {
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
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 460, height: 320)
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
