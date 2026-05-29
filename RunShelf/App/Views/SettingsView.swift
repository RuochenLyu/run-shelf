import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var controller: SchedulerServiceController
    @AppStorage(RunShelfSettings.defaultRetentionDaysKey) private var defaultRetentionDays = RunShelfSettings.defaultRetentionDays
    @AppStorage(RunShelfSettings.defaultRetentionMaxRunsKey) private var defaultRetentionMaxRuns = RunShelfSettings.defaultRetentionMaxRuns

    var body: some View {
        Form {
            Section("数据") {
                LabeledContent("任务目录") {
                    HStack(spacing: 6) {
                        Text(RunShelfPaths.tasksDirectoryURL().path)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([RunShelfPaths.tasksDirectoryURL()])
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless)
                        .help("在 Finder 中显示")
                    }
                }
            }

            Section("后台调度") {
                HStack {
                    Label(schedulerStateText, systemImage: schedulerStateSymbol)
                        .foregroundStyle(schedulerStateColor)
                    Spacer()
                    Button(action: schedulerPrimaryAction) {
                        Text(schedulerActionLabel)
                    }
                    .controlSize(.small)
                    .disabled(!controller.embeddedSchedulerAvailable)
                }

                if controller.serviceStatus == .enabled, let heartbeat = controller.heartbeat {
                    LabeledContent("最近活动", value: heartbeatDescription(heartbeat))
                        .foregroundStyle(.secondary)
                }

                if let hint = schedulerHint {
                    Text(hint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("通知") {
                HStack {
                    Label(notificationStateText, systemImage: notificationSymbol)
                        .foregroundStyle(notificationColor)
                    Spacer()
                    Button(action: notificationPrimaryAction) {
                        Text(notificationActionLabel)
                    }
                    .controlSize(.small)
                }

                if let hint = notificationHint {
                    Text(hint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("保留天数") {
                    RetentionNumberField(value: defaultRetentionDaysBinding, unit: "天", range: 1...365)
                }
                LabeledContent("最多保留") {
                    RetentionNumberField(value: defaultRetentionMaxRunsBinding, unit: "次", range: 1...5000)
                }
            } header: {
                Text("日志保留")
            } footer: {
                Text("仅影响新建任务；每个任务可在右侧检查器中单独调整。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 600)
        .onAppear {
            controller.refresh()
        }
        .alert("Run Shelf", isPresented: errorBinding) {
            Button("知道了", role: .cancel) {
                controller.lastErrorMessage = nil
            }
        } message: {
            Text(controller.lastErrorMessage ?? "")
        }
    }

    // MARK: - Scheduler section

    private var schedulerStateText: String {
        if !controller.embeddedSchedulerAvailable {
            return "组件缺失"
        }
        switch controller.serviceStatus {
        case .enabled: return "正在后台运行"
        case .notRegistered, .notFound: return "未启用"
        case .requiresApproval: return "等待授权"
        @unknown default: return "未知"
        }
    }

    private var schedulerStateSymbol: String {
        switch controller.serviceStatus {
        case .enabled: return "checkmark.circle.fill"
        case .requiresApproval: return "exclamationmark.triangle.fill"
        case .notRegistered, .notFound: return "pause.circle.fill"
        @unknown default: return "questionmark.circle.fill"
        }
    }

    private var schedulerStateColor: Color {
        switch controller.serviceStatus {
        case .enabled: return .green
        case .requiresApproval: return .orange
        default: return .secondary
        }
    }

    private var schedulerHint: String? {
        if !controller.embeddedSchedulerAvailable {
            return "应用文件不完整，请重新安装 Run Shelf。"
        }
        switch controller.serviceStatus {
        case .enabled:
            return nil
        case .notRegistered, .notFound:
            return "点击启用后会注册后台调度组件。多数情况下会直接完成；如需确认，macOS 会要求你前往系统设置。"
        case .requiresApproval:
            return "请在系统设置中开启 Run Shelf 的登录项。"
        @unknown default:
            return nil
        }
    }

    private var schedulerActionLabel: String {
        switch controller.serviceStatus {
        case .enabled: return "管理登录项"
        case .requiresApproval: return "前往系统设置"
        case .notRegistered, .notFound: return "启用后台运行"
        @unknown default: return "重试"
        }
    }

    private func schedulerPrimaryAction() {
        switch controller.serviceStatus {
        case .enabled, .requiresApproval:
            controller.openLoginItemsSettings()
        case .notRegistered, .notFound:
            controller.register()
        @unknown default:
            controller.refresh()
        }
    }

    // MARK: - Notification section

    private var notificationStateText: String {
        switch controller.notificationStatus {
        case .authorized: return "已允许"
        case .provisional, .ephemeral: return "已临时允许"
        case .denied: return "已拒绝"
        case .notDetermined: return "未授权"
        @unknown default: return "未知"
        }
    }

    private var notificationSymbol: String {
        switch controller.notificationStatus {
        case .authorized, .provisional, .ephemeral: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        default: return "bell.slash"
        }
    }

    private var notificationColor: Color {
        switch controller.notificationStatus {
        case .authorized, .provisional, .ephemeral: return .green
        case .denied: return .red
        default: return .secondary
        }
    }

    private var notificationHint: String? {
        switch controller.notificationStatus {
        case .authorized, .provisional, .ephemeral:
            return "任务失败时会发送系统通知。"
        case .denied:
            return "请在系统设置中重新允许 Run Shelf 的通知。"
        case .notDetermined:
            return "首次创建任务时会请求授权。"
        @unknown default:
            return nil
        }
    }

    private var notificationActionLabel: String {
        switch controller.notificationStatus {
        case .notDetermined: return "请求授权"
        default: return "打开系统设置"
        }
    }

    private func notificationPrimaryAction() {
        switch controller.notificationStatus {
        case .notDetermined:
            controller.requestNotificationAuthorization()
        default:
            controller.openNotificationSettings()
        }
    }

    // MARK: - Bindings

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { controller.lastErrorMessage != nil },
            set: { if !$0 { controller.lastErrorMessage = nil } }
        )
    }

    private var defaultRetentionDaysBinding: Binding<Int> {
        Binding(
            get: { defaultRetentionDays },
            set: { defaultRetentionDays = min(max($0, 1), 365) }
        )
    }

    private var defaultRetentionMaxRunsBinding: Binding<Int> {
        Binding(
            get: { defaultRetentionMaxRuns },
            set: { defaultRetentionMaxRuns = min(max($0, 1), 5000) }
        )
    }

    private func heartbeatDescription(_ heartbeat: SchedulerHeartbeat) -> String {
        let text = RunShelfFormatters.dateTimeWithSeconds(heartbeat.checkedAt)
        let fresh = Date().timeIntervalSince(heartbeat.checkedAt) <= 90
        return fresh ? text : "\(text)（已过期）"
    }
}
