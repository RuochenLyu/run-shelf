import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var controller: SchedulerServiceController
    @AppStorage(RunShelfSettings.defaultRetentionDaysKey) private var defaultRetentionDays = RunShelfSettings.defaultRetentionDays
    @AppStorage(RunShelfSettings.defaultRetentionMaxRunsKey) private var defaultRetentionMaxRuns = RunShelfSettings.defaultRetentionMaxRuns
    @State private var cliStatus: RunShelfCLIInstallationStatus?
    @State private var cliFeedback: String?
    @State private var cliFeedbackIsError = false

    var body: some View {
        Form {
            Section("存储") {
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

            Section("系统") {
                schedulerRow
                if let warning = schedulerWarning {
                    SettingsWarningRow(text: warning)
                }

                notificationRow
                if let warning = notificationWarning {
                    SettingsWarningRow(text: warning)
                }
            }

            Section("命令行") {
                HStack(spacing: 10) {
                    Label("runshelf", systemImage: "terminal")
                    Spacer(minLength: 12)
                    Text(cliStateText)
                        .foregroundStyle(.secondary)

                    if cliStatus?.isInstalled != true {
                        Button("安装…") {
                            installCommandLineTool()
                        }
                        .disabled(embeddedCLIURL == nil)
                    }
                }

                if let status = cliStatus, status.isInstalled, !status.pathConfigured {
                    SettingsWarningRow(text: "PATH 尚未包含 \(RunShelfCLIInstaller.defaultPrefixURL().path)")
                }

                Button {
                    copyAgentGuide()
                } label: {
                    Label("复制 Agent 集成说明", systemImage: "doc.on.doc")
                }
                .disabled(embeddedCLIURL == nil)

                if let cliFeedback {
                    Label(
                        cliFeedback,
                        systemImage: cliFeedbackIsError ? "xmark.circle.fill" : "checkmark"
                    )
                        .font(.caption)
                        .foregroundStyle(cliFeedbackIsError ? Color.red : Color.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("新建任务的日志保留") {
                LabeledContent("保留天数") {
                    RetentionNumberField(value: defaultRetentionDaysBinding, unit: "天", range: 1...365)
                }
                LabeledContent("最多保留") {
                    RetentionNumberField(value: defaultRetentionMaxRunsBinding, unit: "次", range: 1...5000)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 540)
        .background(SettingsWindowAccessor())
        .onAppear {
            controller.refresh()
            refreshCLIStatus()
        }
        .alert("Run Shelf", isPresented: errorBinding) {
            Button("知道了", role: .cancel) {
                controller.lastErrorMessage = nil
            }
        } message: {
            Text(controller.lastErrorMessage ?? "")
        }
    }

    private var schedulerRow: some View {
        HStack(spacing: 10) {
            Label("后台调度", systemImage: "clock.arrow.circlepath")
            Spacer(minLength: 12)
            Text(schedulerStateText)
                .foregroundStyle(schedulerStateColor)
            Button(schedulerActionLabel, action: schedulerPrimaryAction)
                .disabled(!controller.embeddedSchedulerAvailable)
        }
    }

    private var notificationRow: some View {
        HStack(spacing: 10) {
            Label("通知", systemImage: "bell")
            Spacer(minLength: 12)
            Text(notificationStateText)
                .foregroundStyle(notificationColor)
            Button(notificationActionLabel, action: notificationPrimaryAction)
        }
    }

    private var cliStateText: String {
        guard embeddedCLIURL != nil else { return "组件缺失" }
        return cliStatus?.isInstalled == true ? "已安装 · \(appVersion)" : "未安装"
    }

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

    private func refreshCLIStatus() {
        guard let embeddedCLIURL else {
            cliStatus = nil
            cliFeedback = "找不到内置 runshelf 命令"
            cliFeedbackIsError = true
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
            cliFeedback = result.pathConfigured ? "安装完成" : "已安装，PATH 尚未配置"
            cliFeedbackIsError = false
            refreshCLIStatus()
        } catch {
            cliFeedback = error.localizedDescription
            cliFeedbackIsError = true
            refreshCLIStatus()
        }
    }

    private func copyAgentGuide() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(agentGuide, forType: .string)
        cliFeedback = "已复制 Markdown"
        cliFeedbackIsError = false
    }

    private var schedulerStateText: String {
        if !controller.embeddedSchedulerAvailable {
            return "组件缺失"
        }
        switch controller.serviceStatus {
        case .enabled: return "已启用"
        case .notRegistered, .notFound: return "未启用"
        case .requiresApproval: return "需要授权"
        @unknown default: return "未知"
        }
    }

    private var schedulerStateColor: Color {
        if !controller.embeddedSchedulerAvailable { return .red }
        switch controller.serviceStatus {
        case .requiresApproval: return .orange
        default: return .secondary
        }
    }

    private var schedulerWarning: String? {
        if !controller.embeddedSchedulerAvailable {
            return "后台组件缺失，请重新安装 Run Shelf"
        }
        if controller.serviceStatus == .requiresApproval {
            return "需要在系统设置中允许登录项"
        }
        if controller.serviceStatus == .enabled,
           let heartbeat = controller.heartbeat,
           Date().timeIntervalSince(heartbeat.checkedAt) > 90 {
            return "最近活动：\(RunShelfFormatters.dateTimeWithSeconds(heartbeat.checkedAt))"
        }
        return nil
    }

    private var schedulerActionLabel: String {
        switch controller.serviceStatus {
        case .enabled: return "登录项…"
        case .requiresApproval: return "系统设置…"
        case .notRegistered, .notFound: return "启用"
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

    private var notificationStateText: String {
        switch controller.notificationStatus {
        case .authorized: return "已允许"
        case .provisional, .ephemeral: return "临时允许"
        case .denied: return "已拒绝"
        case .notDetermined: return "未授权"
        @unknown default: return "未知"
        }
    }

    private var notificationColor: Color {
        switch controller.notificationStatus {
        case .denied: return .red
        case .notDetermined: return .orange
        default: return .secondary
        }
    }

    private var notificationWarning: String? {
        controller.notificationStatus == .denied
            ? "需要在系统设置中允许通知"
            : nil
    }

    private var notificationActionLabel: String {
        switch controller.notificationStatus {
        case .notDetermined: return "允许"
        default: return "设置…"
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
}

private struct SettingsWarningRow: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .textSelection(.enabled)
    }
}

private struct SettingsWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(nsView.window)
        }
    }

    private func configure(_ window: NSWindow?) {
        window?.title = "Run Shelf 设置"
        window?.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window?.standardWindowButton(.zoomButton)?.isEnabled = false
    }
}
