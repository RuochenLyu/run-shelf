import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @StateObject private var controller = SchedulerServiceController()
    @AppStorage(RunShelfSettings.defaultRetentionDaysKey) private var defaultRetentionDays = RunShelfSettings.defaultRetentionDays
    @AppStorage(RunShelfSettings.defaultRetentionMaxRunsKey) private var defaultRetentionMaxRuns = RunShelfSettings.defaultRetentionMaxRuns

    var body: some View {
        Form {
            Section("数据") {
                LabeledContent("任务目录") {
                    Text(RunShelfPaths.tasksDirectoryURL().path)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([RunShelfPaths.appSupportDirectoryURL()])
                } label: {
                    Label("在 Finder 中显示", systemImage: "folder")
                }
            }

            Section("后台调度") {
                LabeledContent("状态") {
                    Label(schedulerStateText, systemImage: schedulerStateSymbol)
                        .foregroundStyle(schedulerStateColor)
                }

                if let heartbeat = controller.heartbeat {
                    LabeledContent("最近心跳", value: heartbeatDescription(heartbeat))
                }

                HStack {
                    Button {
                        controller.register()
                    } label: {
                        Label("启动并开机自启", systemImage: "power")
                    }
                    .disabled(controller.serviceStatus == .enabled || !controller.embeddedSchedulerAvailable)

                    Button(role: .destructive) {
                        controller.unregister()
                    } label: {
                        Label("停止", systemImage: "stop.fill")
                    }
                    .disabled(controller.serviceStatus != .enabled)

                    Spacer()

                    Button {
                        controller.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("刷新状态")
                }

                if controller.serviceStatus == .requiresApproval {
                    Text("macOS 已阻止 Run Shelf 在登录时启动调度器。请前往「系统设置 › 通用 › 登录项」启用 Run Shelf。")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }

            Section("通知") {
                LabeledContent("失败通知授权") {
                    Label(controller.notificationStatus.displayName, systemImage: notificationSymbol)
                        .foregroundStyle(notificationColor)
                }
                if controller.notificationStatus != .authorized {
                    Button {
                        controller.requestNotificationAuthorization()
                    } label: {
                        Label("请求通知权限", systemImage: "bell.badge")
                    }
                }
            }

            Section("日志保留默认值") {
                Stepper(value: $defaultRetentionDays, in: 1...365) {
                    LabeledContent("保留天数", value: "\(defaultRetentionDays) 天")
                }
                Stepper(value: $defaultRetentionMaxRuns, in: 50...5000, step: 50) {
                    LabeledContent("最多记录", value: "\(defaultRetentionMaxRuns) 次")
                }
                Text("仅影响新建任务；每个任务可在自己的 task.json 中改写策略。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 540)
        .alert("Run Shelf", isPresented: errorBinding) {
            Button("好", role: .cancel) {
                controller.lastErrorMessage = nil
            }
        } message: {
            Text(controller.lastErrorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { controller.lastErrorMessage != nil },
            set: { if !$0 { controller.lastErrorMessage = nil } }
        )
    }

    private var schedulerStateText: String {
        switch controller.serviceStatus {
        case .enabled: return "运行中"
        case .notRegistered:
            return controller.embeddedSchedulerAvailable ? "已停止" : "组件缺失"
        case .requiresApproval: return "需要批准"
        case .notFound: return "组件缺失"
        @unknown default: return "未知"
        }
    }

    private var schedulerStateSymbol: String {
        switch controller.serviceStatus {
        case .enabled: return "checkmark.circle.fill"
        case .notRegistered, .notFound: return "pause.circle.fill"
        case .requiresApproval: return "exclamationmark.triangle.fill"
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

    private var notificationSymbol: String {
        switch controller.notificationStatus {
        case .authorized, .provisional, .ephemeral: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        default: return "questionmark.circle.fill"
        }
    }

    private var notificationColor: Color {
        switch controller.notificationStatus {
        case .authorized, .provisional, .ephemeral: return .green
        case .denied: return .red
        default: return .secondary
        }
    }

    private func heartbeatDescription(_ heartbeat: SchedulerHeartbeat) -> String {
        let text = RunShelfFormatters.dateTimeWithSeconds(heartbeat.checkedAt)
        let fresh = Date().timeIntervalSince(heartbeat.checkedAt) <= 90
        return fresh ? text : "\(text)（已过期）"
    }
}
