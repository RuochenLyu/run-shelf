import AppKit
import Combine
import Darwin
import Foundation
import XCTest

final class RunShelfCoreTests: XCTestCase {
    func testDurationUsesReadableMinuteAndSecondUnits() {
        XCTAssertEqual(RunShelfFormatters.duration(22_910), "22秒")
        XCTAssertEqual(RunShelfFormatters.duration(60_000), "1分")
        XCTAssertEqual(RunShelfFormatters.duration(1_954_270), "32分34秒")
        XCTAssertEqual(RunShelfFormatters.duration(3_661_000), "1时1分")
    }

    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        let fileManager = FileManager.default
        for url in temporaryDirectories {
            try? fileManager.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    @MainActor
    func testStableDiskRefreshDoesNotPublishStoreChanges() async throws {
        let root = try makeTemporaryDirectory()
        let tasksURL = root.appendingPathComponent("tasks", isDirectory: true)
        try FileManager.default.createDirectory(at: tasksURL, withIntermediateDirectories: true)
        try "seeded\n".write(
            to: tasksURL.appendingPathComponent(".examples-seeded"),
            atomically: true,
            encoding: .utf8
        )

        let store = TaskStore(tasksDirectoryURL: tasksURL, startsDiskMonitor: false)
        var task = try makeTask(
            root: tasksURL,
            id: "stable-scan",
            script: "#!/bin/zsh\necho stable\n",
            timeoutSeconds: 0
        )
        let run = RunRecord(
            runId: "stable-run",
            taskId: task.id,
            trigger: .manual,
            status: .success,
            exitCode: 0,
            scheduledAt: nil,
            startedAt: Date(),
            endedAt: Date(),
            durationMs: 1,
            scriptSha256: "hash",
            stdoutPath: "stdout.log",
            stderrPath: "stderr.log",
            message: nil
        )
        task.runs = [run]
        let stableResult = DiskScanResult(
            entries: [
                .fullReload(task, generation: 0),
                .runsOnly(taskID: task.id, runs: [run], generation: 0)
            ],
            deletedTaskIDs: [],
            newSignatures: [:],
            newRunsCache: [:],
            activities: [:],
            errors: []
        )

        store.applyDiskScan(stableResult)
        XCTAssertEqual(store.tasks, [task])

        var changeCount = 0
        let observation = store.objectWillChange.sink { changeCount += 1 }
        defer { observation.cancel() }

        store.applyDiskScan(stableResult)

        XCTAssertEqual(changeCount, 0, "Equal fullReload and runsOnly content must not invalidate the SwiftUI tree")
    }

    @MainActor
    func testLiveLogRefreshKeepsExistingContentVisibleAndSkipsIdenticalPublishes() async throws {
        let root = try makeTemporaryDirectory()
        let taskID = "00000000-0000-4000-8000-000000000099"
        let runID = "20260809T010203Z-live"
        let taskURL = root.appendingPathComponent(taskID, isDirectory: true)
        let runURL = taskURL
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
        try FileManager.default.createDirectory(at: runURL, withIntermediateDirectories: true)

        let stdoutURL = runURL.appendingPathComponent("stdout.log")
        let stderrURL = runURL.appendingPathComponent("stderr.log")
        try "first\n".write(to: stdoutURL, atomically: true, encoding: .utf8)
        try "".write(to: stderrURL, atomically: true, encoding: .utf8)

        let run = RunRecord(
            runId: runID,
            taskId: taskID,
            trigger: .manual,
            status: .running,
            exitCode: nil,
            scheduledAt: nil,
            startedAt: Date(),
            endedAt: nil,
            durationMs: nil,
            scriptSha256: "hash",
            stdoutPath: "stdout.log",
            stderrPath: "stderr.log",
            message: nil
        )
        let task = RunShelfTask(
            manifest: .create(id: taskID, name: "Log refresh", description: "", enabled: true),
            directoryURL: taskURL,
            script: "#!/bin/zsh\n",
            notes: "",
            runs: [run],
            isDirty: false
        )
        let loader = LogContentLoader()

        loader.load(task: task, run: run, force: true)
        XCTAssertFalse(loader.isLoading, "Fast local reads should not flash a loading placeholder")
        await loader.waitForCurrentLoad()
        XCTAssertFalse(loader.isLoading)
        XCTAssertEqual(loader.stdout.text, "first\n")

        var unchangedPublishCount = 0
        let observation = loader.objectWillChange.sink { unchangedPublishCount += 1 }
        loader.load(task: task, run: run, force: true)
        XCTAssertFalse(loader.isLoading, "Refreshing the same run must keep the log view visible")
        await loader.waitForCurrentLoad()
        XCTAssertEqual(unchangedPublishCount, 0, "Identical log content must not invalidate the view")

        try "first\nsecond\n".write(to: stdoutURL, atomically: true, encoding: .utf8)
        loader.load(task: task, run: run, force: true)
        XCTAssertFalse(loader.isLoading, "A live update must not replace the scroll view with a spinner")
        await loader.waitForCurrentLoad()
        XCTAssertEqual(loader.stdout.text, "first\nsecond\n")
        observation.cancel()

        let otherRunID = "20260809T010204Z-finished"
        let otherRunURL = taskURL
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(otherRunID, isDirectory: true)
        try FileManager.default.createDirectory(at: otherRunURL, withIntermediateDirectories: true)
        try "other\n".write(
            to: otherRunURL.appendingPathComponent("stdout.log"),
            atomically: true,
            encoding: .utf8
        )
        try "".write(
            to: otherRunURL.appendingPathComponent("stderr.log"),
            atomically: true,
            encoding: .utf8
        )
        var otherRun = run
        otherRun.runId = otherRunID
        otherRun.status = .success

        loader.load(task: task, run: otherRun)
        await loader.waitForCurrentLoad()
        XCTAssertEqual(loader.stdout.text, "other\n")

        loader.load(task: task, run: run)
        XCTAssertEqual(loader.stdout, .empty, "Running logs must be reread instead of served from cache")
        XCTAssertFalse(loader.isLoading)
        await loader.waitForCurrentLoad()
        XCTAssertEqual(loader.stdout.text, "first\nsecond\n")

        try "first\nsecond\nfinal\n".write(to: stdoutURL, atomically: true, encoding: .utf8)
        var completedRun = run
        completedRun.status = .success
        loader.load(task: task, run: completedRun)
        await loader.waitForCurrentLoad()
        XCTAssertEqual(loader.stdout.text, "first\nsecond\nfinal\n", "A completed run must receive one final read")
    }

    @MainActor
    func testLogLoaderClearsContentImmediatelyWhenSwitchingRuns() async throws {
        let root = try makeTemporaryDirectory()
        let taskID = UUID().uuidString
        let taskURL = root.appendingPathComponent(taskID, isDirectory: true)
        let runsURL = taskURL.appendingPathComponent("runs", isDirectory: true)
        try FileManager.default.createDirectory(at: runsURL, withIntermediateDirectories: true)
        var runs: [RunRecord] = []
        for (index, text) in ["first run\n", "second run\n"].enumerated() {
            let runID = "run-\(index)"
            let runURL = runsURL.appendingPathComponent(runID, isDirectory: true)
            try FileManager.default.createDirectory(at: runURL, withIntermediateDirectories: true)
            try text.write(to: runURL.appendingPathComponent("stdout.log"), atomically: true, encoding: .utf8)
            try "".write(to: runURL.appendingPathComponent("stderr.log"), atomically: true, encoding: .utf8)
            runs.append(RunRecord(
                runId: runID,
                taskId: taskID,
                trigger: .manual,
                status: .success,
                exitCode: 0,
                scheduledAt: nil,
                startedAt: Date().addingTimeInterval(TimeInterval(index)),
                endedAt: Date().addingTimeInterval(TimeInterval(index)),
                durationMs: 1,
                scriptSha256: "",
                stdoutPath: "stdout.log",
                stderrPath: "stderr.log",
                message: nil
            ))
        }
        let task = RunShelfTask(
            manifest: .create(id: taskID, name: "Switch logs", description: "", enabled: true),
            directoryURL: taskURL,
            script: "#!/bin/zsh\n",
            notes: "",
            runs: runs,
            isDirty: false
        )
        let loader = LogContentLoader()
        loader.load(task: task, run: runs[0])
        await loader.waitForCurrentLoad()
        XCTAssertEqual(loader.stdout.text, "first run\n")

        loader.load(task: task, run: runs[1])

        XCTAssertTrue(loader.isWaitingForContent)
        XCTAssertEqual(loader.stdout, .empty)
        XCTAssertEqual(loader.stderr, .empty)
        await loader.waitForCurrentLoad()
        XCTAssertEqual(loader.stdout.text, "second run\n")
    }

    @MainActor
    func testRunningLogContentIsNotCached() async throws {
        let root = try makeTemporaryDirectory()
        let taskID = UUID().uuidString
        let taskURL = root.appendingPathComponent(taskID, isDirectory: true)
        let runURL = taskURL.appendingPathComponent("runs/live", isDirectory: true)
        let finishedURL = taskURL.appendingPathComponent("runs/finished", isDirectory: true)
        try FileManager.default.createDirectory(at: runURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: finishedURL, withIntermediateDirectories: true)
        let liveStdoutURL = runURL.appendingPathComponent("stdout.log")
        try "first\n".write(to: liveStdoutURL, atomically: true, encoding: .utf8)
        try "".write(to: runURL.appendingPathComponent("stderr.log"), atomically: true, encoding: .utf8)
        try "finished\n".write(
            to: finishedURL.appendingPathComponent("stdout.log"),
            atomically: true,
            encoding: .utf8
        )
        try "".write(to: finishedURL.appendingPathComponent("stderr.log"), atomically: true, encoding: .utf8)
        let live = RunRecord(
            runId: "live",
            taskId: taskID,
            trigger: .manual,
            status: .running,
            exitCode: nil,
            scheduledAt: nil,
            startedAt: Date(),
            endedAt: nil,
            durationMs: nil,
            scriptSha256: "",
            stdoutPath: "stdout.log",
            stderrPath: "stderr.log",
            message: nil
        )
        var finished = live
        finished.runId = "finished"
        finished.status = .success
        finished.exitCode = 0
        finished.endedAt = Date()
        let task = RunShelfTask(
            manifest: .create(id: taskID, name: "Cache contract", description: "", enabled: true),
            directoryURL: taskURL,
            script: "#!/bin/zsh\n",
            notes: "",
            runs: [live, finished],
            isDirty: false
        )
        let loader = LogContentLoader()
        loader.load(task: task, run: live)
        await loader.waitForCurrentLoad()
        XCTAssertEqual(loader.stdout.text, "first\n")

        try "second\n".write(to: liveStdoutURL, atomically: true, encoding: .utf8)
        loader.load(task: task, run: finished)
        await loader.waitForCurrentLoad()
        loader.load(task: task, run: live)

        XCTAssertEqual(loader.stdout, .empty)
        await loader.waitForCurrentLoad()
        XCTAssertEqual(loader.stdout.text, "second\n")
    }

    @MainActor
    func testConcurrentManualRunsDoNotStarveLogLoading() async throws {
        let root = try makeTemporaryDirectory()
        let runCount = ProcessInfo.processInfo.activeProcessorCount + 1
        let coordinator = TaskRunCoordinator()
        let completions = expectation(description: "manual runs finish")
        completions.expectedFulfillmentCount = runCount
        var tasks: [RunShelfTask] = []

        for index in 0..<runCount {
            let task = try makeTask(
                root: root,
                id: "blocking-\(index)",
                script: "#!/bin/zsh\nsleep 30\n",
                timeoutSeconds: 0
            )
            tasks.append(task)
            coordinator.start(
                task: task,
                runID: "manual-\(index)",
                onStateChange: {},
                completion: { _ in completions.fulfill() }
            )
        }
        defer { tasks.forEach { coordinator.cancel(taskID: $0.id) } }

        let claimsDeadline = Date().addingTimeInterval(3)
        while Date() < claimsDeadline,
              tasks.contains(where: { TaskRunClaimManager.activeClaims(for: $0).isEmpty }) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(tasks.contains { TaskRunClaimManager.activeClaims(for: $0).isEmpty })

        let logTask = try makeTask(
            root: root,
            id: "log-reader",
            script: "#!/bin/zsh\n",
            timeoutSeconds: 0
        )
        let runID = "finished-log"
        let runURL = logTask.directoryURL.appendingPathComponent("runs/\(runID)", isDirectory: true)
        try FileManager.default.createDirectory(at: runURL, withIntermediateDirectories: true)
        try "log remains responsive\n".write(
            to: runURL.appendingPathComponent("stdout.log"),
            atomically: true,
            encoding: .utf8
        )
        try "".write(to: runURL.appendingPathComponent("stderr.log"), atomically: true, encoding: .utf8)
        let run = RunRecord(
            runId: runID,
            taskId: logTask.id,
            trigger: .manual,
            status: .success,
            exitCode: 0,
            scheduledAt: nil,
            startedAt: Date(),
            endedAt: Date(),
            durationMs: 1,
            scriptSha256: "",
            stdoutPath: "stdout.log",
            stderrPath: "stderr.log",
            message: nil
        )
        let loader = LogContentLoader()
        loader.load(task: logTask, run: run)

        let loaded = expectation(description: "log read completes while runners block")
        Task {
            await loader.waitForCurrentLoad()
            loaded.fulfill()
        }
        await fulfillment(of: [loaded], timeout: 2)
        XCTAssertEqual(loader.stdout.text, "log remains responsive\n")

        tasks.forEach { coordinator.cancel(taskID: $0.id) }
        await fulfillment(of: [completions], timeout: 10)
    }

    func testLogScrollStateDefersPendingOriginAndBoundsLRU() {
        var state = LogScrollState()
        for index in 0..<60 {
            state.record(origin: NSPoint(x: 0, y: CGFloat(index)), for: "run-\(index)")
        }

        XCTAssertEqual(state.origins.count, 50)
        XCTAssertNil(state.origins["run-0"])
        XCTAssertEqual(state.origins["run-59"]?.y, 59)

        XCTAssertEqual(state.beginRestore(for: "run-59").y, 59)
        state.record(origin: NSPoint(x: 0, y: 1), for: "run-59")
        XCTAssertEqual(state.origins["run-59"]?.y, 59)

        state.completeRestore(for: "run-59")
        state.record(origin: NSPoint(x: 0, y: 42), for: "run-59")
        XCTAssertEqual(state.origins["run-59"]?.y, 42)
    }

    func testCronUsesOrSemanticsWhenDayOfMonthAndWeekdayAreBothRestricted() throws {
        let schedule = try CronSchedule.parse("0 9 1 * 1")
        let firstOfMonth = try makeDate(year: 2026, month: 1, day: 1, hour: 9, minute: 0)
        let monday = try makeDate(year: 2026, month: 1, day: 5, hour: 9, minute: 0)
        let unrelatedDay = try makeDate(year: 2026, month: 1, day: 6, hour: 9, minute: 0)

        XCTAssertTrue(schedule.matches(firstOfMonth, calendar: gregorianCalendar()))
        XCTAssertTrue(schedule.matches(monday, calendar: gregorianCalendar()))
        XCTAssertFalse(schedule.matches(unrelatedDay, calendar: gregorianCalendar()))
    }

    func testTaskFileStoreLoadsValidTasksAndReportsBrokenDirectories() throws {
        let root = try makeTemporaryDirectory()
        try writeTaskDirectory(
            root: root,
            id: "00000000-0000-4000-8000-000000000001",
            name: "Valid",
            enabled: true,
            scheduleExpression: "*/15 * * * *",
            script: "#!/bin/zsh\necho ok\n"
        )

        let brokenURL = root.appendingPathComponent("broken-task", isDirectory: true)
        try FileManager.default.createDirectory(at: brokenURL, withIntermediateDirectories: true)
        try "{ broken".write(to: brokenURL.appendingPathComponent("task.json"), atomically: true, encoding: .utf8)
        try "#!/bin/zsh\n".write(to: brokenURL.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)

        let futureURL = root.appendingPathComponent("00000000-0000-4000-8000-000000000002", isDirectory: true)
        try writeTaskDirectory(
            root: root,
            id: "00000000-0000-4000-8000-000000000002",
            name: "Future",
            enabled: false,
            scheduleExpression: "0 9 * * *",
            script: "#!/bin/zsh\necho future\n",
            schemaVersion: 99
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: futureURL.path))

        let result = try TaskFileStore(tasksDirectoryURL: root).loadTasksWithIssues(includeRuns: false)

        XCTAssertEqual(result.tasks.map(\.manifest.name), ["Valid"])
        XCTAssertEqual(result.issues.count, 2)
        XCTAssertTrue(result.issues.contains { $0.directoryName == "broken-task" })
        XCTAssertTrue(result.issues.contains { $0.directoryName == "00000000-0000-4000-8000-000000000002" })
    }

    func testTaskRunnerTimeoutTerminatesChildProcessGroup() throws {
        let root = try makeTemporaryDirectory()
        let markerURL = root.appendingPathComponent("child-survived.txt")
        let pidURL = root.appendingPathComponent("child.pid")
        let script = """
        #!/bin/zsh
        set -euo pipefail
        (
          trap '' TERM HUP
          sleep 30
          echo survived > \(markerURL.path)
        ) &
        echo $! > \(pidURL.path)
        wait
        """
        // Full suites run process tests in parallel. Leave enough startup time for the shell
        // to persist its child PID before exercising timeout termination.
        let task = try makeTask(root: root, id: "timeout-task", script: script, timeoutSeconds: 3)

        let record = try TaskRunner.run(
            task: task,
            trigger: .manual,
            terminationGraceSeconds: 0.2
        )

        XCTAssertEqual(record.status, .timeout)
        XCTAssertEqual(record.message, "超过 3 秒未结束")
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))

        let childPID = try readPID(at: pidURL)
        XCTAssertFalse(isProcessAlive(childPID), "timeout should terminate the whole child process group")
    }

    func testTaskRunnerTimeoutUsesInjectedMonotonicClock() throws {
        let root = try makeTemporaryDirectory()
        let task = try makeTask(
            root: root,
            id: "monotonic-timeout-task",
            script: "#!/bin/zsh\nsleep 1.4\n",
            timeoutSeconds: 1
        )

        let record = try TaskRunner.run(
            task: task,
            trigger: .manual,
            monotonicNow: { 100 }
        )

        XCTAssertEqual(record.status, .success)
        XCTAssertNil(record.message)
        XCTAssertGreaterThanOrEqual(record.durationMs ?? 0, 1_000)
    }

    func testRunSnapshotReapsChildWhenProcessStartedCallbackThrows() throws {
        let root = try makeTemporaryDirectory()
        let snapshotURL = root.appendingPathComponent("throw-after-spawn.sh")
        let stdoutURL = root.appendingPathComponent("stdout.log")
        let stderrURL = root.appendingPathComponent("stderr.log")
        try "#!/bin/zsh\ntrap '' TERM\nsleep 30\n".write(
            to: snapshotURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: snapshotURL.path
        )
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }
        var spawnedPID: pid_t?

        XCTAssertThrowsError(try TaskRunner.runSnapshot(
            snapshotURL: snapshotURL,
            workingDirectoryURL: root,
            stdoutHandle: stdout,
            stderrHandle: stderr,
            timeoutSeconds: 0,
            cancellation: nil,
            externalCancellationURL: nil,
            terminationGraceSeconds: 0.1,
            monotonicNow: {
                TimeInterval(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
            },
            onProcessStarted: { pid in
                spawnedPID = pid
                throw CocoaError(.fileReadUnknown)
            }
        ))

        let pid = try XCTUnwrap(spawnedPID)
        XCTAssertFalse(isProcessAlive(pid), "throw path must reap the spawned child instead of leaving a zombie")
    }

    func testTaskRunnerCancellationWritesCancelledRun() throws {
        let root = try makeTemporaryDirectory()
        let task = try makeTask(
            root: root,
            id: "cancel-task",
            script: "#!/bin/zsh\nsleep 30\n",
            timeoutSeconds: 0
        )
        let cancellation = TaskRunCancellation()
        let finished = expectation(description: "run finishes after cancellation")
        let lock = NSLock()
        var result: Result<RunRecord, Error>?

        DispatchQueue.global(qos: .userInitiated).async {
            let runResult = Result {
                try TaskRunner.run(
                    task: task,
                    trigger: .manual,
                    cancellation: cancellation,
                    terminationGraceSeconds: 0.2
                )
            }
            lock.withLock {
                result = runResult
            }
            finished.fulfill()
        }

        Thread.sleep(forTimeInterval: 0.3)
        cancellation.cancel()
        wait(for: [finished], timeout: 3)

        let runResult = lock.withLock { result }
        let record = try XCTUnwrap(runResult?.get())
        XCTAssertEqual(record.status, .cancelled)
        XCTAssertEqual(record.message, "用户取消了运行")
    }

    func testTaskRunnerClaimBlocksSecondConcurrentRun() throws {
        let root = try makeTemporaryDirectory()
        let task = try makeTask(
            root: root,
            id: "claim-task",
            script: "#!/bin/zsh\nsleep 30\n",
            timeoutSeconds: 0
        )
        let cancellation = TaskRunCancellation()
        let finished = expectation(description: "first run finishes after cancellation")
        let lock = NSLock()
        var firstResult: Result<RunRecord, Error>?

        DispatchQueue.global(qos: .userInitiated).async {
            let runResult = Result {
                try TaskRunner.run(
                    task: task,
                    trigger: .manual,
                    cancellation: cancellation,
                    terminationGraceSeconds: 0.2
                )
            }
            lock.withLock {
                firstResult = runResult
            }
            finished.fulfill()
        }

        try waitForClaim(task: task)
        XCTAssertThrowsError(try TaskRunner.run(task: task, trigger: .manual)) { error in
            guard case TaskRunnerError.runAlreadyActive = error else {
                XCTFail("expected runAlreadyActive, got \(error)")
                return
            }
        }

        cancellation.cancel()
        wait(for: [finished], timeout: 3)
        let record = try XCTUnwrap(lock.withLock { firstResult }?.get())
        XCTAssertEqual(record.status, .cancelled)
        XCTAssertTrue(TaskRunClaimManager.activeClaims(for: task).isEmpty)
    }

    func testTaskRepositoryUpdatePreservesInternalRunnerPolicy() throws {
        let root = try makeTemporaryDirectory()
        let repository = TaskRepository(tasksDirectoryURL: root)
        let created = try repository.createTask(from: TaskSpec(
            slug: "agent-task",
            name: "Agent Task",
            enabled: true,
            script: "#!/bin/zsh\necho ok\n"
        ))

        var task = created.task
        task.manifest.runner.concurrency = "allow"
        try repository.writeTask(task, expectedRevision: created.revision)

        let updated = try repository.updateTask(
            selector: .slug("agent-task"),
            with: TaskSpec(name: "Agent Task Renamed")
        )

        XCTAssertEqual(updated.task.manifest.name, "Agent Task Renamed")
        XCTAssertEqual(updated.task.manifest.runner.concurrency, "allow")
        XCTAssertThrowsError(try repository.createTask(from: TaskSpec(
            slug: "agent-task",
            name: "Other Task",
            script: "#!/bin/zsh\necho other\n"
        )))
    }

    func testTaskRepositoryAppliesAndValidatesConcurrencyAndPriority() throws {
        let root = try makeTemporaryDirectory()
        let repository = TaskRepository(tasksDirectoryURL: root)
        let created = try repository.createTask(from: TaskSpec(
            slug: "queued-task",
            name: "Queued Task",
            concurrency: TaskConcurrency.queue,
            priority: TaskPriority.background,
            script: "#!/bin/zsh\necho ok\n"
        ))
        XCTAssertEqual(created.task.manifest.runner.concurrency, TaskConcurrency.queue)
        XCTAssertTrue(created.task.manifest.runner.runsInBackground)

        let updated = try repository.updateTask(
            selector: .slug("queued-task"),
            with: TaskSpec(priority: TaskPriority.standard)
        )
        XCTAssertEqual(updated.task.manifest.runner.concurrency, TaskConcurrency.queue)
        XCTAssertEqual(updated.task.manifest.runner.priority, TaskPriority.standard)

        XCTAssertThrowsError(try repository.updateTask(
            selector: .slug("queued-task"),
            with: TaskSpec(concurrency: "parallel")
        ))
        XCTAssertThrowsError(try repository.updateTask(
            selector: .slug("queued-task"),
            with: TaskSpec(priority: "low")
        ))
    }

    func testRunnerPolicyWithoutPriorityDecodesAsStandard() throws {
        let json = #"{"concurrency":"skip","timeoutSeconds":0,"missedRunPolicy":{"type":"skipIfLate","maxDelaySeconds":1800}}"#
        let policy = try JSONDecoder().decode(TaskRunnerPolicy.self, from: Data(json.utf8))
        XCTAssertEqual(policy.priority, TaskPriority.standard)
        XCTAssertFalse(policy.runsInBackground)
    }

    func testTaskRunnerExportsRunIdentityAndDeadline() throws {
        let root = try makeTemporaryDirectory()
        let script = """
        #!/bin/zsh
        print "task=$RUNSHELF_TASK_ID"
        print "run=$RUNSHELF_RUN_ID"
        print "deadline=${RUNSHELF_TIMEOUT_AT:-none}"
        """
        let task = try makeTask(root: root, id: "env-task", script: script, timeoutSeconds: 600)
        let before = Date()

        let record = try TaskRunner.run(task: task, trigger: .manual, runId: "env-run")

        XCTAssertEqual(record.status, .success)
        let output = try String(
            contentsOf: task.directoryURL.appendingPathComponent("runs/env-run/stdout.log"),
            encoding: .utf8
        )
        XCTAssertTrue(output.contains("task=\(task.id)\n"))
        XCTAssertTrue(output.contains("run=env-run\n"))
        let deadlineText = try XCTUnwrap(output.components(separatedBy: "\n")
            .first { $0.hasPrefix("deadline=") }?
            .dropFirst("deadline=".count))
        let deadline = try Date(String(deadlineText), strategy: .iso8601)
        XCTAssertEqual(deadline.timeIntervalSince(before), 600, accuracy: 5)

        let unlimited = try makeTask(root: root, id: "env-unlimited", script: script, timeoutSeconds: 0)
        _ = try TaskRunner.run(task: unlimited, trigger: .manual, runId: "env-unlimited-run")
        let unlimitedOutput = try String(
            contentsOf: unlimited.directoryURL.appendingPathComponent("runs/env-unlimited-run/stdout.log"),
            encoding: .utf8
        )
        XCTAssertTrue(unlimitedOutput.contains("deadline=none\n"))
    }

    func testBackgroundPriorityRunsBelowStandard() throws {
        let root = try makeTemporaryDirectory()
        let script = "#!/bin/zsh\nps -o pri= -p $$\n"
        var standard = try makeTask(root: root, id: "standard-priority", script: script, timeoutSeconds: 0)
        standard.manifest.runner.priority = TaskPriority.standard
        var background = try makeTask(root: root, id: "background-priority", script: script, timeoutSeconds: 0)
        background.manifest.runner.priority = TaskPriority.background

        // standard 继承测试进程的 QoS。GitHub macOS runner 把测试进程限制在 utility 及以下，
        // 两档在那里落到同一优先级，无从比较。
        let probe = Process()
        let probeOutput = Pipe()
        probe.executableURL = URL(fileURLWithPath: "/bin/zsh")
        probe.arguments = ["-c", "ps -o pri= -p $$; /usr/sbin/taskpolicy -c utility /bin/zsh -c 'ps -o pri= -p $$'"]
        probe.standardOutput = probeOutput
        try probe.run()
        probe.waitUntilExit()
        let probePriorities = String(decoding: probeOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(whereSeparator: \.isWhitespace)
            .compactMap { Int($0) }
        XCTAssertEqual(probePriorities.count, 2)
        try XCTSkipUnless(
            probePriorities.count == 2 && probePriorities[1] < probePriorities[0],
            "测试进程的 QoS 不高于 utility：\(probePriorities)"
        )

        _ = try TaskRunner.run(task: standard, trigger: .manual, runId: "standard")
        _ = try TaskRunner.run(task: background, trigger: .manual, runId: "background")

        func priority(of task: RunShelfTask, runID: String) throws -> Int {
            let text = try String(
                contentsOf: task.directoryURL.appendingPathComponent("runs/\(runID)/stdout.log"),
                encoding: .utf8
            )
            return try XCTUnwrap(Int(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        XCTAssertLessThan(
            try priority(of: background, runID: "background"),
            try priority(of: standard, runID: "standard")
        )
    }

    func testCLIInstallerSharesInstallAndStatusDetection() throws {
        let root = try makeTemporaryDirectory()
        let executableURL = root.appendingPathComponent("embedded/runshelf")
        try FileManager.default.createDirectory(
            at: executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("binary".utf8).write(to: executableURL)
        let prefixURL = root.appendingPathComponent("bin", isDirectory: true)
        let environment = ["HOME": root.path, "PATH": "/usr/bin:\(prefixURL.path)"]

        let before = RunShelfCLIInstaller.inspect(
            executableURL: executableURL,
            prefixURL: prefixURL,
            environment: environment
        )
        XCTAssertFalse(before.isInstalled)
        XCTAssertTrue(before.pathConfigured)

        let result = try RunShelfCLIInstaller.install(
            executableURL: executableURL,
            prefixURL: prefixURL,
            force: false,
            environment: environment
        )
        XCTAssertEqual(result.path, prefixURL.appendingPathComponent("runshelf").path)
        XCTAssertTrue(result.pathConfigured)

        let after = RunShelfCLIInstaller.inspect(
            executableURL: executableURL,
            prefixURL: prefixURL,
            environment: environment
        )
        XCTAssertTrue(after.isInstalled)
        XCTAssertEqual(after.target, executableURL.path)
    }

    @MainActor
    func testAppTaskOriginIsAssignedAndCannotBeRewritten() throws {
        let root = try makeTemporaryDirectory()
        let tasksURL = root.appendingPathComponent("tasks", isDirectory: true)
        try FileManager.default.createDirectory(at: tasksURL, withIntermediateDirectories: true)
        try Data("seeded\n".utf8).write(to: tasksURL.appendingPathComponent(".examples-seeded"))
        let store = TaskStore(tasksDirectoryURL: tasksURL, startsDiskMonitor: false)

        let taskID = try XCTUnwrap(store.createTask(from: TaskTemplate.examples[0], name: "App Origin"))
        XCTAssertEqual(store.task(withID: taskID)?.manifest.origin, .app)

        store.updateTask(id: taskID) { task in
            task.manifest.name = "App Origin Updated"
            task.manifest.origin = .cli
        }
        XCTAssertEqual(store.task(withID: taskID)?.manifest.origin, .app)
        XCTAssertTrue(store.saveTask(id: taskID))

        let reloaded = try TaskRepository(tasksDirectoryURL: tasksURL)
            .loadTask(selector: .id(taskID), includeRuns: false)
        XCTAssertEqual(reloaded.task.manifest.origin, .app)

        var forged = reloaded.task
        forged.manifest.origin = .cli
        try TaskRepository(tasksDirectoryURL: tasksURL)
            .writeTask(forged, expectedRevision: reloaded.revision)
        let preserved = try TaskRepository(tasksDirectoryURL: tasksURL)
            .loadTask(selector: .id(taskID), includeRuns: false)
        XCTAssertEqual(preserved.task.manifest.origin, .app)
    }

    func testTaskDefinitionRevisionTokenRoundTripsAndDetectsConflict() throws {
        let root = try makeTemporaryDirectory()
        let repository = TaskRepository(tasksDirectoryURL: root)
        let created = try repository.createTask(from: TaskSpec(
            slug: "revision-task",
            name: "Revision Task",
            script: "#!/bin/zsh\necho before\n"
        ))
        let decodedRevision = try TaskDefinitionRevision(token: created.revision.token)
        XCTAssertEqual(decodedRevision, created.revision)

        let updated = try repository.updateTask(
            selector: .slug("revision-task"),
            with: TaskSpec(description: "agent update"),
            expectedRevision: decodedRevision
        )
        XCTAssertEqual(updated.task.manifest.description, "agent update")

        Thread.sleep(forTimeInterval: 0.02)
        try "#!/bin/zsh\necho outside\n".write(
            to: updated.task.directoryURL.appendingPathComponent("run.sh"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertThrowsError(try repository.updateTask(
            selector: .slug("revision-task"),
            with: TaskSpec(notes: "stale write"),
            expectedRevision: updated.revision
        )) { error in
            guard case TaskRepositoryError.conflict = error else {
                XCTFail("expected conflict, got \(error)")
                return
            }
        }
    }

    func testTaskFileStoreMarksOrphanRunningRunStale() throws {
        let root = try makeTemporaryDirectory()
        try writeTaskDirectory(
            root: root,
            id: "00000000-0000-4000-8000-000000000003",
            name: "Orphan",
            enabled: true,
            scheduleExpression: "0 9 * * *",
            script: "#!/bin/zsh\necho orphan\n"
        )
        let taskDirectoryURL = root.appendingPathComponent("00000000-0000-4000-8000-000000000003", isDirectory: true)
        let runURL = taskDirectoryURL.appendingPathComponent("runs/orphan-run", isDirectory: true)
        try FileManager.default.createDirectory(at: runURL, withIntermediateDirectories: true)
        let startedAt = Date().addingTimeInterval(-60)
        let runningRecord = RunRecord(
            runId: "orphan-run",
            taskId: "00000000-0000-4000-8000-000000000003",
            trigger: .manual,
            status: .running,
            exitCode: nil,
            scheduledAt: nil,
            startedAt: startedAt,
            endedAt: nil,
            durationMs: nil,
            scriptSha256: "",
            stdoutPath: "stdout.log",
            stderrPath: "stderr.log",
            message: nil,
            processID: 123_456,
            processGroupID: nil
        )
        let metaURL = runURL.appendingPathComponent("meta.json")
        try writeRunRecord(runningRecord, to: metaURL)

        let task = try TaskFileStore(tasksDirectoryURL: root).loadTask(at: taskDirectoryURL, includeRuns: true)

        let record = try XCTUnwrap(task.runs.first)
        XCTAssertEqual(record.status, .stale)
        XCTAssertNotNil(record.endedAt)
        XCTAssertEqual(record.message, "运行宿主已不存在，本次运行已标记为 stale。")
        XCTAssertEqual(try decodeRunRecord(at: metaURL).status, .stale)
    }

    func testReconcileDoesNotOverwriteTerminalMetaFromStaleRunningInput() throws {
        let root = try makeTemporaryDirectory()
        let taskID = "00000000-0000-4000-8000-000000000013"
        try writeTaskDirectory(
            root: root,
            id: taskID,
            name: "Terminal",
            enabled: true,
            scheduleExpression: "0 9 * * *",
            script: "#!/bin/zsh\necho done\n"
        )
        let taskDirectoryURL = root.appendingPathComponent(taskID, isDirectory: true)
        let task = try TaskFileStore(tasksDirectoryURL: root).loadTask(at: taskDirectoryURL, includeRuns: false)
        let runURL = taskDirectoryURL.appendingPathComponent("runs/terminal-run", isDirectory: true)
        try FileManager.default.createDirectory(at: runURL, withIntermediateDirectories: true)
        let running = RunRecord(
            runId: "terminal-run",
            taskId: taskID,
            trigger: .manual,
            status: .running,
            exitCode: nil,
            scheduledAt: nil,
            startedAt: Date().addingTimeInterval(-1),
            endedAt: nil,
            durationMs: nil,
            scriptSha256: "",
            stdoutPath: "stdout.log",
            stderrPath: "stderr.log",
            message: nil
        )
        var terminal = running
        terminal.status = .success
        terminal.exitCode = 0
        terminal.endedAt = Date()
        terminal.durationMs = 1_000
        let metaURL = runURL.appendingPathComponent("meta.json")
        try writeRunRecord(terminal, to: metaURL)
        let store = TaskFileStore(tasksDirectoryURL: root)

        let reconciled = store.reconcileRunningRecord(running, metaURL: metaURL, claimTask: task)

        XCTAssertEqual(reconciled.status, .success)
        XCTAssertEqual(try decodeRunRecord(at: metaURL).status, .success)
    }

    func testSchedulerWritesStaleRecordForExpiredMissedRun() throws {
        let appSupportURL = try makeTemporaryDirectory()
        let tasksURL = appSupportURL.appendingPathComponent("tasks", isDirectory: true)
        let stateURL = appSupportURL.appendingPathComponent("scheduler-state.json")
        let heartbeatURL = appSupportURL.appendingPathComponent("scheduler-heartbeat.json")
        let logURL = appSupportURL.appendingPathComponent("scheduler.log")
        let now = try makeDate(year: 2026, month: 1, day: 2, hour: 10, minute: 0)
        let lastCheck = try makeDate(year: 2025, month: 12, day: 31, hour: 0, minute: 0)
        let scheduledAt = try makeDate(year: 2026, month: 1, day: 1, hour: 9, minute: 0)

        try writeTaskDirectory(
            root: tasksURL,
            id: "00000000-0000-4000-8000-000000000004",
            name: "Stale",
            enabled: true,
            scheduleExpression: "0 9 1 1 *",
            script: "#!/bin/zsh\necho should-not-run\n",
            maxDelaySeconds: 60
        )
        try writeSchedulerState(
            SchedulerState(
                schemaVersion: 1,
                lastCheckAt: lastCheck,
                lastScheduledMinuteByTaskID: [:]
            ),
            to: stateURL
        )

        let engine = SchedulerEngine(
            taskFileStore: TaskFileStore(tasksDirectoryURL: tasksURL),
            appSupportDirectoryURL: appSupportURL,
            stateURL: stateURL,
            heartbeatURL: heartbeatURL,
            logURL: logURL
        )

        engine.tick(now: now)
        let metaURL = try waitForFirstRunMeta(root: tasksURL.appendingPathComponent("00000000-0000-4000-8000-000000000004/runs"))
        let record = try decodeRunRecord(at: metaURL)

        XCTAssertEqual(record.status, .stale)
        XCTAssertEqual(record.scheduledAt, scheduledAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: heartbeatURL.path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunShelfTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func makeTask(root: URL, id: String, script: String, timeoutSeconds: Int) throws -> RunShelfTask {
        let taskID = UUID().uuidString
        let directoryURL = root.appendingPathComponent(taskID, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL.appendingPathComponent("runs", isDirectory: true), withIntermediateDirectories: true)
        let manifest = TaskManifest(
            schemaVersion: 1,
            id: taskID,
            name: id,
            description: "",
            enabled: true,
            createdAt: Date(),
            updatedAt: Date(),
            schedule: .defaultDaily,
            runner: TaskRunnerPolicy(
                concurrency: "skip",
                timeoutSeconds: timeoutSeconds,
                missedRunPolicy: .defaultPolicy
            ),
            notifications: .defaultPolicy,
            retention: .defaultPolicy
        )
        let task = RunShelfTask(
            manifest: manifest,
            directoryURL: directoryURL,
            script: script,
            notes: "",
            runs: [],
            isDirty: false
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: directoryURL.appendingPathComponent("task.json"))
        try script.write(to: directoryURL.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)
        try "".write(to: directoryURL.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        return task
    }

    private func writeTaskDirectory(
        root: URL,
        id: String,
        name: String,
        enabled: Bool,
        scheduleExpression: String,
        script: String,
        schemaVersion: Int = 1,
        maxDelaySeconds: Int = 1_800
    ) throws {
        let directoryURL = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL.appendingPathComponent("runs", isDirectory: true), withIntermediateDirectories: true)
        let manifest = TaskManifest(
            schemaVersion: schemaVersion,
            id: id,
            name: name,
            description: "",
            enabled: enabled,
            createdAt: Date(),
            updatedAt: Date(),
            schedule: TaskSchedule(type: "cron", expression: scheduleExpression, timezone: "local"),
            runner: TaskRunnerPolicy(
                concurrency: "skip",
                timeoutSeconds: 0,
                missedRunPolicy: MissedRunPolicy(type: "skipIfLate", maxDelaySeconds: maxDelaySeconds)
            ),
            notifications: .defaultPolicy,
            retention: .defaultPolicy
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: directoryURL.appendingPathComponent("task.json"), options: [.atomic])
        try script.write(to: directoryURL.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)
        try "".write(to: directoryURL.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
    }

    private func writeSchedulerState(_ state: SchedulerState, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: url, options: [.atomic])
    }

    private func waitForFirstRunMeta(root: URL) throws -> URL {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let metaURL = findFirstRunMeta(root: root) {
                return metaURL
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("timed out waiting for run meta under \(root.path)")
        throw CocoaError(.fileNoSuchFile)
    }

    private func waitForClaim(task: RunShelfTask) throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if !TaskRunClaimManager.activeClaims(for: task).isEmpty {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("timed out waiting for run claim under \(task.directoryURL.path)")
        throw CocoaError(.fileNoSuchFile)
    }

    private func findFirstRunMeta(root: URL) -> URL? {
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return nil
        }
        return directories
            .map { $0.appendingPathComponent("meta.json") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func decodeRunRecord(at url: URL) throws -> RunRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RunRecord.self, from: Data(contentsOf: url))
    }

    private func writeRunRecord(_ record: RunRecord, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: url, options: [.atomic])
    }

    private func readPID(at url: URL) throws -> pid_t {
        let text = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try XCTUnwrap(pid_t(text))
    }

    private func isProcessAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    private func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) throws -> Date {
        var components = DateComponents()
        components.calendar = gregorianCalendar()
        components.timeZone = .current
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = 0
        return try XCTUnwrap(components.date)
    }

    private func gregorianCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }
}
