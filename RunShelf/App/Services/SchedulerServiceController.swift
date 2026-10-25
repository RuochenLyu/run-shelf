import AppKit
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
    private let registrationSignatureKey = "schedulerRegistrationSignature"
    private let decoder: JSONDecoder
    private var isRequestingNotificationAuthorization = false
    private var isRepairingRegistration = false
    private var attemptedRegistrationRepairSignature: String?
    /// 预览构建与正式版共用 bundle id；临时数据目录下注册会把正式版的后台调度指向预览构建。
    private let registrationLocked = RunShelfPaths.isAppSupportOverridden
    private let registrationLockedMessage = "预览模式（RUN_SHELF_APP_SUPPORT_DIR）不改动后台调度注册。"

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
        repairRegistrationIfNeeded()
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

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// 通知设置没有 SMAppService 那样的官方 API，用 deeplink best-effort。
    /// schema 失效时 fallback 到 System Settings 主面板。
    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"),
           NSWorkspace.shared.open(url) {
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    /// Gate 主按钮入口。失败按 SMError 码分流文案；只有当状态最终为
    /// `.requiresApproval` 时才主动跳登录项设置面板。
    func registerForGate() {
        guard !registrationLocked else {
            lastErrorMessage = registrationLockedMessage
            return
        }
        lastErrorMessage = nil
        var registrationErrorResponse: RegistrationErrorResponse = .stayOnGate

        guard embeddedSchedulerAvailable else {
            lastErrorMessage = "调度组件文件损坏，请重装 Run Shelf。"
            return
        }

        do {
            try service.register()
            markCurrentRegistrationSignature()
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
        guard !registrationLocked else {
            lastErrorMessage = registrationLockedMessage
            return
        }
        lastErrorMessage = nil
        do {
            try service.register()
            markCurrentRegistrationSignature()
            refresh()
        } catch {
            _ = handleServiceRegistrationError(error)
            refresh()
        }
    }

    func unregister() {
        guard !registrationLocked else {
            lastErrorMessage = registrationLockedMessage
            return
        }
        lastErrorMessage = nil
        do {
            try service.unregister()
            UserDefaults.standard.removeObject(forKey: registrationSignatureKey)
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
            lastErrorMessage = "注册失败：\(error.localizedDescription)。"
            return .stayOnGate
        }

        switch nsError.code {
        case Int(kSMErrorInvalidSignature):
            lastErrorMessage = "调度组件签名无效，请重装 Run Shelf。"
            return .stayOnGate
        case Int(kSMErrorJobPlistNotFound), Int(kSMErrorToolNotValid):
            lastErrorMessage = "调度组件文件损坏，请重装 Run Shelf。"
            return .stayOnGate
        case Int(kSMErrorInvalidPlist):
            lastErrorMessage = "调度配置异常，请重装 Run Shelf。"
            return .stayOnGate
        case Int(kSMErrorAlreadyRegistered):
            // 静默吞掉，由 refreshAuthorization 把状态同步出来
            lastErrorMessage = nil
            return .stayOnGate
        case Int(kSMErrorLaunchDeniedByUser):
            lastErrorMessage = "登录项未授权，请在系统设置中重新启用 Run Shelf。"
            return .openSettings
        default:
            lastErrorMessage = "注册失败：\(error.localizedDescription)。"
            return .stayOnGate
        }
    }

    private func readHeartbeat() -> SchedulerHeartbeat? {
        guard let data = try? Data(contentsOf: RunShelfPaths.schedulerHeartbeatURL()) else { return nil }
        return try? decoder.decode(SchedulerHeartbeat.self, from: data)
    }

    private func isEmbeddedSchedulerAvailable() -> Bool {
        let helperURL = embeddedSchedulerURL()
        let plistURL = embeddedSchedulerPlistURL()
        return FileManager.default.fileExists(atPath: helperURL.path)
            && FileManager.default.fileExists(atPath: plistURL.path)
    }

    private func repairRegistrationIfNeeded() {
        guard !registrationLocked else { return }
        guard serviceStatus == .enabled else { return }
        guard embeddedSchedulerAvailable else { return }
        guard !isRepairingRegistration else { return }
        guard let signature = currentRegistrationSignature() else { return }
        guard UserDefaults.standard.string(forKey: registrationSignatureKey) != signature else { return }
        guard attemptedRegistrationRepairSignature != signature else { return }

        isRepairingRegistration = true
        attemptedRegistrationRepairSignature = signature
        service.unregister { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.lastErrorMessage = "后台调度刷新失败：\(error.localizedDescription)。"
                    self.isRepairingRegistration = false
                    self.refreshAuthorization()
                    return
                }

                do {
                    try self.service.register()
                    UserDefaults.standard.set(signature, forKey: self.registrationSignatureKey)
                    self.lastErrorMessage = nil
                } catch {
                    _ = self.handleServiceRegistrationError(error)
                }

                self.isRepairingRegistration = false
                self.refreshAuthorization()
            }
        }
    }

    private func markCurrentRegistrationSignature() {
        guard let signature = currentRegistrationSignature() else { return }
        UserDefaults.standard.set(signature, forKey: registrationSignatureKey)
    }

    private func currentRegistrationSignature() -> String? {
        guard let helperSignature = fileSignature(for: embeddedSchedulerURL()) else { return nil }
        guard let plistSignature = fileSignature(for: embeddedSchedulerPlistURL()) else { return nil }
        return [
            "bundleProgram=Contents/Library/LaunchServices/RunShelfScheduler",
            helperSignature,
            plistSignature
        ].joined(separator: "|")
    }

    private func fileSignature(for url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        guard let size = attributes[.size] as? NSNumber else { return nil }
        guard let modifiedAt = attributes[.modificationDate] as? Date else { return nil }
        return "\(url.path):\(size.int64Value):\(modifiedAt.timeIntervalSince1970)"
    }

    private func embeddedSchedulerURL() -> URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchServices/RunShelfScheduler")
    }

    private func embeddedSchedulerPlistURL() -> URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchAgents/com.aix4u.runshelf.scheduler.plist")
    }
}

private enum RegistrationErrorResponse {
    case stayOnGate
    case openSettings
}
