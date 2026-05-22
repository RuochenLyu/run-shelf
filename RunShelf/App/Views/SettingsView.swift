import AppKit
import SwiftUI

struct SettingsView: View {
    @StateObject private var controller = SchedulerServiceController()
    @AppStorage(RunShelfSettings.defaultRetentionDaysKey) private var defaultRetentionDays = RunShelfSettings.defaultRetentionDays
    @AppStorage(RunShelfSettings.defaultRetentionMaxRunsKey) private var defaultRetentionMaxRuns = RunShelfSettings.defaultRetentionMaxRuns

    var body: some View {
        Form {
            Section("数据") {
                LabeledContent("任务存储目录", value: RunShelfPaths.tasksDirectoryURL().path)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([RunShelfPaths.appSupportDirectoryURL()])
                } label: {
                    Label("打开数据目录", systemImage: "externaldrive")
                }
            }

            Section("后台调度进程") {
                LabeledContent("状态", value: controller.serviceStatusDisplayName)
                LabeledContent("嵌入状态", value: controller.embeddedSchedulerAvailable ? "已找到" : "缺失")

                if let heartbeat = controller.heartbeat {
                    LabeledContent("心跳", value: heartbeatText(heartbeat))
                    LabeledContent(isHeartbeatFresh(heartbeat) ? "PID" : "上次 PID", value: "\(heartbeat.pid)")
                    LabeledContent("运行中任务", value: "\(heartbeat.runningTaskIDs.count)")
                    if let error = heartbeat.lastError, !error.isEmpty {
                        LabeledContent("最近错误", value: error)
                    }
                } else {
                    LabeledContent("心跳", value: "暂无")
                }

                HStack {
                    Button {
                        controller.register()
                    } label: {
                        Label("启动", systemImage: "power")
                    }
                    .disabled(controller.serviceStatus == .enabled)

                    Button {
                        controller.unregister()
                    } label: {
                        Label("停止", systemImage: "stop.fill")
                    }
                    .disabled(controller.serviceStatus == .notRegistered || controller.serviceStatus == .notFound)

                    Button {
                        controller.refresh()
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                }
            }

            Section("通知") {
                LabeledContent("授权状态", value: controller.notificationStatus.displayName)
                Button {
                    controller.requestNotificationAuthorization()
                } label: {
                    Label("请求通知权限", systemImage: "bell.badge")
                }
                .disabled(controller.notificationStatus == .authorized)
            }

            Section("保留策略") {
                Stepper(value: $defaultRetentionDays, in: 1...365) {
                    LabeledContent("默认日志保留天数", value: "\(defaultRetentionDays) 天")
                }
                Stepper(value: $defaultRetentionMaxRuns, in: 1...5000, step: 50) {
                    LabeledContent("默认最大运行记录", value: "\(defaultRetentionMaxRuns) 次/任务")
                }
                Text("每个任务会按自己的 task.json 保留策略清理 runs 目录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 520)
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

    private func heartbeatText(_ heartbeat: SchedulerHeartbeat) -> String {
        let text = RunShelfFormatters.dateTimeWithSeconds(heartbeat.checkedAt)
        return isHeartbeatFresh(heartbeat) ? text : "\(text)（已过期）"
    }

    private func isHeartbeatFresh(_ heartbeat: SchedulerHeartbeat) -> Bool {
        Date().timeIntervalSince(heartbeat.checkedAt) <= 90
    }
}
