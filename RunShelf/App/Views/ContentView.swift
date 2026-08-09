import SwiftUI

struct ContentView: View {
    private let inspectorWidth: CGFloat = 300
    private let collapsedSidebarTitleInset: CGFloat = 128

    @ObservedObject private var store: TaskStore
    @ObservedObject private var selection: TaskSelectionState
    @StateObject private var schedulePrefs = SchedulePreferencesStore()
    @State private var isShowingNewTask = false
    @State private var isShowingDeleteConfirmation = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    init(store: TaskStore) {
        self.store = store
        self.selection = store.selection
    }

    var body: some View {
        navigationContent
            .environmentObject(schedulePrefs)
            .frame(minWidth: 1120, minHeight: 640)
            .overlay(alignment: .topTrailing) {
                windowActionBar
            }
            .sheet(isPresented: $isShowingNewTask) {
                NewTaskSheet(store: store)
                    .environmentObject(schedulePrefs)
            }
            .confirmationDialog("删除任务", isPresented: $isShowingDeleteConfirmation) {
                Button("删除", role: .destructive) {
                    if let id = selection.selectedTaskID {
                        store.deleteTask(id: id)
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("任务目录会移入废纸篓。")
            }
            .alert("Run Shelf", isPresented: errorBinding) {
                Button("知道了", role: .cancel) {
                    store.lastErrorMessage = nil
                }
            } message: {
                Text(store.lastErrorMessage ?? "")
            }
            .onReceive(NotificationCenter.default.publisher(for: .saveSelectedTaskFromMenu)) { _ in
                if let id = selection.selectedTaskID {
                    store.saveTask(id: id)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .runSelectedTaskFromMenu)) { _ in
                if let id = selection.selectedTaskID {
                    store.runTask(id: id)
                }
            }
    }

    private var navigationContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            TaskSidebarView(store: store, selection: selection)
                .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 320)
        } detail: {
            HStack(spacing: 0) {
                detailContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if store.selectedTask != nil {
                    Divider()
                    inspectorContent
                        .frame(width: inspectorWidth)
                        .frame(maxHeight: .infinity)
                        .background(Color(nsColor: .windowBackgroundColor))
                }
            }
            .ignoresSafeArea(.container, edges: .top)
        }
    }

    private var windowActionBar: some View {
        HStack(spacing: 8) {
            Button {
                isShowingNewTask = true
            } label: {
                toolbarIcon("plus")
            }
            .help("新建任务")
            .accessibilityLabel("新建任务")
            .accessibilityIdentifier("new-task")

            Button {
                if let id = selection.selectedTaskID {
                    store.runTask(id: id)
                }
            } label: {
                toolbarIcon("play.fill")
            }
            .help("立即运行（⌘R）")
            .accessibilityLabel("立即运行")
            .accessibilityIdentifier("run-task")
            .disabled(!canRunSelectedTask)

            Button {
                if let id = selection.selectedTaskID {
                    store.saveTask(id: id)
                }
            } label: {
                toolbarIcon("square.and.arrow.down")
            }
            .help("保存改动（⌘S）")
            .accessibilityLabel("保存改动")
            .accessibilityIdentifier("save-task")
            .disabled(!canSaveSelectedTask)

            Button(role: .destructive) {
                isShowingDeleteConfirmation = true
            } label: {
                toolbarIcon("trash")
            }
            .help("删除任务")
            .accessibilityLabel("删除任务")
            .accessibilityIdentifier("delete-task")
            .disabled(selection.selectedTaskID == nil)
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        .controlSize(.large)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 18, x: 0, y: 4)
        .padding(.top, 8)
        .padding(.trailing, 12)
        .ignoresSafeArea(.container, edges: .top)
    }

    private func toolbarIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var detailContent: some View {
        if let task = store.selectedTask {
            TaskDetailView(
                store: store,
                selection: selection,
                taskID: task.id,
                titleLeadingInset: isSidebarCollapsed ? collapsedSidebarTitleInset : 0
            )
            .ignoresSafeArea(.container, edges: .top)
        } else {
            emptyDetailPlaceholder
        }
    }

    @ViewBuilder
    private var inspectorContent: some View {
        if let task = store.selectedTask {
            TaskInspectorView(store: store, task: task)
        } else {
            InspectorEmptyView()
        }
    }

    private var emptyDetailPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text("还没有任务")
                .font(.title3.weight(.semibold))
            Text("点右上角的 + 新建一个任务")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.lastErrorMessage != nil },
            set: { if !$0 { store.lastErrorMessage = nil } }
        )
    }

    private var canSaveSelectedTask: Bool {
        guard let task = store.selectedTask else { return false }
        return store.canSaveTask(task)
    }

    private var canRunSelectedTask: Bool {
        guard let task = store.selectedTask else { return false }
        return store.canRunTask(task)
    }

    private var isSidebarCollapsed: Bool {
        columnVisibility == .detailOnly
    }
}
