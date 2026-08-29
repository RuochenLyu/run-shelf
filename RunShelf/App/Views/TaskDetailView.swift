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

    var keyboardEquivalent: KeyEquivalent {
        switch self {
        case .script: return "1"
        case .notes: return "2"
        case .log: return "3"
        }
    }

    var helpText: String {
        switch self {
        case .script: return "脚本（⌘1）"
        case .notes: return "备注（⌘2）"
        case .log: return "日志（⌘3）"
        }
    }
}

struct TaskDetailView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var selection: TaskSelectionState
    let taskID: String
    var titleLeadingInset: CGFloat = 0

    @State private var selectedTab: TaskDetailTab = .script

    var body: some View {
        if let task = store.task(withID: taskID) {
            VStack(spacing: 0) {
                // Header 的 sheet 展示状态属于当前任务；切换任务时不复用。
                TaskHeaderView(store: store, task: task, titleLeadingInset: titleLeadingInset)
                    .id(task.id)
                Divider()
                tabBar
                Divider()
                content(for: task)
            }
            .onChange(of: selection.selectedRunID) { _, newValue in
                if newValue != nil {
                    selectedTab = .log
                }
            }
        } else {
            EmptyStateView(title: "任务不存在", systemImage: "exclamationmark.triangle", description: nil)
        }
    }

    private var tabBar: some View {
        HStack {
            Spacer()
            HStack(spacing: 0) {
                ForEach(TaskDetailTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Text(tab.displayName)
                            .font(.callout)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(tab.keyboardEquivalent, modifiers: [.command])
                    .background {
                        if selectedTab == tab {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color(nsColor: .selectedContentBackgroundColor))
                        }
                    }
                    .foregroundStyle(
                        selectedTab == tab
                            ? Color(nsColor: .selectedControlTextColor)
                            : .primary
                    )
                    .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                    .help(tab.helpText)
                }
            }
            .padding(2)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
            .frame(width: 240)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("任务详情")
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func content(for task: RunShelfTask) -> some View {
        switch selectedTab {
        case .script:
            scriptTab
        case .notes:
            notesTab
        case .log:
            LogView(store: store, selection: selection, task: task)
        }
    }

    private var scriptTab: some View {
        ShellScriptEditor(text: scriptBinding)
    }

    private var notesTab: some View {
        ZStack(alignment: .topLeading) {
            if (store.task(withID: taskID)?.notes ?? "").isEmpty {
                Text("添加备注…")
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }

            TextEditor(text: notesBinding)
                .scrollContentBackground(.hidden)
        }
        .font(.body)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
