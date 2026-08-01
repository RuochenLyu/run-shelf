import SwiftUI
import AppKit

@main
struct RunShelfApp: App {
    @StateObject private var schedulerController: SchedulerServiceController
    @StateObject private var taskStore: TaskStore

    init() {
        let controller = SchedulerServiceController()
        _schedulerController = StateObject(wrappedValue: controller)
        _taskStore = StateObject(wrappedValue: TaskStore())
    }

    var body: some Scene {
        Window("Run Shelf", id: "main") {
            ContentView(store: taskStore)
                .frame(
                    minWidth: RunShelfWindowMetrics.mainMinWidth,
                    minHeight: RunShelfWindowMetrics.mainMinHeight
                )
            .environmentObject(schedulerController)
            .environmentObject(taskStore)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .saveItem) {
                Button("保存") {
                    NotificationCenter.default.post(name: .saveSelectedTaskFromMenu, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command])
            }

            CommandGroup(after: .saveItem) {
                Button("立即运行") {
                    NotificationCenter.default.post(name: .runSelectedTaskFromMenu, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command])

                Divider()

                // Window scene 默认不提供 Close；手动接回 Cmd+W。
                // 关掉后从菜单栏「打开 Run Shelf」可以再开。
                Button("关闭窗口") {
                    NSApp.keyWindow?.performClose(nil)
                }
                .keyboardShortcut("w", modifiers: [.command])
            }
        }

        MenuBarExtra {
            MenuBarContent(
                taskStore: taskStore,
                schedulerController: schedulerController
            )
        } label: {
            MenuBarLabel(
                taskStore: taskStore,
                schedulerController: schedulerController
            )
        }

        Settings {
            SettingsView()
                .environmentObject(schedulerController)
        }
    }
}

extension Notification.Name {
    static let saveSelectedTaskFromMenu = Notification.Name("RunShelf.saveSelectedTaskFromMenu")
    static let runSelectedTaskFromMenu = Notification.Name("RunShelf.runSelectedTaskFromMenu")
}

private struct MenuBarLabel: View {
    @ObservedObject var taskStore: TaskStore
    @ObservedObject var schedulerController: SchedulerServiceController

    var body: some View {
        // 未授权优先级最高（用 badge 提示用户回主窗口）
        if !schedulerController.isAuthorized {
            Image(systemName: "tray.full.badge.minus")
        } else if !taskStore.runningTaskIDs.isEmpty {
            Image(systemName: "tray.full")
                .symbolEffect(.pulse, options: .repeating)
        } else {
            Image(systemName: "tray.full")
        }
    }
}

private struct MenuBarContent: View {
    @ObservedObject var taskStore: TaskStore
    @ObservedObject var schedulerController: SchedulerServiceController

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        runMenu
        Divider()
        if !schedulerController.isAuthorized {
            Button("后台调度未启用…") { activateMainWindow() }
        }
        Button("打开 Run Shelf") { activateMainWindow() }
            .keyboardShortcut("o", modifiers: [.command])
        Divider()
        Button("退出 Run Shelf") { NSApp.terminate(nil) }
    }

    @ViewBuilder
    private var runMenu: some View {
        Menu("立即运行") {
            let tasks = taskStore.sortedTasks
            let runnableIDs = Set(tasks.filter { taskStore.canRunTask($0) }.map(\.id))

            if tasks.isEmpty {
                Text("暂无任务")
            } else {
                RunTaskMenuItems(
                    tasks: tasks,
                    runningIDs: taskStore.runningTaskIDs,
                    runnableIDs: runnableIDs,
                    onRun: { taskStore.runTask(id: $0) }
                )
            }
        }
    }

    private func activateMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // 主窗口可能已关闭；openWindow 对已存在的同 id 窗口会拿到前台，对不存在的会新建。
        openWindow(id: "main")
    }
}

private struct RunTaskMenuItems: View {
    let tasks: [RunShelfTask]
    let runningIDs: Set<String>
    let runnableIDs: Set<String>
    let onRun: (String) -> Void

    var body: some View {
        ForEach(tasks) { task in
            taskRow(for: task)
        }
    }

    @ViewBuilder
    private func taskRow(for task: RunShelfTask) -> some View {
        let isRunning = runningIDs.contains(task.id)
        Button {
            onRun(task.id)
        } label: {
            if isRunning {
                Text("\(task.manifest.name)（运行中）")
            } else {
                Text(task.manifest.name)
            }
        }
        .disabled(!runnableIDs.contains(task.id))
    }
}
