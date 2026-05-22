import AppKit
import SwiftUI

enum TaskDetailTab: String, Hashable, CaseIterable, Identifiable {
    case script
    case notes
    case log

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .script: return "脚本"
        case .notes: return "备注"
        case .log: return "日志"
        }
    }

    var systemImage: String {
        switch self {
        case .script: return "terminal"
        case .notes: return "note.text"
        case .log: return "doc.text.magnifyingglass"
        }
    }
}

struct TaskDetailView: View {
    @ObservedObject var store: TaskStore
    let taskID: String

    @State private var selectedTab: TaskDetailTab = .script
    @State private var selectedLogKind: RunLogKind = .combined

    var body: some View {
        if let task = store.task(withID: taskID) {
            VStack(spacing: 0) {
                TaskHeaderView(store: store, task: task)
                Divider()
                tabBar
                Divider()
                content(for: task)
            }
            .onChange(of: store.selectedRunID) { newValue in
                if newValue != nil {
                    selectedTab = .log
                }
            }
        } else {
            EmptyStateView(title: "任务不存在", systemImage: "exclamationmark.triangle", description: nil)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            DetailTabSwitcher(selection: $selectedTab)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func content(for task: RunShelfTask) -> some View {
        switch selectedTab {
        case .script:
            scriptTab
        case .notes:
            notesTab
        case .log:
            LogView(store: store, task: task, selectedLogKind: $selectedLogKind)
        }
    }

    private var scriptTab: some View {
        VStack(spacing: 0) {
            ScriptToolbarView(script: scriptBinding)
            Divider()
            ShellScriptEditor(text: scriptBinding)
        }
    }

    private var notesTab: some View {
        TextEditor(text: notesBinding)
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(16)
    }

    private var scriptBinding: Binding<String> {
        Binding(
            get: { store.task(withID: taskID)?.script ?? "" },
            set: { value in
                store.updateTask(id: taskID) { task in
                    task.script = value
                }
            }
        )
    }

    private var notesBinding: Binding<String> {
        Binding(
            get: { store.task(withID: taskID)?.notes ?? "" },
            set: { value in
                store.updateTask(id: taskID) { task in
                    task.notes = value
                }
            }
        )
    }
}

private struct DetailTabSwitcher: View {
    @Binding var selection: TaskDetailTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(TaskDetailTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    Label(tab.displayName, systemImage: tab.systemImage)
                        .labelStyle(.titleAndIcon)
                        .font(.callout.weight(selection == tab ? .semibold : .regular))
                        .foregroundStyle(selection == tab ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background {
                    if selection == tab {
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

private struct ScriptToolbarView: View {
    @Binding var script: String

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                Button("严格模式") {
                    insertSnippet("set -euo pipefail")
                }
                Button("进入项目目录") {
                    insertSnippet(#"cd "$HOME/Projects/my-project""#)
                }
                Button("Homebrew 路径") {
                    insertSnippet(#"export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH""#)
                }
                Button("Python 虚拟环境") {
                    insertSnippet("source .venv/bin/activate")
                }
            } label: {
                Label("插入片段", systemImage: "text.badge.plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                chooseDirectoryAndInsertCD()
            } label: {
                Label("插入目录", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)

            Spacer()
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 24)
        .padding(.vertical, 7)
    }

    private func chooseDirectoryAndInsertCD() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "插入"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        insertSnippet("cd \(shellDoubleQuoted(url.path))")
    }

    private func insertSnippet(_ snippet: String) {
        let trimmed = snippet.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return }
        if script.isEmpty || script.hasSuffix("\n") {
            script += trimmed + "\n"
        } else {
            script += "\n" + trimmed + "\n"
        }
    }

    private func shellDoubleQuoted(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
        return "\"\(escaped)\""
    }
}
