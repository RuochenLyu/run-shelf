import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var controller: SchedulerServiceController
    @AppStorage(RunShelfSettings.defaultRetentionDaysKey) private var defaultRetentionDays = RunShelfSettings.defaultRetentionDays
    @AppStorage(RunShelfSettings.defaultRetentionMaxRunsKey) private var defaultRetentionMaxRuns = RunShelfSettings.defaultRetentionMaxRuns
    @State private var cliStatus: RunShelfCLIInstallationStatus?
    @State private var cliFeedback: String?
    @State private var isShowingAgentWritePreview = false

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
                        .accessibilityLabel("在 Finder 中显示任务目录")
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

            Section("命令行与 AI Agent") {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(cliStatus?.isInstalled == true ? "runshelf 命令已安装" : "在终端中使用 runshelf")
                        if let status = cliStatus, status.isInstalled {
                            Text("\(status.path) · 版本 \(appVersion)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer()
                    Button(cliStatus?.isInstalled == true ? "已安装" : "安装 runshelf 命令") {
                        installCommandLineTool()
                    }
                    .controlSize(.small)
                    .disabled(embeddedCLIURL == nil || cliStatus?.isInstalled == true)
                }

                if let status = cliStatus, status.isInstalled, !status.pathConfigured {
                    Text("命令已安装，但当前 PATH 不包含 \(RunShelfCLIInstaller.defaultPrefixURL().path)。请把该目录加入 shell 配置。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Text("把 Run Shelf 的 CLI 契约交给 AI agent，让它安全地创建、运行和查询任务。")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("复制集成说明") {
                        copyAgentGuide()
                    }
                    Button("写入 ~/.claude/CLAUDE.md") {
                        isShowingAgentWritePreview = true
                    }
                }
                .controlSize(.small)
                .disabled(embeddedCLIURL == nil)

                if let cliFeedback {
                    Text(cliFeedback)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
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
        .frame(width: 520, height: 720)
        .onAppear {
            controller.refresh()
            refreshCLIStatus()
        }
        .sheet(isPresented: $isShowingAgentWritePreview) {
            agentWritePreview
        }
        .alert("Run Shelf", isPresented: errorBinding) {
            Button("知道了", role: .cancel) {
                controller.lastErrorMessage = nil
            }
        } message: {
            Text(controller.lastErrorMessage ?? "")
        }
    }

    // MARK: - Command line and agent section

    private var embeddedCLIURL: URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/Helpers/runshelf")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
    }

    private var agentGuide: String {
        RunShelfAgentGuide.markdown(executableURL: embeddedCLIURL)
    }

    private var claudeInstructionsURL: URL {
        RunShelfAgentSetupWriter.claudeInstructionsURL()
    }

    private var agentWritePreview: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("写入 ~/.claude/CLAUDE.md")
                .font(.headline)
            Text("Run Shelf 只会新增或更新下面的标记块，标记块外的内容保持不变。")
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(RunShelfAgentGuide.markedBlock(executableURL: embeddedCLIURL))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 360)
            HStack {
                Spacer()
                Button("取消", role: .cancel) {
                    isShowingAgentWritePreview = false
                }
                Button("写入") {
                    writeClaudeInstructions()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 560)
    }

    private func refreshCLIStatus() {
        guard let embeddedCLIURL else {
            cliStatus = nil
            cliFeedback = "应用文件不完整，找不到内置 runshelf 命令。"
            return
        }
        cliStatus = RunShelfCLIInstaller.inspect(executableURL: embeddedCLIURL)
    }

    private func installCommandLineTool() {
        guard let embeddedCLIURL else { return }
        do {
            let result = try RunShelfCLIInstaller.install(
                executableURL: embeddedCLIURL,
                prefixURL: RunShelfCLIInstaller.defaultPrefixURL(),
                force: false
            )
            cliFeedback = result.pathConfigured
                ? "已安装：\(result.path)"
                : "已安装：\(result.path)。当前 PATH 尚未包含安装目录。"
            refreshCLIStatus()
        } catch {
            cliFeedback = error.localizedDescription
            refreshCLIStatus()
        }
    }

    private func copyAgentGuide() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(agentGuide, forType: .string)
        cliFeedback = "已复制集成说明。"
    }

    private func writeClaudeInstructions() {
        do {
            let changed = try RunShelfAgentSetupWriter.writeMarkedBlock(
                to: claudeInstructionsURL,
                executableURL: embeddedCLIURL
            )
            cliFeedback = changed
                ? "已写入：\(claudeInstructionsURL.path)"
                : "无需更改：\(claudeInstructionsURL.path)"
            isShowingAgentWritePreview = false
        } catch {
            cliFeedback = error.localizedDescription
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
