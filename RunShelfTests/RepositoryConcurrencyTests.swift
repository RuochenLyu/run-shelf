import Foundation
import XCTest

final class RepositoryConcurrencyTests: XCTestCase {
    func testConcurrentCreateAllowsExactlyOneSlugOwner() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repositoryA = TaskRepository(tasksDirectoryURL: root)
        let repositoryB = TaskRepository(tasksDirectoryURL: root)
        let start = DispatchSemaphore(value: 0)
        let complete = DispatchGroup()
        let resultLock = NSLock()
        var results: [Result<TaskRepositoryWriteResult, Error>] = []

        for (index, repository) in [repositoryA, repositoryB].enumerated() {
            complete.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                start.wait()
                let result = Result {
                    try repository.createTask(from: TaskSpec(
                        slug: "one-owner",
                        name: "Owner \(index)",
                        script: "#!/bin/zsh\n"
                    ))
                }
                resultLock.withLock { results.append(result) }
                complete.leave()
            }
        }

        start.signal()
        start.signal()
        XCTAssertEqual(complete.wait(timeout: .now() + 5), .success)
        let successes = results.compactMap { try? $0.get() }
        XCTAssertEqual(successes.count, 1)
        XCTAssertEqual(try TaskFileStore(tasksDirectoryURL: root).loadTasks(includeRuns: false).count, 1)
    }

    func testDeletedTaskCannotBeResurrectedByClaimAcquisition() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = TaskRepository(tasksDirectoryURL: root)
        let created = try repository.createTask(from: TaskSpec(
            slug: "deleted-task",
            name: "Deleted Task",
            script: "#!/bin/zsh\n"
        ))

        _ = try repository.deleteTask(selector: .id(created.task.id))
        XCTAssertThrowsError(try TaskRunClaimManager.acquire(
            task: created.task,
            runID: "should-not-exist",
            host: "test"
        )) { error in
            guard case TaskRepositoryError.taskDirectoryMissing = error else {
                return XCTFail("expected taskDirectoryMissing, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: created.task.directoryURL.path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunShelfRepositoryConcurrencyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
