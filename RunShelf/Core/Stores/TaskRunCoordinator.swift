import Foundation

@MainActor
final class TaskRunCoordinator {
    private var cancellations: [String: [String: TaskRunCancellation]] = [:]
    private var startTimes: [String: [String: Date]] = [:]

    var runningTaskIDs: Set<String> {
        Set(startTimes.compactMap { id, starts in starts.isEmpty ? nil : id })
    }

    var runningStartedAt: [String: Date] {
        startTimes.compactMapValues { $0.values.min() }
    }

    func start(
        task: RunShelfTask,
        runID: String,
        onStateChange: @escaping @MainActor () -> Void,
        completion: @escaping @MainActor (Result<RunRecord, Error>) -> Void
    ) {
        let cancellation = TaskRunCancellation()
        cancellations[task.id, default: [:]][runID] = cancellation
        startTimes[task.id, default: [:]][runID] = Date()
        onStateChange()

        Task.detached(priority: .userInitiated) {
            let result = Result {
                try TaskRunner.run(
                    task: task,
                    trigger: .manual,
                    runId: runID,
                    host: "app",
                    cancellation: cancellation
                )
            }
            await MainActor.run {
                self.cancellations[task.id]?.removeValue(forKey: runID)
                self.startTimes[task.id]?.removeValue(forKey: runID)
                if self.cancellations[task.id]?.isEmpty != false {
                    self.cancellations.removeValue(forKey: task.id)
                    self.startTimes.removeValue(forKey: task.id)
                }
                onStateChange()
                completion(result)
            }
        }
    }

    func cancel(taskID: String) {
        guard let activeCancellations = cancellations[taskID]?.values else { return }
        for cancellation in activeCancellations {
            cancellation.cancel()
        }
    }

    func canCancel(taskID: String) -> Bool {
        cancellations[taskID]?.isEmpty == false
    }
}
