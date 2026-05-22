import SwiftUI

struct NewTaskSheet: View {
    @ObservedObject var store: TaskStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTemplateID: String? = TaskTemplate.builtIns.first?.id
    @State private var taskName = ""

    private var selectedTemplate: TaskTemplate {
        TaskTemplate.builtIns.first { $0.id == selectedTemplateID } ?? .blank
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("新建任务")
                .font(.title2.weight(.semibold))
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 12)

            Divider()

            HStack(spacing: 0) {
                List(selection: $selectedTemplateID) {
                    ForEach(TaskTemplate.builtIns) { template in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(template.name)
                                .font(.headline)
                            Text(template.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 5)
                        .tag(template.id)
                    }
                }
                .frame(width: 220)

                Divider()

                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("任务名")
                            .font(.headline)
                        TextField(selectedTemplate.name, text: $taskName)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("默认执行时间")
                            .font(.headline)
                        Text(selectedTemplate.defaultSchedule.expression)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("run.sh 预览")
                            .font(.headline)
                        ScrollView {
                            Text(selectedTemplate.script)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                        }
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }

                    Spacer()
                }
                .padding(20)
            }

            Divider()

            HStack {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                Button("创建") {
                    store.createTask(from: selectedTemplate, name: taskName)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
    }
}
