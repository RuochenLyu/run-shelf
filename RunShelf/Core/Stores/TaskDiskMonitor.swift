import Foundation

@MainActor
final class TaskDiskMonitor {
    typealias InputProvider = @MainActor () -> DiskScanInput?
    typealias ResultHandler = @MainActor (DiskScanResult) -> Void

    private var inputProvider: InputProvider?
    private var resultHandler: ResultHandler?
    private var periodicTask: Task<Void, Never>?
    private var isRefreshing = false
    private var refreshPending = false

    deinit {
        periodicTask?.cancel()
    }

    func start(
        intervalNanoseconds: UInt64 = 5_000_000_000,
        inputProvider: @escaping InputProvider,
        resultHandler: @escaping ResultHandler
    ) {
        self.inputProvider = inputProvider
        self.resultHandler = resultHandler
        periodicTask?.cancel()
        requestRefresh()
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNanoseconds)
                guard !Task.isCancelled else { break }
                self?.requestRefresh()
            }
        }
    }

    func requestRefresh() {
        guard !isRefreshing else {
            refreshPending = true
            return
        }
        guard let input = inputProvider?() else { return }
        isRefreshing = true

        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                DiskScanner.scan(input)
            }.value
            guard let self, !Task.isCancelled else { return }
            resultHandler?(result)
            isRefreshing = false
            if refreshPending {
                refreshPending = false
                requestRefresh()
            }
        }
    }
}
