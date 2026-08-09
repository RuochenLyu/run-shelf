import Foundation
import XCTest

final class RunShelfCLIE2ETests: XCTestCase {
    private struct Invocation {
        var exitCode: Int32
        var stdout: Data
        var stderr: Data

        var json: [String: Any] {
            get throws {
                try XCTUnwrap(JSONSerialization.jsonObject(with: stdout) as? [String: Any])
            }
        }
    }

    private var rootURL: URL!
    private var appSupportURL: URL!
    private var executableURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunShelfCLIE2E-\(UUID().uuidString)", isDirectory: true)
        appSupportURL = rootURL.appendingPathComponent("Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        executableURL = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("runshelf")
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: executableURL.path),
            "RunShelfTests target 必须依赖 RunShelfCLI，预期可执行文件位于 \(executableURL.path)"
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootURL)
        try super.tearDownWithError()
    }

    func testJSONContractCreateUpdateConflictDangerousAndConcurrentCAS() throws {
        let create = try invokeApply([
            "slug": "cli-contract",
            "name": "CLI Contract",
            "script": "#!/bin/zsh\necho initial\n",
            "notes": "initial"
        ])
        XCTAssertEqual(create.exitCode, 0)
        XCTAssertEqual(try create.json["ok"] as? Bool, true)

        let createResult = try result(create.json)
        let createdTask = try dictionary(createResult["task"])
        let taskID = try XCTUnwrap(createdTask["id"] as? String)
        XCTAssertNotNil(UUID(uuidString: taskID))

        let show = try invoke(["task", "show", taskID, "--json"])
        XCTAssertEqual(show.exitCode, 0)
        let revision = try string(result(show.json)["revisionToken"])

        let update = try invokeApply([
            "id": taskID,
            "name": "CLI Contract Updated",
            "script": "#!/bin/zsh\necho updated\n",
            "notes": "updated"
        ], extraArguments: ["--expected-revision", revision])
        XCTAssertEqual(update.exitCode, 0)

        let stale = try invokeApply([
            "id": taskID,
            "description": "stale update"
        ], extraArguments: ["--expected-revision", revision])
        try assertError(stale, exitCode: 5, code: "conflict")

        let dangerous = try invokeApply([
            "slug": "dangerous-contract",
            "name": "Dangerous Contract",
            "script": "#!/bin/zsh\nrm -rf /tmp/runshelf-contract-target\n"
        ])
        try assertError(dangerous, exitCode: 6, code: "dangerous_command")

        let currentShow = try invoke(["task", "show", taskID, "--json"])
        let currentRevision = try string(result(currentShow.json)["revisionToken"])
        let firstSpec = try writeSpec([
            "id": taskID,
            "name": "CAS Winner A",
            "script": "#!/bin/zsh\necho winner-a\n",
            "notes": "winner-a"
        ])
        let secondSpec = try writeSpec([
            "id": taskID,
            "name": "CAS Winner B",
            "script": "#!/bin/zsh\necho winner-b\n",
            "notes": "winner-b"
        ])
        let invocations = try invokeConcurrently([
            ["apply", firstSpec.path, "--expected-revision", currentRevision, "--json"],
            ["apply", secondSpec.path, "--expected-revision", currentRevision, "--json"]
        ])
        XCTAssertEqual(invocations.map(\.exitCode).sorted(), [0, 5])

        let finalShow = try invoke(["task", "show", taskID, "--json"])
        let finalResult = try result(finalShow.json)
        let finalTask = try dictionary(finalResult["task"])
        let finalName = try string(finalTask["name"])
        let finalScript = try string(finalResult["script"])
        let finalNotes = try string(finalResult["notes"])
        if finalName == "CAS Winner A" {
            XCTAssertTrue(finalScript.contains("winner-a"))
            XCTAssertEqual(finalNotes, "winner-a")
        } else {
            XCTAssertEqual(finalName, "CAS Winner B")
            XCTAssertTrue(finalScript.contains("winner-b"))
            XCTAssertEqual(finalNotes, "winner-b")
        }
    }

    func testDetachedStatusCancelAndDeleteRunningContract() throws {
        let create = try invokeApply([
            "slug": "detached-contract",
            "name": "Detached Contract",
            "timeoutSeconds": 0,
            "script": "#!/bin/zsh\nsleep 30\n"
        ])
        let task = try dictionary(result(create.json)["task"])
        let taskID = try string(task["id"])

        let detached = try invoke(["run", taskID, "--detach", "--json"])
        XCTAssertEqual(detached.exitCode, 0)
        let runID = try string(result(detached.json)["runId"])

        let status = try invoke(["run", "status", runID, "--json"])
        XCTAssertEqual(status.exitCode, 0)
        XCTAssertEqual(try status.json["ok"] as? Bool, true)

        let deleteRunning = try invoke(["task", "delete", taskID, "--json"])
        try assertError(deleteRunning, exitCode: 7, code: "already_running")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: appSupportURL.appendingPathComponent("tasks/\(taskID)/task.json").path
        ))

        let cancel = try invoke(["run", "cancel", runID, "--json"])
        XCTAssertEqual(cancel.exitCode, 0)

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let current = try invoke(["run", "status", runID, "--json"])
            if current.exitCode == 0,
               let run = try result(current.json)["run"] as? [String: Any],
               let status = run["status"] as? String,
               status != "running" {
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: appSupportURL.appendingPathComponent("tasks/\(taskID)/task.json").path
        ))
    }

    func testLegacyClaimCancelDoesNotSignalUnverifiedProcess() throws {
        let create = try invokeApply([
            "slug": "legacy-claim",
            "name": "Legacy Claim",
            "script": "#!/bin/zsh\necho legacy\n"
        ])
        let taskPayload = try dictionary(result(create.json)["task"])
        let taskID = try string(taskPayload["id"])
        let taskURL = appSupportURL.appendingPathComponent("tasks/\(taskID)")
        let claimRoot = taskURL.appendingPathComponent(".run-claim")
        let runID = "legacy-run"
        let runURL = taskURL.appendingPathComponent("runs/\(runID)")
        try FileManager.default.createDirectory(at: claimRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runURL, withIntermediateDirectories: true)
        let legacyClaim = TaskRunClaim(
            schemaVersion: 1,
            runId: runID,
            taskId: taskID,
            processID: getpid(),
            processGroupID: nil,
            host: "legacy",
            startedAt: Date()
        )
        try TaskRunClaimManager.write(
            claim: legacyClaim,
            to: claimRoot.appendingPathComponent("claim.json")
        )

        let cancel = try invoke(["run", "cancel", runID, "--json"])

        try assertError(cancel, exitCode: 5, code: "conflict")
        XCTAssertTrue(FileManager.default.fileExists(atPath: runURL.appendingPathComponent("cancel-requested").path))
        XCTAssertEqual(kill(getpid(), 0), 0)
    }

    func testInstallCLIForceRejectsDirectory() throws {
        let prefixURL = rootURL.appendingPathComponent("bin", isDirectory: true)
        let destinationURL = prefixURL.appendingPathComponent("runshelf", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        try "keep".write(
            to: destinationURL.appendingPathComponent("sentinel"),
            atomically: true,
            encoding: .utf8
        )

        let invocation = try invoke([
            "install-cli", "--prefix", prefixURL.path, "--force", "--json"
        ])
        try assertError(invocation, exitCode: 5, code: "conflict")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.appendingPathComponent("sentinel").path))
    }

    func testTaskSpecRejectsUnknownFieldsAndUnsupportedTimezone() throws {
        let unknownRoot = try invokeApply([
            "name": "Unknown Root",
            "enable": true
        ])
        try assertError(unknownRoot, exitCode: 4, code: "validation")
        XCTAssertTrue(try errorMessage(unknownRoot).contains("enable"))

        let unknownSchedule = try invokeApply([
            "name": "Unknown Schedule",
            "schedule": [
                "type": "cron",
                "expression": "0 9 * * *",
                "timezone": "local",
                "zone": "local"
            ]
        ])
        try assertError(unknownSchedule, exitCode: 4, code: "validation")
        XCTAssertTrue(try errorMessage(unknownSchedule).contains("zone"))

        let unsupportedTimezone = try invokeApply([
            "name": "UTC Task",
            "schedule": [
                "type": "cron",
                "expression": "0 9 * * *",
                "timezone": "UTC"
            ]
        ])
        try assertError(unsupportedTimezone, exitCode: 4, code: "validation")

        let valid = try invokeApply([
            "name": "Local Task",
            "schedule": [
                "type": "cron",
                "expression": "0 9 * * *",
                "timezone": "local"
            ]
        ])
        XCTAssertEqual(valid.exitCode, 0)
    }

    func testLogDefaultsToBoundedTailAndFullIsExplicit() throws {
        let create = try invokeApply([
            "name": "Large Log",
            "script": "#!/bin/zsh\n/usr/bin/yes x | /usr/bin/head -c 1100000\n"
        ])
        let task = try dictionary(result(create.json)["task"])
        let taskID = try string(task["id"])
        let run = try invoke(["run", taskID, "--json"])
        XCTAssertEqual(run.exitCode, 0)
        let runRecord = try dictionary(result(run.json)["run"])
        let runID = try string(runRecord["runId"])

        let bounded = try invoke(["run", "log", runID, "--bytes", "128", "--json"])
        let boundedResult = try result(bounded.json)
        XCTAssertEqual(boundedResult["truncated"] as? Bool, true)
        XCTAssertEqual(boundedResult["returnedBytes"] as? Int, 128)
        XCTAssertEqual(boundedResult["totalBytes"] as? Int, 1_100_000)

        let full = try invoke(["run", "log", runID, "--stderr", "--full", "--json"])
        let fullResult = try result(full.json)
        XCTAssertEqual(fullResult["truncated"] as? Bool, false)
        XCTAssertEqual(fullResult["returnedBytes"] as? Int, 0)
    }

    func testUnknownArgumentsAreRejectedBeforeSideEffectsAndStdoutIsExplicit() throws {
        let typoSpec = try writeSpec([
            "slug": "typo-apply",
            "name": "Typo Apply",
            "script": "#!/bin/zsh\necho should-not-exist\n"
        ])
        let typoApply = try invoke(["apply", typoSpec.path, "--dryrun", "--json"])
        try assertError(typoApply, exitCode: 2, code: "usage")
        let listAfterTypo = try invoke(["task", "list", "--json"])
        XCTAssertTrue(try XCTUnwrap(listAfterTypo.json["result"] as? [[String: Any]]).isEmpty)

        let create = try invokeApply([
            "slug": "typo-run",
            "name": "Typo Run",
            "script": "#!/bin/zsh\necho stdout-marker\necho stderr-marker >&2\n"
        ])
        let taskID = try string(dictionary(result(create.json)["task"])["id"])
        let typoRun = try invoke(["run", taskID, "--detech", "--json"])
        try assertError(typoRun, exitCode: 2, code: "usage")
        let runsURL = appSupportURL.appendingPathComponent("tasks/\(taskID)/runs", isDirectory: true)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: runsURL.path).isEmpty)

        let run = try invoke(["run", taskID, "--json"])
        XCTAssertEqual(run.exitCode, 0)
        let runID = try string(dictionary(result(run.json)["run"])["runId"])
        let stdout = try invoke(["run", "log", runID, "--stdout", "--json"])
        XCTAssertEqual(stdout.exitCode, 0)
        let stdoutResult = try result(stdout.json)
        XCTAssertEqual(stdoutResult["stream"] as? String, "stdout")
        XCTAssertTrue(try string(stdoutResult["text"]).contains("stdout-marker"))
        XCTAssertFalse(try string(stdoutResult["text"]).contains("stderr-marker"))
    }

    func testLoaderRejectsNonUUIDAndManifestDirectoryMismatch() throws {
        let tasksURL = appSupportURL.appendingPathComponent("tasks", isDirectory: true)
        try FileManager.default.createDirectory(at: tasksURL, withIntermediateDirectories: true)
        let repository = TaskRepository(tasksDirectoryURL: tasksURL)
        let created = try repository.createTask(from: TaskSpec(name: "Identity Contract"))
        let mismatchedID = UUID().uuidString
        let mismatchedURL = created.task.directoryURL
            .deletingLastPathComponent()
            .appendingPathComponent(mismatchedID, isDirectory: true)
        try FileManager.default.moveItem(at: created.task.directoryURL, to: mismatchedURL)

        XCTAssertThrowsError(try TaskFileStore(
            tasksDirectoryURL: mismatchedURL.deletingLastPathComponent()
        ).loadTask(at: mismatchedURL, includeRuns: false)) { error in
            guard case TaskRepositoryError.taskIdentityMismatch = error else {
                XCTFail("expected taskIdentityMismatch, got \(error)")
                return
            }
        }
    }

    @MainActor
    func testTaskStoreRejectsDeleteWhenExternalClaimIsActive() throws {
        let tasksURL = appSupportURL.appendingPathComponent("tasks", isDirectory: true)
        try FileManager.default.createDirectory(at: tasksURL, withIntermediateDirectories: true)
        let repository = TaskRepository(tasksDirectoryURL: tasksURL)
        let created = try repository.createTask(from: TaskSpec(
            slug: "external-claim",
            name: "External Claim",
            script: "#!/bin/zsh\nsleep 30\n"
        ))
        let lease = try TaskRunClaimManager.acquire(
            task: created.task,
            runID: "external-run",
            host: "test-external"
        )
        defer { lease.release() }

        let store = TaskStore(tasksDirectoryURL: tasksURL)
        store.deleteTask(id: created.task.id)

        XCTAssertEqual(store.lastErrorMessage, "运行中的任务不能删除。")
        XCTAssertTrue(store.tasks.contains { $0.id == created.task.id })
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.task.directoryURL.path))
    }

    private func invokeApply(
        _ spec: [String: Any],
        extraArguments: [String] = []
    ) throws -> Invocation {
        let specURL = try writeSpec(spec)
        return try invoke(["apply", specURL.path] + extraArguments + ["--json"])
    }

    private func writeSpec(_ spec: [String: Any]) throws -> URL {
        let url = rootURL.appendingPathComponent("spec-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: spec, options: [.sortedKeys]).write(to: url)
        return url
    }

    private func invoke(_ arguments: [String]) throws -> Invocation {
        let process = makeProcess(arguments: arguments)
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return Invocation(
            exitCode: process.terminationStatus,
            stdout: stdout.fileHandleForReading.readDataToEndOfFile(),
            stderr: stderr.fileHandleForReading.readDataToEndOfFile()
        )
    }

    private func invokeConcurrently(_ argumentSets: [[String]]) throws -> [Invocation] {
        let processes = argumentSets.map(makeProcess(arguments:))
        let pipes = processes.map { _ in (Pipe(), Pipe()) }
        for (index, process) in processes.enumerated() {
            process.standardOutput = pipes[index].0
            process.standardError = pipes[index].1
        }
        for process in processes { try process.run() }
        for process in processes { process.waitUntilExit() }
        return processes.enumerated().map { index, process in
            Invocation(
                exitCode: process.terminationStatus,
                stdout: pipes[index].0.fileHandleForReading.readDataToEndOfFile(),
                stderr: pipes[index].1.fileHandleForReading.readDataToEndOfFile()
            )
        }
    }

    private func makeProcess(arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["RUN_SHELF_APP_SUPPORT_DIR"] = appSupportURL.path
        process.environment = environment
        return process
    }

    private func result(_ json: [String: Any]) throws -> [String: Any] {
        XCTAssertEqual(json["ok"] as? Bool, true)
        return try dictionary(json["result"])
    }

    private func dictionary(_ value: Any?) throws -> [String: Any] {
        try XCTUnwrap(value as? [String: Any])
    }

    private func string(_ value: Any?) throws -> String {
        try XCTUnwrap(value as? String)
    }

    private func assertError(
        _ invocation: Invocation,
        exitCode: Int32,
        code: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(invocation.exitCode, exitCode, file: file, line: line)
        let json = try invocation.json
        XCTAssertEqual(json["ok"] as? Bool, false, file: file, line: line)
        let error = try dictionary(json["error"])
        XCTAssertEqual(error["code"] as? String, code, file: file, line: line)
    }

    private func errorMessage(_ invocation: Invocation) throws -> String {
        let error = try dictionary(invocation.json["error"])
        return try string(error["message"])
    }
}
