import SwiftUI
import UniformTypeIdentifiers

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
    @State private var importedScript: ScriptImport?
    @State private var importError: String?
    @State private var isImporterPresented = false
    @State private var isDropTargeted = false

    private var isImportSelected: Bool {
        selectedTemplateID == TaskTemplate.importedTemplateID && importedScript != nil
    }

    private var selectedTemplate: TaskTemplate {
        if isImportSelected, let importedScript {
            return .imported(importedScript)
        }
        return TaskTemplate.builtIns.first { $0.id == selectedTemplateID } ?? .blank
    }

    /// 描述行下方至多一行：导入失败（红色）或导入提示（次要色）。
    private var importCaption: (text: String, isError: Bool)? {
        if let importError { return (importError, true) }
        if isImportSelected, let notice = importedScript?.notice { return (notice, false) }
        return nil
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
                                selectTemplate(template)
                            } label: {
                                TemplateCard(
                                    title: template.name,
                                    systemImage: template.sheetIconName,
                                    isSelected: template.id == selectedTemplateID
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(template.name)
                            .accessibilityValue(template.id == selectedTemplateID ? "已选择" : "未选择")
                        }

                        Button {
                            if let importedScript, !isImportSelected {
                                selectTemplate(.imported(importedScript))
                            } else {
                                isImporterPresented = true
                            }
                        } label: {
                            TemplateCard(
                                title: importedScript?.fileName ?? "导入文件",
                                systemImage: "square.and.arrow.down",
                                isSelected: isImportSelected || isDropTargeted
                            )
                        }
                        .buttonStyle(.plain)
                        .help("从本地文件导入脚本，也可以把文件拖进来")
                        .accessibilityLabel("导入文件")
                        .accessibilityValue(importedScript?.fileName ?? "未选择文件")
                    }
                    .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(isImportSelected ? importedScript?.summary ?? "" : selectedTemplate.description)
                            .foregroundStyle(.secondary)
                        if let importCaption {
                            Text(importCaption.text)
                                .foregroundStyle(importCaption.isError ? Color.red : Color.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)

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
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url):
                importScript(from: url)
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled {
                    importError = error.localizedDescription
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.isFileURL else { return false }
            importScript(from: url)
            return true
        } isTargeted: {
            isDropTargeted = $0
        }
    }

    private func selectTemplate(_ template: TaskTemplate) {
        selectedTemplateID = template.id
        scheduleExpression = template.defaultSchedule.expression
        // 切模板后，让 editor 按新表达式自动推断 mode；
        // 不再保留用户在上个模板下选择的 tab
        pickedMode = nil
        importError = nil
    }

    private func importScript(from url: URL) {
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer { if isAccessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let result = try ScriptImporter().load(from: url)
            importedScript = result
            importError = nil
            // 已在导入卡片上时换文件，保留用户改过的执行时间。
            if selectedTemplateID != TaskTemplate.importedTemplateID {
                selectTemplate(.imported(result))
            }
        } catch {
            importError = error.localizedDescription
        }
    }

    private var isCronValid: Bool {
        if case .success = CronSchedule.validate(scheduleExpression) {
            return true
        }
        return false
    }
}

private struct TemplateCard: View {
    let title: String
    let systemImage: String
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isSelected ? Color.green : Color.primary)
                .frame(height: 28)

            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
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

private extension TaskTemplate {
    var sheetIconName: String {
        switch id {
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
