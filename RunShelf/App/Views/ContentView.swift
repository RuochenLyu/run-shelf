import SwiftUI

struct ContentView: View {
    private let inspectorWidth: CGFloat = 300
    private let collapsedSidebarTitleInset: CGFloat = 128

    @ObservedObject private var store: TaskStore
    @ObservedObject private var selection: TaskSelectionState
    @StateObject private var schedulePrefs = SchedulePreferencesStore()
    @StateObject private var taskListPrefs = TaskListPreferencesStore()
    @State private var isShowingNewTask = false
    @State private var pendingDeletionTaskID: String?
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
            .confirmationDialog("删除任务", isPresented: deleteConfirmationBinding) {
                Button("删除", role: .destructive) {
                    if let id = pendingDeletionTaskID {
                        pendingDeletionTaskID = nil
                        store.deleteTask(id: id)
                    }
                }
                Button("取消", role: .cancel) {
                    pendingDeletionTaskID = nil
                }
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

    private var sidebarTitlebarControls: some View {
        taskSortMenu
            .buttonStyle(.borderless)
            .labelStyle(.iconOnly)
            .controlSize(.large)
            .padding(.top, 8)
            .padding(.trailing, 52)
            .ignoresSafeArea(.container, edges: .top)
    }

    private var windowActionBar: some View {
        HStack(spacing: 8) {
            newTaskButton
            selectedTaskActions
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

    private var taskSortMenu: some View {
        Menu {
            ForEach(TaskListSortMode.allCases) { mode in
                Button {
                    taskListPrefs.setSortMode(mode)
                } label: {
                    if taskListPrefs.sortMode == mode {
                        Label(mode.displayName, systemImage: "checkmark")
                    } else {
                        Text(mode.displayName)
                    }
                }
            }
        } label: {
            toolbarIcon("arrow.up.arrow.down")
        }
        .menuIndicator(.hidden)
        .help("任务排序")
        .accessibilityIdentifier("task-sort-menu")
    }

    private var navigationContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            TaskSidebarView(store: store, selection: selection, preferences: taskListPrefs)
                .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 320)
                .overlay(alignment: .topTrailing) {
                    sidebarTitlebarControls
                }
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

    private var newTaskButton: some View {
        Button {
            isShowingNewTask = true
        } label: {
            toolbarIcon("plus")
        }
        .accessibilityLabel("新建任务")
        .help("新建任务")
        .accessibilityIdentifier("new-task")
    }

    @ViewBuilder
    private var selectedTaskActions: some View {
        Button {
            if let id = selection.selectedTaskID {
                store.runTask(id: id)
            }
        } label: {
            toolbarIcon("play.fill")
        }
        .accessibilityLabel("立即运行")
        .help("立即运行（⌘R）")
        .accessibilityIdentifier("run-task")
        .disabled(!canRunSelectedTask)

        Button {
            if let id = selection.selectedTaskID {
                store.saveTask(id: id)
            }
        } label: {
            toolbarIcon("square.and.arrow.down")
        }
        .accessibilityLabel("保存改动")
        .help("保存改动（⌘S）")
        .accessibilityIdentifier("save-task")
        .disabled(!canSaveSelectedTask)

        Button(role: .destructive) {
            pendingDeletionTaskID = selection.selectedTaskID
        } label: {
            toolbarIcon("trash")
        }
        .accessibilityLabel("删除任务")
        .help("删除任务")
        .accessibilityIdentifier("delete-task")
        .disabled(selection.selectedTaskID == nil)
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
        } else {
            emptyDetailPlaceholder
        }
    }

    @ViewBuilder
    private var inspectorContent: some View {
        if let task = store.selectedTask {
            // Inspector 内含任务专属的编辑草稿状态；任务切换时必须创建新 identity，
            // 不能把上一任务的 ScheduleEditor @State 带到当前任务。
            TaskInspectorView(store: store, task: task)
                .id(task.id)
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

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletionTaskID != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeletionTaskID = nil
                }
            }
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
