import SwiftUI

@main
struct RunShelfApp: App {
    @StateObject private var schedulerController: SchedulerServiceController
    @State private var isGateActive: Bool

    init() {
        let controller = SchedulerServiceController()
        _schedulerController = StateObject(wrappedValue: controller)
        // 一次性快照：仅在 app 启动时决定是否拦截。
        // 之后无论 serviceStatus 怎么变（Settings 里 unregister、系统设置关掉登录项），
        // 本会话不再回到 Gate；下次启动重新判断。
        _isGateActive = State(initialValue: !controller.isAuthorized && !Self.shouldBypassGateForUITesting)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if isGateActive {
                    PermissionGateView {
                        // Gate 通过的瞬间补一次诊断刷新，让 TaskInspector 拿到通知权限真实状态
                        schedulerController.refreshDiagnostics()
                        isGateActive = false
                    }
                } else {
                    ContentView()
                        .frame(
                            minWidth: RunShelfWindowMetrics.mainMinWidth,
                            minHeight: RunShelfWindowMetrics.mainMinHeight
                        )
                }
            }
            .environmentObject(schedulerController)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .saveItem) {
                Button("保存") {
                    NotificationCenter.default.post(name: .saveSelectedTaskFromMenu, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(isGateActive)
            }

            CommandGroup(after: .saveItem) {
                Button("立即运行") {
                    NotificationCenter.default.post(name: .runSelectedTaskFromMenu, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(isGateActive)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(schedulerController)
        }
    }
}

private extension RunShelfApp {
    static var shouldBypassGateForUITesting: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["RUN_SHELF_BYPASS_GATE"] == "1"
        #else
        false
        #endif
    }
}

extension Notification.Name {
    static let saveSelectedTaskFromMenu = Notification.Name("RunShelf.saveSelectedTaskFromMenu")
    static let runSelectedTaskFromMenu = Notification.Name("RunShelf.runSelectedTaskFromMenu")
}
