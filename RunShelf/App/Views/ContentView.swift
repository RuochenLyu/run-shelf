import SwiftUI

struct ContentView: View {
    private let inspectorWidth: CGFloat = 340

    @StateObject private var store = TaskStore()
    @State private var isShowingNewTask = false
    @State private var isShowingDeleteConfirmation = false

    var body: some View {
        NavigationSplitView {
            TaskSidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 320)
        } content: {
            if let task = store.selectedTask {
                TaskDetailView(store: store, taskID: task.id)
            } else {
                emptyDetailPlaceholder
            }
        } detail: {
            if let task = store.selectedTask {
                TaskInspectorView(store: store, task: task)
                    .frame(width: inspectorWidth)
                    .navigationSplitViewColumnWidth(
                        min: inspectorWidth,
                        ideal: inspectorWidth,
                        max: inspectorWidth
                    )
            } else {
                Color.clear
                    .frame(width: inspectorWidth)
                    .navigationSplitViewColumnWidth(
                        min: inspectorWidth,
                        ideal: inspectorWidth,
                        max: inspectorWidth
                    )
            }
        }
        .frame(minWidth: 1120, minHeight: 640)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    isShowingNewTask = true
                } label: {
                    Label("新建任务", systemImage: "plus")
                }
                .help("新建任务")

                Button {
                    if let id = store.selectedTaskID {
                        store.runTask(id: id)
                    }
                } label: {
                    Label("立即运行", systemImage: "play.fill")
                }
                .help("立即运行（⌘R）")
                .disabled(!canRunSelectedTask)

                Button {
                    if let id = store.selectedTaskID {
                        store.saveTask(id: id)
                    }
                } label: {
                    Label("保存", systemImage: "square.and.arrow.down")
                }
                .help("保存（⌘S）")
                .disabled(!canSaveSelectedTask)

                Button(role: .destructive) {
                    isShowingDeleteConfirmation = true
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .help("删除任务")
                .disabled(store.selectedTaskID == nil)
            }
        }
        .sheet(isPresented: $isShowingNewTask) {
            NewTaskSheet(store: store)
        }
        .confirmationDialog("删除任务", isPresented: $isShowingDeleteConfirmation) {
            Button("删除", role: .destructive) {
                if let id = store.selectedTaskID {
                    store.deleteTask(id: id)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("任务目录会移入废纸篓，运行中的任务无法删除。")
        }
        .alert("Run Shelf", isPresented: errorBinding) {
            Button("好", role: .cancel) {
                store.lastErrorMessage = nil
            }
        } message: {
            Text(store.lastErrorMessage ?? "")
        }
        .onAppear {
            store.loadTasks()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled else { break }
                store.refreshRunsFromDisk()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveSelectedTaskFromMenu)) { _ in
            if let id = store.selectedTaskID {
                store.saveTask(id: id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .runSelectedTaskFromMenu)) { _ in
            if let id = store.selectedTaskID {
                store.runTask(id: id)
            }
        }
    }

    private var emptyDetailPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text("还没有任务")
                .font(.title3.weight(.semibold))
            Text("点击工具栏的「新建任务」开始第一个计划脚本。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                isShowingNewTask = true
            } label: {
                Label("新建任务", systemImage: "plus")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .padding(.top, 6)
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
}
