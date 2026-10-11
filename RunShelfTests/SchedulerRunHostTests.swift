import Darwin
import Foundation
import XCTest

final class SchedulerRunHostTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots = []
        super.tearDown()
    }

    func testArgumentsRoundTripIncludingFractionalScheduledAt() throws {
        let taskID = UUID().uuidString
        let scheduledAt = Date(timeIntervalSince1970: 1_791_712_260.25)
        let arguments = SchedulerRunHost.arguments(taskID: taskID, runID: "2026-10-11T17-11-25+08-00-ABCDEF01", scheduledAt: scheduledAt)

        let parsed = try SchedulerRunHost.parseArguments(arguments)

        XCTAssertEqual(parsed.taskID, taskID)
        XCTAssertEqual(parsed.runID, "2026-10-11T17-11-25+08-00-ABCDEF01")
        XCTAssertEqual(try XCTUnwrap(parsed.scheduledAt).timeIntervalSince1970, scheduledAt.timeIntervalSince1970, accuracy: 0.001)

        let withoutDate = try SchedulerRunHost.parseArguments(
            SchedulerRunHost.arguments(taskID: taskID, runID: "run-1", scheduledAt: nil)
        )
        XCTAssertNil(withoutDate.scheduledAt)
    }

    func testParseArgumentsRejectsUnsafeOrIncompleteInput() {
        let taskID = UUID().uuidString
        let invalid: [[String]] = [
            [],
            ["--task-id", taskID, "--run-id", "run-1"],
            [SchedulerRunHost.command, "--task-id", "not-a-uuid", "--run-id", "run-1"],
            [SchedulerRunHost.command, "--task-id", taskID, "--run-id", "../escape"],
            [SchedulerRunHost.command, "--task-id", taskID],
            [SchedulerRunHost.command, "--task-id", taskID, "--run-id"],
            [SchedulerRunHost.command, "--task-id", taskID, "--run-id", "run-1", "--scheduled-at", "yesterday"],
            [SchedulerRunHost.command, "--task-id", taskID, "--run-id", "run-1", "--extra", "x"]
        ]
        for arguments in invalid {
            XCTAssertThrowsError(try SchedulerRunHost.parseArguments(arguments), "\(arguments)")
        }
    }

    func testWaitStatusDescriptions() {
        XCTAssertEqual(SchedulerRunHost.describe(waitStatus: nil), "无法回收宿主进程")
        XCTAssertEqual(SchedulerRunHost.describe(waitStatus: 2 << 8), "退出码 2")
        XCTAssertEqual(SchedulerRunHost.describe(waitStatus: SIGKILL), "被信号 9 终止")
    }

    func testConcurrentLeaseUpdatesDoNotDropProcessGroup() throws {
        // 启动方写宿主 pid 与宿主写进程组并发：无锁读-改-写时后写者会把 processGroupID 覆盖回 nil。
        for attempt in 0..<20 {
            let fixture = try makeFixture(name: "claim-race-\(attempt)", script: "#!/bin/zsh\nexit 0\n")
            let lease = try TaskRunClaimManager.acquire(task: fixture.task, runID: "race-\(attempt)", host: "test")
            let start = DispatchSemaphore(value: 0)
            let group = DispatchGroup()
            DispatchQueue.global().async(group: group) {
                start.wait()
                for _ in 0..<50 {
                    try? lease.update(processID: getpid(), host: "launcher")
                }
            }
            DispatchQueue.global().async(group: group) {
                start.wait()
                try? lease.update(processGroupID: getpgrp())
            }
            start.signal()
            start.signal()
            group.wait()

            let claim = try XCTUnwrap(TaskRunClaimManager.readClaim(at: lease.claimURL))
            XCTAssertEqual(claim.processGroupID, getpgrp(), "attempt \(attempt) lost processGroupID")
            XCTAssertNotNil(claim.processGroupLeaderIdentity)
            lease.release()
        }
    }

    func testRunHostRunsUnderLauncherClaimRecordsScheduledFailureAndQueuesNotification() throws {
        let fixture = try makeFixture(name: "host-failure", script: "#!/bin/zsh\necho boom >&2\nexit 4\n")
        let runID = TaskRunner.makeRunID(from: Date())
        let scheduledAt = Date(timeIntervalSince1970: 1_791_712_260)
        _ = try TaskRunClaimManager.acquire(task: fixture.task, runID: runID, host: SchedulerRunHost.launcherHostName)
        var errors: [String] = []

        let exitCode = SchedulerRunHost.runHost(
            arguments: .init(taskID: fixture.task.id, runID: runID, scheduledAt: scheduledAt),
            tasksDirectoryURL: fixture.tasksURL,
            outbox: fixture.outbox,
            errorOutput: { errors.append($0) }
        )

        XCTAssertEqual(exitCode, 1)
        XCTAssertEqual(errors, [])
        let record = try XCTUnwrap(TaskFileStore(tasksDirectoryURL: fixture.tasksURL).loadRun(for: fixture.task.directoryURL, runID: runID))
        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(record.exitCode, 4)
        XCTAssertEqual(record.trigger, .scheduled)
        XCTAssertEqual(record.scheduledAt, scheduledAt)
        XCTAssertNil(TaskRunClaimManager.activeClaim(for: fixture.task))
        XCTAssertEqual(fixture.outbox.pending().map(\.runId), [runID])
    }

    func testRunHostWithoutClaimFailsWithoutWritingRecord() throws {
        let fixture = try makeFixture(name: "host-no-claim", script: "#!/bin/zsh\nexit 0\n")
        var errors: [String] = []

        let exitCode = SchedulerRunHost.runHost(
            arguments: .init(taskID: fixture.task.id, runID: "missing-claim", scheduledAt: nil),
            tasksDirectoryURL: fixture.tasksURL,
            outbox: fixture.outbox,
            errorOutput: { errors.append($0) }
        )

        XCTAssertEqual(exitCode, 2)
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].contains("missing-claim"))
        XCTAssertNil(try TaskFileStore(tasksDirectoryURL: fixture.tasksURL).loadRun(for: fixture.task.directoryURL, runID: "missing-claim"))
        XCTAssertTrue(fixture.outbox.pending().isEmpty)
    }

    // MARK: - Helpers

    private struct Fixture {
        var task: RunShelfTask
        var tasksURL: URL
        var outbox: RunShelfNotificationOutbox
    }

    private func makeFixture(name: String, script: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SchedulerRunHostTests-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        let tasksURL = root.appendingPathComponent("tasks", isDirectory: true)
        let taskID = UUID().uuidString
        let taskURL = tasksURL.appendingPathComponent(taskID, isDirectory: true)
        try FileManager.default.createDirectory(at: taskURL.appendingPathComponent("runs"), withIntermediateDirectories: true)
        let manifest = TaskManifest(
            schemaVersion: 1,
            id: taskID,
            name: name,
            description: "",
            enabled: true,
            createdAt: Date(),
            updatedAt: Date(),
            schedule: TaskSchedule(type: "cron", expression: "* * * * *", timezone: "local"),
            runner: TaskRunnerPolicy(
                concurrency: "skip",
                timeoutSeconds: 0,
                missedRunPolicy: MissedRunPolicy(type: "skipIfLate", maxDelaySeconds: 1_800)
            ),
            notifications: .defaultPolicy,
            retention: RetentionPolicy(days: 30, maxRuns: 100)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: taskURL.appendingPathComponent("task.json"))
        try script.write(to: taskURL.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)
        try "".write(to: taskURL.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        let task = RunShelfTask(
            manifest: manifest,
            directoryURL: taskURL,
            script: script,
            notes: "",
            runs: [],
            isDirty: false
        )
        let outbox = RunShelfNotificationOutbox(
            directoryURL: RunShelfPaths.notificationOutboxURL(appSupportDirectoryURL: root)
        )
        return Fixture(task: task, tasksURL: tasksURL, outbox: outbox)
    }
}
