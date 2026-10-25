import SwiftUI

struct TaskInspectorView: View {
    @ObservedObject var store: TaskStore
    @EnvironmentObject private var schedulePrefs: SchedulePreferencesStore
    @EnvironmentObject private var schedulerController: SchedulerServiceController
    var task: RunShelfTask

    /// 用户从菜单点了「自定义…」：即使当前值正好是预设，也展开时长输入。
    @State private var isEditingCustomTimeout = false

    var body: some View {
        Form {
            Section("计划") {
                ScheduleEditorView(
                    expression: cronBinding,
                    initialMode: schedulePrefs.mode(for: task.id).flatMap(ScheduleMode.init(rawValue:)),
                    onModeChange: { newMode in
                        schedulePrefs.setMode(newMode.rawValue, for: task.id)
                    },
                    onValidityChange: { isValid in
                        store.setScheduleDraftValidity(taskID: task.id, isValid: isValid)
                    }
                )
                .onDisappear {
                    store.setScheduleDraftValidity(taskID: task.id, isValid: true)
                }

                CronPreviewView(expression: task.manifest.schedule.expression, nextRunCount: 3)

                if task.manifest.enabled && !schedulerController.isAuthorized {
                    Label("后台调度未启用；手动运行仍然可用", systemImage: "pause.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("运行配置") {
                InspectorSettingRow(title: "上次未结束") {
                    Picker("", selection: concurrencyBinding) {
                        Text("跳过本次").tag(TaskConcurrency.skip)
                        Text("排队补跑").tag(TaskConcurrency.queue)
                        Text("同时运行").tag(TaskConcurrency.allow)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }

                InspectorSettingRow(title: "优先级") {
                    Picker("", selection: priorityBinding) {
                        Text("标准").tag(TaskPriority.standard)
                        Text("后台").tag(TaskPriority.background)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }

                InspectorSettingRow(title: "超时") {
                    Picker("", selection: timeoutChoiceBinding) {
                        ForEach(Self.timeoutPresets, id: \.self) { value in
                            Text(Self.durationLabel(value)).tag(value)
                        }
                        Divider()
                        Text(customTimeoutMenuLabel).tag(Self.customTimeoutTag)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                } accessory: {
                    if showsCustomTimeoutEditor {
                        HStack(spacing: 10) {
                            RetentionNumberField(
                                value: timeoutHoursBinding,
                                unit: "小时",
                                range: 0...168,
                                fieldWidth: 44
                            )
                            RetentionNumberField(
                                value: timeoutMinutesBinding,
                                unit: "分钟",
                                range: 0...59,
                                fieldWidth: 36
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .help("运行超过这个时长会被终止。脚本可从环境变量 RUNSHELF_TIMEOUT_AT 读取截止时间，提前收尾。")

                Toggle("失败时通知", isOn: failureNotificationBinding)

                if shouldShowNotificationDeniedHint {
                    HStack(spacing: 6) {
                        Text("通知未授权")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("打开系统设置") {
                            schedulerController.openNotificationSettings()
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }

                LabeledContent("保留天数") {
                    RetentionNumberField(value: retentionDaysBinding, unit: "天", range: 1...365)
                }

                LabeledContent("最多保留") {
                    RetentionNumberField(value: retentionMaxRunsBinding, unit: "次", range: 1...5000)
                }
            }

            Section {
                Button {
                    store.openTaskDirectory(id: task.id)
                } label: {
                    Label("在 Finder 中显示", systemImage: "folder")
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 28)
    }

    static let timeoutPresets = [0, 300, 900, 1800, 3600, 7200, 10800, 14400, 21600, 43200]
    private static let customTimeoutTag = -1

    /// 精确到秒的时长文案；只显示非零的部分，例如「1 小时 15 分钟」。
    static func durationLabel(_ seconds: Int) -> String {
        guard seconds > 0 else { return "不限制" }
        let hours = seconds / 3600
        let minutes = seconds % 3600 / 60
        let remainder = seconds % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) 小时") }
        if minutes > 0 { parts.append("\(minutes) 分钟") }
        if remainder > 0 { parts.append("\(remainder) 秒") }
        return parts.joined(separator: " ")
    }

    private var currentTimeoutSeconds: Int {
        store.task(withID: task.id)?.manifest.runner.timeoutSeconds ?? 0
    }

    private var showsCustomTimeoutEditor: Bool {
        isEditingCustomTimeout || !Self.timeoutPresets.contains(currentTimeoutSeconds)
    }

    private var customTimeoutMenuLabel: String {
        // 当前值不在预设里时，菜单按钮直接显示真实时长，不再误显示成「不限制」。
        if Self.timeoutPresets.contains(currentTimeoutSeconds) {
            return "自定义…"
        }
        return "自定义：\(Self.durationLabel(currentTimeoutSeconds))"
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

    private var concurrencyBinding: Binding<String> {
        Binding(
            get: { store.task(withID: task.id)?.manifest.runner.concurrency ?? TaskConcurrency.skip },
            set: { value in
                store.updateTask(id: task.id) { task in
                    task.manifest.runner.concurrency = value
                }
            }
        )
    }

    private var priorityBinding: Binding<String> {
        Binding(
            get: { store.task(withID: task.id)?.manifest.runner.priority ?? TaskPriority.standard },
            set: { value in
                store.updateTask(id: task.id) { task in
                    task.manifest.runner.priority = value
                }
            }
        )
    }

    private var timeoutChoiceBinding: Binding<Int> {
        Binding(
            get: { showsCustomTimeoutEditor ? Self.customTimeoutTag : currentTimeoutSeconds },
            set: { value in
                if value == Self.customTimeoutTag {
                    isEditingCustomTimeout = true
                    // 从「不限制」切到自定义时给一个可直接微调的起点。
                    if currentTimeoutSeconds == 0 {
                        setTimeoutSeconds(3600)
                    }
                    return
                }
                isEditingCustomTimeout = false
                setTimeoutSeconds(value)
            }
        )
    }

    private var timeoutHoursBinding: Binding<Int> {
        Binding(
            get: { currentTimeoutSeconds / 3600 },
            set: { hours in
                setTimeoutSeconds(hours * 3600 + currentTimeoutSeconds % 3600 / 60 * 60)
            }
        )
    }

    private var timeoutMinutesBinding: Binding<Int> {
        Binding(
            get: { currentTimeoutSeconds % 3600 / 60 },
            set: { minutes in
                setTimeoutSeconds(currentTimeoutSeconds / 3600 * 3600 + minutes * 60)
            }
        )
    }

    private func setTimeoutSeconds(_ value: Int) {
        guard value != currentTimeoutSeconds else { return }
        store.updateTask(id: task.id) { task in
            task.manifest.runner.timeoutSeconds = max(value, 0)
        }
    }

    private var failureNotificationBinding: Binding<Bool> {
        Binding(
            get: { store.task(withID: task.id)?.manifest.notifications.onFailure ?? true },
            set: { value in
                store.updateTask(id: task.id) { task in
                    task.manifest.notifications.onFailure = value
                }
                if value {
                    schedulerController.requestNotificationAuthorizationIfNeeded()
                }
            }
        )
    }

    private var shouldShowNotificationDeniedHint: Bool {
        let onFailure = store.task(withID: task.id)?.manifest.notifications.onFailure ?? false
        return onFailure && schedulerController.notificationStatus == .denied
    }

    private var retentionDaysBinding: Binding<Int> {
        Binding(
            get: { store.task(withID: task.id)?.manifest.retention.days ?? 30 },
            set: { value in
                store.updateTask(id: task.id) { task in
                    task.manifest.retention.days = value
                }
            }
        )
    }

    private var retentionMaxRunsBinding: Binding<Int> {
        Binding(
            get: { store.task(withID: task.id)?.manifest.retention.maxRuns ?? 500 },
            set: { value in
                store.updateTask(id: task.id) { task in
                    task.manifest.retention.maxRuns = value
                }
            }
        )
    }
}

struct InspectorEmptyView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("从左侧选择任务查看配置")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

/// Inspector 里一行设置：左标题、右控件，下方可选的附加控件，整行共用一个分组单元格。
struct InspectorSettingRow<Control: View, Accessory: View>: View {
    var title: String
    @ViewBuilder var control: Control
    @ViewBuilder var accessory: Accessory

    init(
        title: String,
        @ViewBuilder control: () -> Control,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
        self.title = title
        self.control = control()
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(title) {
                control
            }
            accessory
        }
    }
}

struct RetentionNumberField: View {
    @Binding var value: Int
    var unit: String
    var range: ClosedRange<Int>
    var fieldWidth: CGFloat = 64

    var body: some View {
        HStack(spacing: 6) {
            TextField("", value: clampedValue, format: .number)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: fieldWidth)
            Text(unit)
                .foregroundStyle(.secondary)
            Stepper("", value: clampedValue, in: range)
                .labelsHidden()
                .fixedSize()
        }
    }

    private var clampedValue: Binding<Int> {
        Binding(
            get: { value },
            set: { value = min(max($0, range.lowerBound), range.upperBound) }
        )
    }
}
