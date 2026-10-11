import Foundation

/// 把调度进程写入 outbox 的失败通知转投到系统通知中心。
///
/// 只在 App 进程里运行：调度进程是裸可执行文件，不能调用 UserNotifications。
/// 取舍：App 未运行期间不会弹通知；App 启动后 5 秒内补发最近 24 小时内的条目，
/// 更早的直接丢弃（见 `RunShelfNotificationOutbox.defaultMaxAge`）。
final class FailureNotificationRelay {
    static let pollInterval: TimeInterval = 5

    private let outbox: RunShelfNotificationOutbox
    private let queue = DispatchQueue(label: "com.aix4u.runshelf.notification-relay", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var isDraining = false

    init(outbox: RunShelfNotificationOutbox = RunShelfNotificationOutbox()) {
        self.outbox = outbox
    }

    func start() {
        queue.async {
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(
                deadline: .now(),
                repeating: Self.pollInterval,
                leeway: .seconds(1)
            )
            timer.setEventHandler { [weak self] in
                self?.drainIfIdle()
            }
            self.timer = timer
            timer.resume()
        }
    }

    deinit {
        timer?.cancel()
    }

    private func drainIfIdle() {
        guard !isDraining else { return }
        isDraining = true
        RunShelfNotifier.drainOutbox(outbox) { [weak self] in
            guard let self else { return }
            self.queue.async {
                self.isDraining = false
            }
        }
    }
}
