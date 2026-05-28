import Foundation
import ServiceManagement
import UserNotifications

@MainActor
final class SchedulerServiceController: ObservableObject {
    @Published private(set) var serviceStatus: SMAppService.Status = .notRegistered
    @Published private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var heartbeat: SchedulerHeartbeat?
    @Published private(set) var embeddedSchedulerAvailable = false
    @Published var lastErrorMessage: String?

    private let service = SMAppService.agent(plistName: "com.aix4u.runshelf.scheduler.plist")
    private let decoder: JSONDecoder
    private var isRequestingNotificationAuthorization = false

    init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        refreshAuthorization()
    }

    var isAuthorized: Bool {
        serviceStatus == .enabled
    }

    /// Gate 期间用的轻量刷新：只查 SMAppService 状态和 helper 文件
    func refreshAuthorization() {
        serviceStatus = service.status
        embeddedSchedulerAvailable = isEmbeddedSchedulerAvailable()
    }

    /// 主窗口/Settings 用的诊断刷新：通知权限 + 心跳
    func refreshDiagnostics() {
        RunShelfNotifier.notificationSettings { [weak self] status in
            DispatchQueue.main.async {
                self?.notificationStatus = status
            }
        }
        heartbeat = readHeartbeat()
    }

    func refresh() {
        refreshAuthorization()
        refreshDiagnostics()
    }

    var serviceStatusDisplayName: String {
        if serviceStatus == .notFound, embeddedSchedulerAvailable {
            return "未注册（helper 已嵌入）"
        }
        return serviceStatus.displayName
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Gate 主按钮入口。失败按 SMError 码分流文案；只有当状态最终为
    /// `.requiresApproval` 时才主动跳登录项设置面板。
    func registerForGate() {
        lastErrorMessage = nil
        var registrationErrorResponse: RegistrationErrorResponse = .stayOnGate

        guard embeddedSchedulerAvailable else {
            lastErrorMessage = "调度组件文件损坏，请重装 Run Shelf"
            return
        }

        do {
            try service.register()
            refreshAuthorization()
        } catch {
            registrationErrorResponse = handleServiceRegistrationError(error)
            refreshAuthorization()
        }

        if serviceStatus == .requiresApproval || registrationErrorResponse == .openSettings {
            openLoginItemsSettings()
        }
    }

    func register() {
        lastErrorMessage = nil
        do {
            try service.register()
            refresh()
        } catch {
            _ = handleServiceRegistrationError(error)
            refresh()
        }
    }

    func unregister() {
        lastErrorMessage = nil
        do {
            try service.unregister()
            refresh()
        } catch {
            _ = handleServiceRegistrationError(error)
            refresh()
        }
    }

    func requestNotificationAuthorization() {
        RunShelfNotifier.requestAuthorization { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshDiagnostics()
            }
        }
    }

    /// 弱请求：仅当还没询问过时弹一次原生权限对话框。已授权/已拒绝都不打扰。
    /// 先 sync 一次系统当前状态，避免我们缓存的 notificationStatus 落后于真实情况。
    func requestNotificationAuthorizationIfNeeded() {
        RunShelfNotifier.notificationSettings { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                self.notificationStatus = status
                guard status == .notDetermined else { return }
                guard !self.isRequestingNotificationAuthorization else { return }
                self.isRequestingNotificationAuthorization = true
                RunShelfNotifier.requestAuthorization { _ in
                    DispatchQueue.main.async {
                        self.isRequestingNotificationAuthorization = false
                        self.refreshDiagnostics()
                    }
                }
            }
        }
    }

    @discardableResult
    private func handleServiceRegistrationError(_ error: Error) -> RegistrationErrorResponse {
        let nsError = error as NSError
        #if DEBUG
        print("[Run Shelf] SMAppService 错误 domain=\(nsError.domain) code=\(nsError.code) userInfo=\(nsError.userInfo)")
        #endif

        // SMAppService 在 macOS 13+ 使用 SMAppServiceErrorDomain，code 用 kSMError* 常量。
        // 我们 deployment target 26.0，直接按这些 code 分流。
        guard nsError.domain == SMAppServiceErrorDomain else {
            lastErrorMessage = "注册失败：\(error.localizedDescription)"
            return .stayOnGate
        }

        switch nsError.code {
        case Int(kSMErrorInvalidSignature):
            lastErrorMessage = "调度组件签名无效，请重装 Run Shelf"
            return .stayOnGate
        case Int(kSMErrorJobPlistNotFound), Int(kSMErrorToolNotValid):
            lastErrorMessage = "调度组件文件损坏，请重装 Run Shelf"
            return .stayOnGate
        case Int(kSMErrorInvalidPlist):
            lastErrorMessage = "调度配置异常，请重装 Run Shelf"
            return .stayOnGate
        case Int(kSMErrorAlreadyRegistered):
            // 静默吞掉，由 refreshAuthorization 把状态同步出来
            lastErrorMessage = nil
            return .stayOnGate
        case Int(kSMErrorLaunchDeniedByUser):
            lastErrorMessage = "已被系统拒绝，请在系统设置中重新开启"
            return .openSettings
        default:
            lastErrorMessage = "注册失败：\(error.localizedDescription)"
            return .stayOnGate
        }
    }

    private func readHeartbeat() -> SchedulerHeartbeat? {
        guard let data = try? Data(contentsOf: RunShelfPaths.schedulerHeartbeatURL()) else { return nil }
        return try? decoder.decode(SchedulerHeartbeat.self, from: data)
    }

    private func isEmbeddedSchedulerAvailable() -> Bool {
        let bundleURL = Bundle.main.bundleURL
        let helperURL = bundleURL
            .appendingPathComponent("Contents/Library/Helpers/RunShelfScheduler")
        let plistURL = bundleURL
            .appendingPathComponent("Contents/Library/LaunchAgents/com.aix4u.runshelf.scheduler.plist")
        return FileManager.default.fileExists(atPath: helperURL.path)
            && FileManager.default.fileExists(atPath: plistURL.path)
    }
}

private enum RegistrationErrorResponse {
    case stayOnGate
    case openSettings
}

extension SMAppService.Status {
    var displayName: String {
        switch self {
        case .notRegistered:
            return "未注册"
        case .enabled:
            return "已启用"
        case .requiresApproval:
            return "需要在系统设置中批准"
        case .notFound:
            return "未找到后台调度进程"
        @unknown default:
            return "未知"
        }
    }
}

extension UNAuthorizationStatus {
    var displayName: String {
        switch self {
        case .notDetermined:
            return "未询问"
        case .denied:
            return "已拒绝"
        case .authorized:
            return "已授权"
        case .provisional:
            return "临时授权"
        case .ephemeral:
            return "临时授权"
        @unknown default:
            return "未知"
        }
    }
}
