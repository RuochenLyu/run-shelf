import AppKit
import SwiftUI

struct PermissionGateView: View {
    @EnvironmentObject private var controller: SchedulerServiceController
    var onDismiss: () -> Void

    var body: some View {
        let state = makeState()

        VStack(spacing: 0) {
            Spacer()

            Image(systemName: state.iconName)
                .font(.system(size: 64, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(state.iconColor)
                .padding(.bottom, 24)

            Text(state.title)
                .font(.title2.weight(.semibold))
                .padding(.bottom, 12)

            Text(state.subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
                .padding(.bottom, 32)

            Button(action: state.primaryAction) {
                Text(state.primaryLabel)
                    .frame(minWidth: 180)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.green)

            if let msg = controller.lastErrorMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .padding(.top, 12)
            }

            Spacer()

            if !state.hidesQuitButton {
                Button("退出 Run Shelf") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.bottom, 18)
            }
        }
        .frame(width: 480, height: 380)
        .background(.regularMaterial)
        .background(GateWindowAccessor())
        .onAppear {
            // 启动期已经查过状态了，这里只是补刀防御：万一已经授权就直接放行
            dismissIfAuthorized()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refreshAuthorization()
            dismissIfAuthorized()
        }
        .onChange(of: controller.serviceStatus) { _, _ in
            dismissIfAuthorized()
        }
    }

    private func makeState() -> GateState {
        // 环境不可恢复：helper 二进制或 plist 缺失（用户拿到的是损坏的应用 bundle）
        if !controller.embeddedSchedulerAvailable {
            return GateState(
                iconName: "exclamationmark.triangle.fill",
                iconColor: .orange,
                title: "应用安装不完整",
                subtitle: "请重新下载并安装 Run Shelf。",
                primaryLabel: "退出",
                primaryAction: { NSApp.terminate(nil) },
                hidesQuitButton: true
            )
        }

        // 所有 ≠ enabled 的状态统一一种引导：去系统设置开开关。
        // .requiresApproval（已注册）直接跳设置；其他情况（.notRegistered / .notFound）
        // 先调 register 再跳。register 失败的细节通过 lastErrorMessage 在按钮下方显示。
        let action: () -> Void = {
            if controller.serviceStatus == .requiresApproval {
                controller.openLoginItemsSettings()
            } else {
                controller.registerForGate()
                dismissIfAuthorized()
            }
        }

        return GateState(
            iconName: "clock.badge.checkmark",
            iconColor: .accentColor,
            title: "让 Run Shelf 在后台运行",
            subtitle: "关闭应用后，定时任务仍能按时执行。\n在「登录项与扩展」中启用 Run Shelf 即可。",
            primaryLabel: "打开系统设置",
            primaryAction: action,
            hidesQuitButton: false
        )
    }

    private func dismissIfAuthorized() {
        guard controller.isAuthorized else { return }
        onDismiss()
    }
}

private struct GateState {
    let iconName: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let primaryLabel: String
    let primaryAction: () -> Void
    let hidesQuitButton: Bool
}

/// 接管 Gate 所在 NSWindow：
/// - 固定 480x380、屏幕居中、不可调整大小
/// - 拦截关闭按钮 → terminate（保证“必开”语义不被红色按钮绕过）
/// - dismantle 时恢复主窗口的 styleMask 和合理尺寸，避免主窗口继承 Gate 的限制
private struct GateWindowAccessor: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            context.coordinator.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard context.coordinator.window == nil else { return }
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            context.coordinator.attach(to: window)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        weak var window: NSWindow?
        private weak var previousDelegate: NSWindowDelegate?
        private var previousStyleMask: NSWindow.StyleMask?
        private var isTerminating = false

        func attach(to window: NSWindow) {
            guard self.window !== window else { return }
            self.window = window
            self.previousDelegate = window.delegate
            self.previousStyleMask = window.styleMask

            window.delegate = self

            let size = RunShelfWindowMetrics.gateContentSize
            if let screen = window.screen ?? NSScreen.main {
                let screenFrame = screen.visibleFrame
                let origin = NSPoint(
                    x: screenFrame.midX - size.width / 2,
                    y: screenFrame.midY - size.height / 2
                )
                window.setFrame(NSRect(origin: origin, size: size), display: true)
            } else {
                window.setContentSize(size)
            }
            window.styleMask.remove(.resizable)
        }

        func detach() {
            guard let window else { return }
            if window.delegate === self {
                window.delegate = previousDelegate
            }
            if let mask = previousStyleMask {
                window.styleMask = mask
            }
            // 不恢复 Gate 期间记下的 frame —— 那个 frame 是 Gate 自己的尺寸
            // 直接给主窗口一个合理的初始内容尺寸（与 ContentView .frame minWidth/minHeight 一致）
            window.setContentSize(RunShelfWindowMetrics.mainContentSize)
            window.center()

            self.window = nil
            self.previousDelegate = nil
            self.previousStyleMask = nil
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard !isTerminating else { return false }
            isTerminating = true
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
            return false
        }
    }
}
