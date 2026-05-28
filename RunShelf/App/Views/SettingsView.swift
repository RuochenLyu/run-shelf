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
                    Text(RunShelfPaths.tasksDirectoryURL().path)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([RunShelfPaths.tasksDirectoryURL()])
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
                } else if !controller.isAuthorized {
                    Text("自动调度已停止。下次启动 Run Shelf 时会要求重新启用。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
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
                LabeledContent("保留天数") {
                    RetentionNumberField(value: defaultRetentionDaysBinding, unit: "天", range: 1...365)
                }
                LabeledContent("最多记录") {
                    RetentionNumberField(value: defaultRetentionMaxRunsBinding, unit: "次", range: 1...5000)
                }
                Text("仅影响新建任务；每个任务可在右侧检查器中单独调整。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 540)
        .onAppear {
            controller.refresh()
        }
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
