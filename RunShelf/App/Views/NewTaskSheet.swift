import SwiftUI

struct NewTaskSheet: View {
    @ObservedObject var store: TaskStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTemplateID: String = TaskTemplate.builtIns.first?.id ?? "blank"
    @State private var taskName = ""
    @State private var scheduleExpression: String = TaskTemplate.builtIns.first?.defaultSchedule.expression ?? "0 9 * * *"
    @State private var isScheduleDraftValid = true

    private var selectedTemplate: TaskTemplate {
        TaskTemplate.builtIns.first { $0.id == selectedTemplateID } ?? .blank
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            HStack(spacing: 0) {
                templateList
                    .frame(width: 220)

                Divider()

                detailPane
            }

            Divider()
            footer
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 540, idealHeight: 580)
    }

    private var header: some View {
        HStack {
            Text("新建任务")
                .font(.title3.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var templateList: some View {
        List(selection: $selectedTemplateID) {
            Section("模板") {
                ForEach(TaskTemplate.builtIns) { template in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(template.name)
                            .font(.callout.weight(.medium))
                        Text(template.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 3)
                    .tag(template.id)
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: selectedTemplateID) { newID in
            if let template = TaskTemplate.builtIns.first(where: { $0.id == newID }) {
                scheduleExpression = template.defaultSchedule.expression
            }
        }
    }

    private var detailPane: some View {
        Form {
            Section("任务名") {
                TextField("任务名", text: $taskName, prompt: Text(selectedTemplate.name))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }

            Section("执行时间") {
                ScheduleEditorView(expression: $scheduleExpression) { isValid in
                    isScheduleDraftValid = isValid
                }
                CronPreviewView(expression: scheduleExpression)
            }

            Section("脚本预览") {
                ScrollView {
                    Text(selectedTemplate.script)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 140)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .formStyle(.grouped)
    }

    private var footer: some View {
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
                if createdID != nil {
                    dismiss()
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!isScheduleDraftValid || !isCronValid)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var isCronValid: Bool {
        if case .success = CronSchedule.validate(scheduleExpression) {
            return true
        }
        return false
    }
}
