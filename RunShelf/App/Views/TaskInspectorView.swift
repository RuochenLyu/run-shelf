import SwiftUI

struct TaskInspectorView: View {
    @ObservedObject var store: TaskStore
    @EnvironmentObject private var schedulePrefs: SchedulePreferencesStore
    var task: RunShelfTask

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
                .id(task.id)
                .onDisappear {
                    store.setScheduleDraftValidity(taskID: task.id, isValid: true)
                }

                CronPreviewView(expression: task.manifest.schedule.expression, nextRunCount: 3)
            }

            Section("运行配置") {
                LabeledContent("并发") {
                    Picker("", selection: concurrencyBinding) {
                        Text("跳过重叠").tag("skip")
                        Text("允许重叠").tag("allow")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }

                LabeledContent("超时") {
                    Picker("", selection: timeoutBinding) {
                        ForEach(timeoutOptions, id: \.self) { value in
                            Text(timeoutLabel(value)).tag(value)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }

                Toggle("失败时通知", isOn: failureNotificationBinding)

                LabeledContent("保留天数") {
                    RetentionNumberField(value: retentionDaysBinding, unit: "天", range: 1...365)
                }

                LabeledContent("最多记录") {
                    RetentionNumberField(value: retentionMaxRunsBinding, unit: "次", range: 1...5000)
                }
            }

            Section {
                Button {
                    store.openTaskDirectory(id: task.id)
                } label: {
                    Label("在 Finder 中显示任务目录", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 28)
    }

    private var timeoutOptions: [Int] {
        [0, 30, 60, 120, 300, 600, 1800, 3600]
    }

    private func timeoutLabel(_ seconds: Int) -> String {
        switch seconds {
        case 0: return "不限制"
        case ..<60: return "\(seconds) 秒"
        case ..<3600: return "\(seconds / 60) 分钟"
        default: return "\(seconds / 3600) 小时"
        }
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
            get: { store.task(withID: task.id)?.manifest.runner.concurrency ?? "skip" },
            set: { value in
                store.updateTask(id: task.id) { task in
                    task.manifest.runner.concurrency = value
                }
            }
        )
    }

    private var timeoutBinding: Binding<Int> {
        Binding(
            get: {
                let current = store.task(withID: task.id)?.manifest.runner.timeoutSeconds ?? 0
                return timeoutOptions.contains(current) ? current : 0
            },
            set: { value in
                store.updateTask(id: task.id) { task in
                    task.manifest.runner.timeoutSeconds = value
                }
            }
        )
    }

    private var failureNotificationBinding: Binding<Bool> {
        Binding(
            get: { store.task(withID: task.id)?.manifest.notifications.onFailure ?? true },
            set: { value in
                store.updateTask(id: task.id) { task in
                    task.manifest.notifications.onFailure = value
                }
            }
        )
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

struct RetentionNumberField: View {
    @Binding var value: Int
    var unit: String
    var range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 6) {
            TextField("", value: clampedValue, format: .number)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 72)
            Text(unit)
                .foregroundStyle(.secondary)
        }
    }

    private var clampedValue: Binding<Int> {
        Binding(
            get: { value },
            set: { value = min(max($0, range.lowerBound), range.upperBound) }
        )
    }
}
