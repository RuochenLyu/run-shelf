import Foundation
import XCTest

final class NotificationOutboxTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots = []
        super.tearDown()
    }

    func testUserNotificationsRequireAppBundleWithIdentifier() {
        let schedulerURL = URL(fileURLWithPath: "/Applications/Run Shelf.app/Contents/Library/LaunchServices", isDirectory: true)
        XCTAssertFalse(RunShelfNotifier.canUseUserNotifications(
            bundleURL: schedulerURL,
            bundleIdentifier: "com.aix4u.runshelf.scheduler"
        ))
        XCTAssertFalse(RunShelfNotifier.canUseUserNotifications(
            bundleURL: URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            bundleIdentifier: nil
        ))
        XCTAssertFalse(RunShelfNotifier.canUseUserNotifications(
            bundleURL: URL(fileURLWithPath: "/Applications/Run Shelf.app", isDirectory: true),
            bundleIdentifier: nil
        ))
        XCTAssertTrue(RunShelfNotifier.canUseUserNotifications(
            bundleURL: URL(fileURLWithPath: "/Applications/Run Shelf.app", isDirectory: true),
            bundleIdentifier: "com.aix4u.runshelf"
        ))
    }

    func testNonAppProcessNotifierCallsDegradeWithoutTouchingNotificationCenter() throws {
        // xctest 进程不是 .app：这些调用必须走降级分支，而不是断言 abort。
        try XCTSkipIf(RunShelfNotifier.isUserNotificationContextAvailable, "test host is an app bundle")

        let settings = expectation(description: "settings")
        RunShelfNotifier.notificationSettings { status in
            XCTAssertEqual(status, .notDetermined)
            settings.fulfill()
        }
        let authorization = expectation(description: "authorization")
        RunShelfNotifier.requestAuthorization { granted in
            XCTAssertFalse(granted)
            authorization.fulfill()
        }
        wait(for: [settings, authorization], timeout: 1)

        let outbox = try makeOutbox()
        try outbox.enqueue(notification(runId: "r1"))
        RunShelfNotifier.notifyFailure(task: makeTask(), run: makeRun(runId: "direct", status: .failed))
        let drained = expectation(description: "drain")
        RunShelfNotifier.drainOutbox(outbox) { drained.fulfill() }
        wait(for: [drained], timeout: 1)
        XCTAssertEqual(outbox.pending().map(\.runId), ["r1"], "non-app process must not consume the outbox")
    }

    func testOutboxDrainsInCreationOrderAndDeletesEntries() throws {
        let outbox = try makeOutbox()
        let now = Date()
        try outbox.enqueue(notification(runId: "later", createdAt: now.addingTimeInterval(-10)), now: now)
        try outbox.enqueue(notification(runId: "earlier", createdAt: now.addingTimeInterval(-20)), now: now)

        var delivered: [String] = []
        outbox.drain(now: now) { delivered.append($0.runId) }

        XCTAssertEqual(delivered, ["earlier", "later"])
        XCTAssertTrue(outbox.pending(now: now).isEmpty)
        XCTAssertEqual(try visibleFiles(in: outbox), [])
    }

    func testOutboxReenqueueOfSameRunReplacesEntry() throws {
        let outbox = try makeOutbox()
        try outbox.enqueue(notification(runId: "same", body: "first"))
        try outbox.enqueue(notification(runId: "same", body: "second"))

        XCTAssertEqual(outbox.pending().map(\.body), ["second"])
    }

    func testOutboxDropsExpiredCorruptAndUnknownSchemaEntries() throws {
        let outbox = try makeOutbox()
        let now = Date()
        try outbox.enqueue(notification(runId: "fresh", createdAt: now.addingTimeInterval(-60)), now: now)
        try outbox.enqueue(notification(runId: "expired", createdAt: now.addingTimeInterval(-25 * 60 * 60)), now: now)
        try Data("{".utf8).write(to: outbox.directoryURL.appendingPathComponent("corrupt.json"))
        var future = notification(runId: "future-schema")
        future.schemaVersion = 99
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(future).write(to: outbox.directoryURL.appendingPathComponent("future.json"))

        XCTAssertEqual(outbox.pending(now: now).map(\.runId), ["fresh"])
        XCTAssertEqual(try visibleFiles(in: outbox), [RunShelfNotificationOutbox.fileName(for: notification(runId: "fresh"))])
    }

    func testOutboxIgnoresInFlightTemporaryFilesUntilTheyExpire() throws {
        let outbox = try makeOutbox()
        let temporaryURL = outbox.directoryURL.appendingPathComponent(".partial.json.tmp")
        try Data("{".utf8).write(to: temporaryURL)

        XCTAssertTrue(outbox.pending().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryURL.path))

        _ = outbox.pending(now: Date().addingTimeInterval(2 * RunShelfNotificationOutbox.defaultMaxAge))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
    }

    func testOutboxCapsEntriesWhenAppNeverDrains() throws {
        let outbox = try makeOutbox(maxEntries: 3)
        let now = Date()
        for index in 0..<5 {
            try outbox.enqueue(
                notification(runId: "run-\(index)", createdAt: now.addingTimeInterval(TimeInterval(index))),
                now: now
            )
        }

        XCTAssertEqual(outbox.pending(now: now).map(\.runId), ["run-2", "run-3", "run-4"])
    }

    func testOutboxFileNameSanitizesPathSeparators() {
        var value = notification(runId: "../../escape")
        value.taskId = "a/b"
        let name = RunShelfNotificationOutbox.fileName(for: value)
        XCTAssertFalse(name.contains("/"))
        XCTAssertTrue(name.hasSuffix(".json"))
    }

    func testFailureNotificationBodyMatchesStatus() {
        let task = makeTask()
        XCTAssertEqual(RunShelfFailureNotification(task: task, run: makeRun(runId: "a", status: .failed, exitCode: 2)).body, "退出码：2")
        XCTAssertEqual(RunShelfFailureNotification(task: task, run: makeRun(runId: "b", status: .timeout)).body, "运行超时")
        XCTAssertEqual(
            RunShelfFailureNotification(task: task, run: makeRun(runId: "c", status: .timeout)).identifier,
            "run-shelf-\(task.id)-c"
        )
    }

    // MARK: - Helpers

    private func makeOutbox(maxEntries: Int = RunShelfNotificationOutbox.defaultMaxEntries) throws -> RunShelfNotificationOutbox {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunShelfOutboxTests-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        let outbox = RunShelfNotificationOutbox(
            directoryURL: RunShelfPaths.notificationOutboxURL(appSupportDirectoryURL: root),
            maxEntries: maxEntries
        )
        try FileManager.default.createDirectory(at: outbox.directoryURL, withIntermediateDirectories: true)
        return outbox
    }

    private func visibleFiles(in outbox: RunShelfNotificationOutbox) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: outbox.directoryURL.path)
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    private func notification(
        runId: String,
        body: String = "退出码：1",
        createdAt: Date = Date()
    ) -> RunShelfFailureNotification {
        var value = RunShelfFailureNotification(
            task: makeTask(),
            run: makeRun(runId: runId, status: .failed),
            createdAt: createdAt
        )
        value.body = body
        return value
    }

    private func makeTask() -> RunShelfTask {
        RunShelfTask(
            manifest: TaskManifest(
                schemaVersion: 1,
                id: "11111111-2222-3333-4444-555555555555",
                name: "outbox",
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
            ),
            directoryURL: FileManager.default.temporaryDirectory,
            script: "",
            notes: "",
            runs: [],
            isDirty: false
        )
    }

    private func makeRun(runId: String, status: TaskRunStatus, exitCode: Int? = nil) -> RunRecord {
        RunRecord(
            runId: runId,
            taskId: "11111111-2222-3333-4444-555555555555",
            trigger: .scheduled,
            status: status,
            exitCode: exitCode,
            scheduledAt: nil,
            startedAt: Date(),
            endedAt: Date(),
            durationMs: 0,
            scriptSha256: "",
            stdoutPath: "stdout.log",
            stderrPath: "stderr.log",
            message: nil
        )
    }
}
