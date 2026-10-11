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

    func testDetachedBusyTaskUsesAlreadyRunningContract() throws {
        let create = try invokeApply([
            "slug": "busy-contract",
            "name": "Busy Contract",
            "timeoutSeconds": 0,
            "script": "#!/bin/zsh\nsleep 30\n"
        ])
        let taskID = try string(dictionary(result(create.json)["task"])["id"])
        let first = try invoke(["run", taskID, "--detach", "--json"])
        XCTAssertEqual(first.exitCode, 0)
        let runID = try string(result(first.json)["runId"])

        let second = try invoke(["run", taskID, "--detach", "--json"])
        try assertError(second, exitCode: 7, code: "already_running")

        let cancel = try invoke(["run", "cancel", runID, "--json"])
        XCTAssertEqual(cancel.exitCode, 0)
    }

    func testForegroundRunFailureReturnsErrorEnvelopeWithRunResult() throws {
        let create = try invokeApply([
            "slug": "failed-run",
            "name": "Failed Run",
            "script": "#!/bin/zsh\necho failure-output\nexit 42\n"
        ])
        let taskID = try string(dictionary(result(create.json)["task"])["id"])

        let run = try invoke(["run", taskID, "--json"])

        try assertError(run, exitCode: 8, code: "run_failed")
        let runResult = try dictionary(run.json["result"])
        XCTAssertEqual(runResult["taskId"] as? String, taskID)
        let record = try dictionary(runResult["run"])
        XCTAssertEqual(record["status"] as? String, "failed")
        XCTAssertEqual(record["exitCode"] as? Int, 42)
        XCTAssertNotNil(record["stdoutPath"] as? String)
        XCTAssertNotNil(record["stderrPath"] as? String)
    }

    func testUpdatingWithoutExpectedRevisionIsRejectedWithoutWriting() throws {
        let create = try invokeApply([
            "slug": "revision-required",
            "name": "Original Name",
            "script": "#!/bin/zsh\necho original\n"
        ])
        XCTAssertEqual(create.exitCode, 0)
        let taskID = try string(dictionary(result(create.json)["task"])["id"])

        let updateWithoutRevision = try invokeApply([
            "id": taskID,
            "name": "Overwritten Name",
            "script": "#!/bin/zsh\necho overwritten\n"
        ])

        try assertError(updateWithoutRevision, exitCode: 2, code: "usage")
        XCTAssertTrue(try errorMessage(updateWithoutRevision).contains("task show"))
        XCTAssertTrue(try errorMessage(updateWithoutRevision).contains("revisionToken"))
        let show = try invoke(["task", "show", taskID, "--json"])
        let showResult = try result(show.json)
        XCTAssertEqual(try dictionary(showResult["task"])["name"] as? String, "Original Name")
        XCTAssertTrue(try string(showResult["script"]).contains("original"))
    }

    func testValidationEdgesUseStableExitCodesAndMessages() throws {
        let negativeTimeout = try invokeApply([
            "slug": "negative-timeout",
            "name": "Negative Timeout",
            "timeoutSeconds": -1
        ])
        try assertError(negativeTimeout, exitCode: 4, code: "validation")

        for slug in ["status", "log", "cancel", "stop"] {
            let reserved = try invokeApply([
                "slug": slug,
                "name": "Reserved \(slug)"
            ])
            try assertError(reserved, exitCode: 4, code: "validation")
            XCTAssertTrue(try errorMessage(reserved).contains("保留字"))
        }

        let unsafeCancel = try invoke(["run", "cancel", "../claim", "--json"])
        try assertError(unsafeCancel, exitCode: 4, code: "validation")

        let create = try invokeApply([
            "slug": "ended-run",
            "name": "Ended Run",
            "script": "#!/bin/zsh\necho done\n"
        ])
        let taskID = try string(dictionary(result(create.json)["task"])["id"])
        let run = try invoke(["run", taskID, "--json"])
        let runID = try string(dictionary(result(run.json)["run"])["runId"])
        let cancelEnded = try invoke(["run", "cancel", runID, "--json"])
        try assertError(cancelEnded, exitCode: 3, code: "not_found")
        XCTAssertTrue(try errorMessage(cancelEnded).contains("run status"))
    }

    func testContractSelfDescriptionIncludesVersionHelpSchemasAndExample() throws {
        let help = try invoke([])
        XCTAssertEqual(help.exitCode, 0)
        let helpText = try XCTUnwrap(String(data: help.stdout, encoding: .utf8))
        XCTAssertTrue(helpText.hasPrefix("AI agent：先运行 runshelf help agent\n机器可读输出："))
        for command in [
            "task delete", "run stop", "--bytes <n>|--full", "schema cli-result",
            "schema task-spec [--example]", "version [--json]", "RUNSHELF_JSON"
        ] {
            XCTAssertTrue(helpText.contains(command), "help 缺少 \(command)")
        }

        let agentHelp = try invoke(["help", "agent"])
        let agentText = try XCTUnwrap(String(data: agentHelp.stdout, encoding: .utf8))
        for contract in ["task delete", "run log", "run stop", "schemaVersion", "run_failed", "doctor"] {
            XCTAssertTrue(agentText.contains(contract), "agent help 缺少 \(contract)")
        }

        let version = try invoke(["version", "--json"])
        XCTAssertEqual(version.exitCode, 0)
        XCTAssertEqual(try version.json["schemaVersion"] as? Int, 1)
        let versionResult = try result(version.json)
        XCTAssertFalse(try string(versionResult["appVersion"]).isEmpty)
        XCTAssertEqual(versionResult["envelopeSchemaVersion"] as? Int, 1)

        let list = try invoke(["task", "list", "--json"])
        XCTAssertEqual(try list.json["schemaVersion"] as? Int, 1)

        let resultSchema = try invoke(["schema", "cli-result"])
        let schema = try dictionary(JSONSerialization.jsonObject(with: resultSchema.stdout))
        let required = try XCTUnwrap(schema["required"] as? [String])
        XCTAssertTrue(required.contains("schemaVersion"))

        let example = try invoke(["schema", "task-spec", "--example"])
        let exampleJSON = try dictionary(JSONSerialization.jsonObject(with: example.stdout))
        XCTAssertEqual(exampleJSON["name"] as? String, "Example task")
        XCTAssertTrue(try string(exampleJSON["script"]).contains("echo hello"))
    }

    func testAgentSetupUsesHelpAgentAsSingleSourceOfTruth() throws {
        let setup = try invoke(["agent-setup"])
        let help = try invoke(["help", "agent"])

        XCTAssertEqual(setup.exitCode, 0)
        XCTAssertEqual(help.exitCode, 0)
        XCTAssertEqual(setup.stdout, help.stdout)
        let content = try XCTUnwrap(String(data: setup.stdout, encoding: .utf8))
        XCTAssertTrue(content.contains(executableURL.resolvingSymlinksInPath().path))
        XCTAssertTrue(content.contains("schema task-spec"))
        XCTAssertTrue(content.contains("## 最小 TaskSpec"))
        XCTAssertTrue(content.contains("## 退出码"))
        XCTAssertTrue(content.contains("--allow-dangerous"))
    }

    func testAgentSetupWriteIsIdempotentAndPreservesExistingContent() throws {
        let targetURL = rootURL.appendingPathComponent(".claude/CLAUDE.md")
        try FileManager.default.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let existing = "# Existing instructions\n\nKeep this text byte-for-byte.\n"
        try Data(existing.utf8).write(to: targetURL)

        let first = try invoke(["agent-setup", "--write", "claude", "--json"])
        XCTAssertEqual(first.exitCode, 0)
        XCTAssertEqual(try result(first.json)["changed"] as? Bool, true)
        XCTAssertEqual(try result(first.json)["path"] as? String, targetURL.path)
        let firstData = try Data(contentsOf: targetURL)
        let firstText = try XCTUnwrap(String(data: firstData, encoding: .utf8))
        XCTAssertTrue(firstText.hasPrefix(existing))
        XCTAssertEqual(firstText.components(separatedBy: RunShelfAgentGuide.beginMarker).count, 2)
        XCTAssertEqual(firstText.components(separatedBy: RunShelfAgentGuide.endMarker).count, 2)

        let second = try invoke(["agent-setup", "--write", "claude", "--json"])
        XCTAssertEqual(second.exitCode, 0)
        XCTAssertEqual(try result(second.json)["changed"] as? Bool, false)
        XCTAssertEqual(try Data(contentsOf: targetURL), firstData)

        let agentsURL = rootURL.appendingPathComponent("AGENTS.md")
        let agentsExisting = "# Workspace rules\n"
        try Data(agentsExisting.utf8).write(to: agentsURL)
        let agents = try invoke(
            ["agent-setup", "--write", "agents", "--json"],
            currentDirectoryURL: rootURL
        )
        XCTAssertEqual(agents.exitCode, 0)
        XCTAssertEqual(try result(agents.json)["changed"] as? Bool, true)
        XCTAssertTrue(try String(contentsOf: agentsURL, encoding: .utf8).hasPrefix(agentsExisting))
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

    func testCancelBeforeProcessGroupIsRecordedDoesNotSignalSupervisor() throws {
        let create = try invokeApply([
            "slug": "early-cancel",
            "name": "Early Cancel",
            "script": "#!/bin/zsh\necho early\n"
        ])
        let taskID = try string(dictionary(result(create.json)["task"])["id"])
        let taskURL = appSupportURL.appendingPathComponent("tasks/\(taskID)")
        let runID = "early-cancel-run"
        let runURL = taskURL.appendingPathComponent("runs/\(runID)")

        // 模拟监督进程（App / 调度宿主）：claim 已抢到、身份可验证，但脚本还没启动。
        let supervisor = Process()
        supervisor.executableURL = URL(fileURLWithPath: "/bin/sleep")
        supervisor.arguments = ["30"]
        try supervisor.run()
        defer {
            if supervisor.isRunning {
                supervisor.terminate()
                supervisor.waitUntilExit()
            }
        }
        let claimDirectoryURL = taskURL.appendingPathComponent(".run-claim/\(runID)")
        try FileManager.default.createDirectory(at: claimDirectoryURL, withIntermediateDirectories: true)
        let claim = TaskRunClaim(
            schemaVersion: 1,
            runId: runID,
            taskId: taskID,
            processID: supervisor.processIdentifier,
            processGroupID: nil,
            processIdentity: TaskRunClaimManager.processIdentity(for: supervisor.processIdentifier),
            host: "scheduler-launcher",
            startedAt: Date()
        )
        try TaskRunClaimManager.write(claim: claim, to: claimDirectoryURL.appendingPathComponent("claim.json"))

        let cancel = try invoke(["run", "cancel", runID, "--json"])

        XCTAssertEqual(cancel.exitCode, 0, String(data: cancel.stdout, encoding: .utf8) ?? "")
        let payload = try result(cancel.json)
        XCTAssertEqual(payload["signal"] as? Int, 0)
        XCTAssertNil(payload["processGroupID"] as? Int)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(supervisor.isRunning, "取消请求不应向监督进程发信号")
        XCTAssertTrue(FileManager.default.fileExists(atPath: runURL.appendingPathComponent("cancel-requested").path))
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
        let originInput = try invokeApply([
            "name": "Forged Origin",
            "origin": "app"
        ])
        try assertError(originInput, exitCode: 4, code: "validation")
        XCTAssertTrue(try errorMessage(originInput).contains("origin"))

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

    func testCLIOriginIsPersistedExposedAndPreservedAcrossUpdates() throws {
        let create = try invokeApply([
            "slug": "cli-origin",
            "name": "CLI Origin",
            "script": "#!/bin/zsh\necho origin\n"
        ])
        let createResult = try result(create.json)
        let createdTask = try dictionary(createResult["task"])
        XCTAssertEqual(createdTask["origin"] as? String, "cli")
        let taskID = try string(createdTask["id"])

        let manifestURL = appSupportURL.appendingPathComponent("tasks/\(taskID)/task.json")
        let manifest = try dictionary(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)))
        XCTAssertEqual(manifest["schemaVersion"] as? Int, 1)
        XCTAssertEqual(manifest["origin"] as? String, "cli")

        let list = try invoke(["task", "list", "--json"])
        let listedTasks = try XCTUnwrap(try list.json["result"] as? [[String: Any]])
        XCTAssertEqual(listedTasks.first?["origin"] as? String, "cli")

        let show = try invoke(["task", "show", taskID, "--json"])
        let showResult = try result(show.json)
        XCTAssertEqual(try dictionary(showResult["task"])["origin"] as? String, "cli")
        let revision = try string(showResult["revisionToken"])

        let update = try invokeApply([
            "id": taskID,
            "name": "CLI Origin Updated"
        ], extraArguments: ["--expected-revision", revision])
        XCTAssertEqual(try dictionary(result(update.json)["task"])["origin"] as? String, "cli")
        let updatedManifest = try dictionary(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)))
        XCTAssertEqual(updatedManifest["origin"] as? String, "cli")
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

    private func invoke(_ arguments: [String], currentDirectoryURL: URL? = nil) throws -> Invocation {
        let process = makeProcess(arguments: arguments)
        process.currentDirectoryURL = currentDirectoryURL
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
        environment["HOME"] = rootURL.path
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
