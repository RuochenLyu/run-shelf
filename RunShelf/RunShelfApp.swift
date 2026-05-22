import SwiftUI

@main
struct RunShelfApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1120, minHeight: 680)
        }
        .windowStyle(.titleBar)
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
            }
        }

        Settings {
            SettingsView()
        }
    }
}

extension Notification.Name {
    static let saveSelectedTaskFromMenu = Notification.Name("RunShelf.saveSelectedTaskFromMenu")
    static let runSelectedTaskFromMenu = Notification.Name("RunShelf.runSelectedTaskFromMenu")
}
