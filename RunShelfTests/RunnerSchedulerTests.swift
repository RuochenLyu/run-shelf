import Foundation
import XCTest

final class RunnerSchedulerTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots = []
        super.tearDown()
    }

    func testLatestMatchingRunIsNotLimitedToFirst64Matches() throws {
        let schedule = try CronSchedule.parse("* * * * *")
        let start = try date(2026, 1, 1, 0, 0)
        let end = try date(2026, 1, 1, 4, 0)
        XCTAssertEqual(schedule.latestMatchingRun(after: start, through: end, calendar: calendar()), end)
        XCTAssertEqual(schedule.matchingRuns(after: start, through: end).count, 64)
    }

    func testLiveClaimDoesNotExpireOnlyBecauseItIsOld() throws {
        let task = try makeTask(id: "long", concurrency: "skip")
        let lease = try TaskRunClaimManager.acquire(
            task: task,
            runID: "long-run",
            host: "test",
            now: Date().addingTimeInterval(-72 * 60 * 60)
        )
        defer { lease.release() }
        XCTAssertNotNil(TaskRunClaimManager.activeClaim(
            for: task,
            runID: "long-run",
            now: Date().addingTimeInterval(72 * 60 * 60)
        ))
        let claim = try XCTUnwrap(TaskRunClaimManager.activeClaim(for: task, runID: "long-run"))
        XCTAssertNotNil(claim.processIdentity)
        XCTAssertTrue(TaskRunClaimManager.canSafelySignal(claim))
    }

    func testLivePIDWithMismatchedBirthIdentityIsStale() throws {
        let task = try makeTask(id: "reused-pid", concurrency: "skip")
        let claimRoot = TaskRunClaimManager.claimDirectoryURL(for: task)
        let runRoot = claimRoot.appendingPathComponent("reused-run")
        try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
        let current = try XCTUnwrap(TaskRunClaimManager.processIdentity(for: getpid()))
        let reused = TaskRunClaim(
            schemaVersion: 1,
            runId: "reused-run",
            taskId: task.id,
            processID: getpid(),
            processGroupID: nil,
            processIdentity: TaskProcessIdentity(
                startTimeSeconds: current.startTimeSeconds + 1,
                startTimeMicroseconds: current.startTimeMicroseconds
            ),
            host: "old-process",
            startedAt: Date()
        )
        try TaskRunClaimManager.write(claim: reused, to: runRoot.appendingPathComponent("claim.json"))

        XCTAssertNil(TaskRunClaimManager.activeClaim(for: task, runID: "reused-run"))
        XCTAssertFalse(TaskRunClaimManager.canSafelySignal(reused))
    }

    func testStaleClaimReclamationKeepsReplacementClaim() throws {
        let task = try makeTask(id: "reclaim", concurrency: "skip")
        let claimRoot = TaskRunClaimManager.claimDirectoryURL(for: task)
        try FileManager.default.createDirectory(at: claimRoot, withIntermediateDirectories: true)
        try TaskRunClaimManager.write(
            claim: TaskRunClaim(
                schemaVersion: 1,
                runId: "stale",
                taskId: task.id,
                processID: Int32.max,
                processGroupID: nil,
                host: "dead",
                startedAt: Date().addingTimeInterval(-300)
            ),
            to: claimRoot.appendingPathComponent("claim.json")
        )
        let replacement = try TaskRunClaimManager.acquire(task: task, runID: "replacement", host: "test")
        defer { replacement.release() }
        XCTAssertThrowsError(try TaskRunClaimManager.acquire(task: task, runID: "competitor", host: "test"))
        XCTAssertEqual(TaskRunClaimManager.activeClaim(for: task)?.runId, "replacement")
    }

    func testAllowPolicyRunsTwoInstancesAndRetentionPreservesBoth() throws {
        let task = try makeTask(
            id: "allow",
            concurrency: "allow",
            script: "#!/bin/zsh\nsleep 30\n",
            maxRuns: 1
        )
        let firstCancellation = TaskRunCancellation()
        let secondCancellation = TaskRunCancellation()
        let firstFinished = expectation(description: "first run finishes")
        let secondFinished = expectation(description: "second run finishes")
        let lock = NSLock()
        var statuses: [TaskRunStatus] = []

        DispatchQueue.global().async {
            if let record = try? TaskRunner.run(
                task: task,
                trigger: .manual,
                runId: "one",
                cancellation: firstCancellation,
                terminationGraceSeconds: 0.1
            ) {
                lock.withLock { statuses.append(record.status) }
            }
            firstFinished.fulfill()
        }
        DispatchQueue.global().async {
            if let record = try? TaskRunner.run(
                task: task,
                trigger: .manual,
                runId: "two",
                cancellation: secondCancellation,
                terminationGraceSeconds: 0.1
            ) {
                lock.withLock { statuses.append(record.status) }
            }
            secondFinished.fulfill()
        }

        try waitUntil { TaskRunClaimManager.activeClaims(for: task).count == 2 }
        XCTAssertNotNil(TaskRunClaimManager.activeClaim(for: task, runID: "one"))
        XCTAssertNotNil(TaskRunClaimManager.activeClaim(for: task, runID: "two"))
        firstCancellation.cancel()
        wait(for: [firstFinished], timeout: 4)
        let runNames = try FileManager.default.contentsOfDirectory(
            at: task.directoryURL.appendingPathComponent("runs"),
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent)
        XCTAssertEqual(Set(runNames), ["one", "two"], "one run finishing must not retain-clean another active run")
        secondCancellation.cancel()
        wait(for: [secondFinished], timeout: 4)
        XCTAssertEqual(Set(lock.withLock { statuses }), [.cancelled])
    }

    func testSchedulerRunsDueTaskAndDeduplicatesMinute() throws {
        let fixture = try schedulerFixture(id: "due", concurrency: "skip")
        let now = try date(2026, 1, 2, 10, 0)
        try fixture.writeState(lastCheckAt: now.addingTimeInterval(-60))
        fixture.engine.tick(now: now)
        try waitUntil { self.records(in: fixture.taskURL).contains { $0.status == .success } }
        fixture.engine.tick(now: now)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(records(in: fixture.taskURL).count, 1)
        XCTAssertEqual(records(in: fixture.taskURL).first?.scheduledAt, now)
    }

    func testSchedulerHonorsSkipAndAllowClaims() throws {
        let now = try date(2026, 1, 2, 10, 0)
        let skip = try schedulerFixture(id: "skip", concurrency: "skip")
        let skipLease = try TaskRunClaimManager.acquire(task: skip.task, runID: "skip-existing", host: "test")
        defer { skipLease.release() }
        try skip.writeState(lastCheckAt: now.addingTimeInterval(-60))
        skip.engine.tick(now: now)
        try waitUntil { self.records(in: skip.taskURL).contains { $0.status == .skipped } }

        let allow = try schedulerFixture(id: "allow-scheduled", concurrency: "allow")
        let allowLease = try TaskRunClaimManager.acquire(task: allow.task, runID: "allow-existing", host: "test")
        defer { allowLease.release() }
        try allow.writeState(lastCheckAt: now.addingTimeInterval(-60))
        allow.engine.tick(now: now)
        try waitUntil { self.records(in: allow.taskURL).contains { $0.status == .success } }
        XCTAssertNotNil(TaskRunClaimManager.activeClaim(for: allow.task, runID: "allow-existing"))
    }

    func testRetentionRemovesOnlyOldUnclaimedOrphans() throws {
        let task = try makeTask(id: "retention-orphans", concurrency: "allow")
        let runsURL = task.directoryURL.appendingPathComponent("runs", isDirectory: true)
        let oldURL = runsURL.appendingPathComponent("old-orphan", isDirectory: true)
        let recentURL = runsURL.appendingPathComponent("recent-orphan", isDirectory: true)
        let claimedURL = runsURL.appendingPathComponent("claimed-orphan", isDirectory: true)
        for url in [oldURL, recentURL, claimedURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
        let now = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-600)],
            ofItemAtPath: oldURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-600)],
            ofItemAtPath: claimedURL.path
        )
        let lease = try TaskRunClaimManager.acquire(
            task: task,
            runID: "claimed-orphan",
            host: "test"
        )
        defer { lease.release() }

        RetentionCleaner.clean(
            taskDirectoryURL: task.directoryURL,
            policy: task.manifest.retention,
            now: now,
            orphanGracePeriod: 300
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: claimedURL.path))
    }

    private func makeTask(
        id: String,
        concurrency: String,
        script: String = "#!/bin/zsh\necho ok\n",
        maxRuns: Int = 500
    ) throws -> RunShelfTask {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("RunnerScheduler-\(UUID().uuidString)")
        let taskID = UUID(uuidString: id) == nil ? UUID().uuidString : id
        let root = container.appendingPathComponent(taskID, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("runs"), withIntermediateDirectories: true)
        roots.append(container)
        let manifest = TaskManifest(
            schemaVersion: 1,
            id: taskID,
            name: id,
            description: "",
            enabled: true,
            createdAt: Date(),
            updatedAt: Date(),
            schedule: TaskSchedule(type: "cron", expression: "* * * * *", timezone: "local"),
            runner: TaskRunnerPolicy(
                concurrency: concurrency,
                timeoutSeconds: 0,
                missedRunPolicy: MissedRunPolicy(type: "skipIfLate", maxDelaySeconds: 1_800)
            ),
            notifications: .defaultPolicy,
            retention: RetentionPolicy(days: 30, maxRuns: maxRuns)
        )
        let task = RunShelfTask(
            manifest: manifest,
            directoryURL: root,
            script: script,
            notes: "",
            runs: [],
            isDirty: false
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: root.appendingPathComponent("task.json"))
        try script.write(to: root.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)
        try "".write(to: root.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        return task
    }

    private func schedulerFixture(id: String, concurrency: String) throws -> Fixture {
        let taskID = UUID().uuidString
        var task = try makeTask(id: taskID, concurrency: concurrency)
        task.manifest.name = id
        let appSupport = task.directoryURL.deletingLastPathComponent().appendingPathComponent("support-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        roots.append(appSupport)
        let tasksURL = appSupport.appendingPathComponent("tasks")
        let taskURL = tasksURL.appendingPathComponent(taskID)
        try FileManager.default.createDirectory(at: taskURL.appendingPathComponent("runs"), withIntermediateDirectories: true)
        var storedTask = task
        storedTask.directoryURL = taskURL
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(storedTask.manifest).write(to: taskURL.appendingPathComponent("task.json"))
        try storedTask.script.write(to: taskURL.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)
        try "".write(to: taskURL.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        let stateURL = appSupport.appendingPathComponent("state.json")
        return Fixture(
            engine: SchedulerEngine(
                taskFileStore: TaskFileStore(tasksDirectoryURL: tasksURL),
                appSupportDirectoryURL: appSupport,
                stateURL: stateURL,
                heartbeatURL: appSupport.appendingPathComponent("heartbeat.json"),
                logURL: appSupport.appendingPathComponent("scheduler.log")
            ),
            task: storedTask,
            taskURL: taskURL,
            stateURL: stateURL
        )
    }

    private func records(in taskURL: URL) -> [RunRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: taskURL.appendingPathComponent("runs"),
            includingPropertiesForKeys: nil
        )) ?? []
        return urls.compactMap { try? decoder.decode(RunRecord.self, from: Data(contentsOf: $0.appendingPathComponent("meta.json"))) }
    }

    private func waitUntil(timeout: TimeInterval = 4, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.03)
        }
        throw CocoaError(.fileReadUnknown)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) throws -> Date {
        try XCTUnwrap(calendar().date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)))
    }

    private func calendar() -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = .current
        return value
    }
}

private struct Fixture {
    let engine: SchedulerEngine
    let task: RunShelfTask
    let taskURL: URL
    let stateURL: URL

    func writeState(lastCheckAt: Date) throws {
        let state = SchedulerState(schemaVersion: 1, lastCheckAt: lastCheckAt, lastScheduledMinuteByTaskID: [:])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: stateURL)
    }
}
