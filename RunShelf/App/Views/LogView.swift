import SwiftUI

struct LogView: View {
    @ObservedObject var store: TaskStore
    var task: RunShelfTask
    @Binding var selectedLogKind: RunLogKind

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
    }

    private var toolbar: some View {
        HStack(spacing: 16) {
            runPicker

            Spacer(minLength: 16)

            LogKindSwitcher(selection: $selectedLogKind)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(minHeight: 58)
    }

    @ViewBuilder
    private var runPicker: some View {
        if task.runs.isEmpty {
            Text("暂无运行记录")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 320, alignment: .leading)
        } else {
            RunSelectionPicker(task: task, selectedRunID: selectedRunBinding)
                .frame(width: 320, alignment: .leading)
        }
    }

    private var selectedRunBinding: Binding<String?> {
        Binding(
            get: {
                guard let selectedRunID = store.selectedRunID,
                      task.runs.contains(where: { $0.runId == selectedRunID }) else {
                    return nil
                }
                return selectedRunID
            },
            set: { store.selectedRunID = $0 }
        )
    }

    @ViewBuilder
    private var content: some View {
        if let run = effectiveRun {
            ScrollView {
                Text(store.logText(for: task, run: run, kind: selectedLogKind))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text("暂无运行记录")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("点击工具栏的「立即运行」开始第一次运行。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var effectiveRun: RunRecord? {
        if let id = store.selectedRunID,
           let run = task.runs.first(where: { $0.runId == id }) {
            return run
        }
        return task.latestRun
    }

}

private struct RunSelectionPicker: View {
    var task: RunShelfTask
    @Binding var selectedRunID: String?

    var body: some View {
        Picker("运行记录", selection: $selectedRunID) {
            Text("最新一次").tag(Optional<String>.none)

            ForEach(task.runs.prefix(40)) { run in
                Text(runLabel(for: run)).tag(Optional(run.runId))
            }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func runLabel(for run: RunRecord) -> String {
        let time = RunShelfFormatters.dateTime(run.startedAt)
        return "\(time) · \(run.status.displayName)"
    }
}

private struct LogKindSwitcher: View {
    @Binding var selection: RunLogKind

    var body: some View {
        HStack(spacing: 0) {
            ForEach(RunLogKind.allCases) { kind in
                Button {
                    selection = kind
                } label: {
                    Text(kind.displayName)
                        .font(.callout.weight(selection == kind ? .semibold : .regular))
                        .foregroundStyle(selection == kind ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background {
                    if selection == kind {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
                    }
                }
            }
        }
        .padding(2)
        .frame(width: 260)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(nsColor: .separatorColor).opacity(0.35))
        }
    }
}
