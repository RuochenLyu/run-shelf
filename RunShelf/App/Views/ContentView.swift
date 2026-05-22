import SwiftUI

struct ContentView: View {
    @StateObject private var store = TaskStore()
    @State private var isShowingNewTask = false
    @State private var isShowingDeleteConfirmation = false

    var body: some View {
        NavigationSplitView {
            TaskSidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
        } content: {
            if let task = store.selectedTask {
                TaskDetailView(store: store, taskID: task.id)
            } else {
                EmptyStateView(title: "暂无任务", systemImage: "tray", description: "新建任务后会显示脚本、历史和日志。")
            }
        } detail: {
            if let task = store.selectedTask {
                TaskInspectorView(store: store, task: task)
                    .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 380)
            } else {
                EmptyStateView(title: "未选择任务", systemImage: "sidebar.right", description: nil)
            }
        }
        .frame(minWidth: 1120, minHeight: 680)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    isShowingNewTask = true
                } label: {
                    Label("新建任务", systemImage: "plus")
                }

                Button {
                    if let id = store.selectedTaskID {
                        store.runTask(id: id)
                    }
                } label: {
                    Label("立即运行", systemImage: "play.fill")
                }
                .disabled(store.selectedTaskID == nil || store.selectedTaskID.map { store.runningTaskIDs.contains($0) } == true)

                Button {
                    if let id = store.selectedTaskID {
                        store.saveTask(id: id)
                    }
                } label: {
                    Label("保存", systemImage: "square.and.arrow.down")
                }
                .disabled(store.selectedTask?.isDirty != true)

                Button(role: .destructive) {
                    isShowingDeleteConfirmation = true
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .disabled(store.selectedTaskID == nil)
            }
        }
        .sheet(isPresented: $isShowingNewTask) {
            NewTaskSheet(store: store)
                .frame(minWidth: 520, minHeight: 420)
        }
        .confirmationDialog("删除任务", isPresented: $isShowingDeleteConfirmation) {
            Button("删除", role: .destructive) {
                if let id = store.selectedTaskID {
                    store.deleteTask(id: id)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("任务目录会移入废纸篓。运行中的任务不能删除。")
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
                await store.refreshRunsFromDisk()
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

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.lastErrorMessage != nil },
            set: { if !$0 { store.lastErrorMessage = nil } }
        )
    }
}
