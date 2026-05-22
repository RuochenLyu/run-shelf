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

    init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        refresh()
    }

    func refresh() {
        serviceStatus = service.status
        embeddedSchedulerAvailable = isEmbeddedSchedulerAvailable()
        RunShelfNotifier.notificationSettings { [weak self] status in
            DispatchQueue.main.async {
                self?.notificationStatus = status
            }
        }
        heartbeat = readHeartbeat()
    }

    var serviceStatusDisplayName: String {
        if serviceStatus == .notFound, embeddedSchedulerAvailable {
            return "未注册（helper 已嵌入）"
        }
        return serviceStatus.displayName
    }

    func register() {
        do {
            try service.register()
            refresh()
        } catch {
            lastErrorMessage = error.localizedDescription
            refresh()
        }
    }

    func unregister() {
        do {
            try service.unregister()
            refresh()
        } catch {
            lastErrorMessage = error.localizedDescription
            refresh()
        }
    }

    func requestNotificationAuthorization() {
        RunShelfNotifier.requestAuthorization { [weak self] _ in
            DispatchQueue.main.async {
                self?.refresh()
            }
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
