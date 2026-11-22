import AppKit
import SwiftUI

struct NewTaskSheet: View {
    private static let notificationPromptDelayNanoseconds: UInt64 = 250_000_000

    @ObservedObject var store: TaskStore
    @EnvironmentObject private var schedulePrefs: SchedulePreferencesStore
    @EnvironmentObject private var schedulerController: SchedulerServiceController
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTemplateID: String = TaskTemplate.builtIns.first?.id ?? "blank"
    @State private var taskName = ""
    @State private var scheduleExpression: String = TaskTemplate.builtIns.first?.defaultSchedule.expression ?? "0 9 * * *"
    @State private var isScheduleDraftValid = true
    @State private var pickedMode: ScheduleMode? = nil
    @State private var importedTemplate: TaskTemplate? = nil
    @State private var importWarnings: [String] = []
    @State private var importError: String? = nil

    private var selectedTemplate: TaskTemplate {
        if selectedTemplateID == TaskTemplate.importedTemplateID, let importedTemplate {
            return importedTemplate
        }
        return TaskTemplate.builtIns.first { $0.id == selectedTemplateID } ?? .blank
    }

    private var isImportSelected: Bool {
        importedTemplate != nil && selectedTemplateID == TaskTemplate.importedTemplateID
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("新建任务")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 4)

            Form {
                Section("模板") {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                        spacing: 10
                    ) {
                        ForEach(TaskTemplate.builtIns) { template in
                            Button {
                                selectedTemplateID = template.id
                                scheduleExpression = template.defaultSchedule.expression
                                // 切模板后，让 editor 按新表达式自动推断 mode；
                                // 不再保留用户在上个模板下选择的 tab
                                pickedMode = nil
                            } label: {
                                TemplateCard(
                                    template: template,
                                    isSelected: template.id == selectedTemplateID
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(template.name)
                            .accessibilityValue(template.id == selectedTemplateID ? "已选择" : "未选择")
                        }

                        Button(action: handleImportCardTap) {
                            ImportCard(
                                fileName: importedTemplate?.name,
                                isSelected: isImportSelected
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("从本地文件导入脚本")
                        .accessibilityValue(isImportSelected ? "已选择" : "未选择")
                        .help(importedTemplate == nil
                              ? "选择任意文本脚本（.sh / .zsh / .py / .js / .rb / .pl / .txt …），按内容识别语言"
                              : "已导入的文件：再点一次可换一个文件")
                    }
                    .padding(.vertical, 4)

                    Text(selectedTemplate.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if isImportSelected {
                        ForEach(importWarnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if let importError {
                        Label(importError, systemImage: "xmark.octagon")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    LabeledContent {
                        TextField("", text: $taskName, prompt: Text(selectedTemplate.name))
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                    } label: {
                        Text("名称")
                    }
                }

                Section("执行时间") {
                    ScheduleEditorView(
                        expression: $scheduleExpression,
                        onModeChange: { pickedMode = $0 },
                        onValidityChange: { isScheduleDraftValid = $0 }
                    )
                    CronPreviewView(expression: scheduleExpression, nextRunCount: 1)
                }
            }
            .formStyle(.grouped)

            HStack(spacing: 10) {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("创建") {
                    let createdID = store.createTask(
                        from: selectedTemplate,
                        name: taskName,
                        scheduleExpression: scheduleExpression
                    )
                    if let id = createdID {
                        if let mode = pickedMode {
                            schedulePrefs.setMode(mode.rawValue, for: id)
                        }
                        let needsNotificationPrompt = store.task(withID: id)?.manifest.notifications.onFailure ?? false
                        dismiss()
                        if needsNotificationPrompt {
                            // macOS sheet 关闭动画约 200-300ms；等它让出焦点再弹系统权限对话框。
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: Self.notificationPromptDelayNanoseconds)
                                schedulerController.requestNotificationAuthorizationIfNeeded()
                            }
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isScheduleDraftValid || !isCronValid)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 560, height: 640)
    }

    private var isCronValid: Bool {
        if case .success = CronSchedule.validate(scheduleExpression) {
            return true
        }
        return false
    }

    // MARK: - 从本地文件导入

    /// 第一次点开面板；已经导入过但没选中时先切回去，再点一次才换文件。
    private func handleImportCardTap() {
        if importedTemplate != nil, !isImportSelected {
            selectedTemplateID = TaskTemplate.importedTemplateID
            pickedMode = nil
            return
        }
        presentImportPanel()
    }

    private func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.title = "导入脚本"
        panel.message = "选择任意脚本文件，按内容识别语言，不限制扩展名"
        panel.prompt = "导入"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importScript(at: url)
    }

    private func importScript(at url: URL) {
        do {
            let imported = try ScriptImporter.load(from: url)
            let baseName = (url.lastPathComponent as NSString).deletingPathExtension
            let template = TaskTemplate.imported(
                script: imported.script,
                name: baseName.isEmpty ? url.lastPathComponent : baseName,
                summary: "来自 \(url.lastPathComponent) · \(imported.summary)",
                notes: "由本地文件导入：\(url.path)"
            )
            importedTemplate = template
            importWarnings = imported.warnings
            importError = nil
            selectedTemplateID = TaskTemplate.importedTemplateID
            pickedMode = nil
            taskName = template.name
        } catch {
            importError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private struct TemplateCard: View {
    let template: TaskTemplate
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 22, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isSelected ? Color.green : Color.primary)
                .frame(height: 28)

            Text(template.name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .templateCardChrome(isSelected: isSelected)
    }

    private var iconName: String {
        switch template.id {
        case "blank": return "doc.text"
        case "project-script": return "folder.fill"
        case "curl-request": return "network"
        case "git-sync": return "arrow.triangle.2.circlepath"
        case "node-script": return "n.square.fill"
        case "python-script": return "chevron.left.forwardslash.chevron.right"
        case "rsync-backup": return "externaldrive.fill.badge.checkmark"
        default: return "doc.text"
        }
    }
}

/// 「从本地文件导入」卡片。导入前显示入口文案，导入后显示文件名，点一下可以换文件。
private struct ImportCard: View {
    let fileName: String?
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 22, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isSelected ? Color.green : Color.primary)
                .frame(height: 28)

            Text(fileName ?? "导入脚本")
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.primary)
                .padding(.horizontal, 4)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .templateCardChrome(isSelected: isSelected)
    }
}

private struct TemplateCardChrome: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.green.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.green.opacity(0.7) : Color.clear, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

private extension View {
    func templateCardChrome(isSelected: Bool) -> some View {
        modifier(TemplateCardChrome(isSelected: isSelected))
    }
}
