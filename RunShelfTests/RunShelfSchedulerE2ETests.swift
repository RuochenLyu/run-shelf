import Darwin
import Foundation
import XCTest

/// 直接运行裸 RunShelfScheduler 可执行文件（与生产同样没有 .app bundle）。
final class RunShelfSchedulerE2ETests: XCTestCase {
    private var rootURL: URL!
    private var appSupportURL: URL!
    private var productsURL: URL!
    private var processes: [Process] = []
    private var detachedPIDs: [pid_t] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunShelfSchedulerE2E-\(UUID().uuidString)", isDirectory: true)
        appSupportURL = rootURL.appendingPathComponent("Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        productsURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        for name in ["runshelf", "RunShelfScheduler"] {
            XCTAssertTrue(
                FileManager.default.isExecutableFile(atPath: productsURL.appendingPathComponent(name).path),
                "RunShelfTests target 必须依赖 RunShelfCLI 和 RunShelfScheduler，缺少 \(name)"
            )
        }
    }

    override func tearDownWithError() throws {
        for process in processes where process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        processes = []
        // 运行宿主和脚本在独立 session 里，测试失败时不能留下孤儿。
        for pid in detachedPIDs {
            killpg(pid, SIGKILL)
            kill(pid, SIGKILL)
        }
        detachedPIDs = []
        try? FileManager.default.removeItem(at: rootURL)
        try super.tearDownWithError()
    }

    func testSchedulerSurvivesFailedRunAndQueuesNotificationForApp() throws {
        let taskID = try applyTask([
            "slug": "scheduler-failure",
            "name": "Scheduler Failure",
            "schedule": ["type": "cron", "expression": "* * * * *", "timezone": "local"],
            "script": "#!/bin/zsh\nexit 3\n"
        ])

        let scheduler = try launch("RunShelfScheduler", arguments: [])
        let outboxURL = appSupportURL.appendingPathComponent("notifications/outbox", isDirectory: true)

        let deadline = Date().addingTimeInterval(15)
        var queued: [String] = []
        while Date() < deadline {
            queued = ((try? FileManager.default.contentsOfDirectory(atPath: outboxURL.path)) ?? [])
                .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
            if !queued.isEmpty || !scheduler.isRunning { break }
            Thread.sleep(forTimeInterval: 0.1)
        }

        XCTAssertTrue(
            scheduler.isRunning,
            "scheduler exited (status \(scheduler.terminationStatus), reason \(scheduler.terminationReason.rawValue)) after a failed run"
        )
        XCTAssertEqual(queued.count, 1)
        XCTAssertTrue(queued.first?.hasPrefix("\(taskID)--") == true)

        // 再给一个 tick 窗口确认进程没有在通知路径后崩溃。
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(scheduler.isRunning)

        let runs = try FileManager.default.contentsOfDirectory(
            atPath: appSupportURL.appendingPathComponent("tasks/\(taskID)/runs").path
        )
        XCTAssertEqual(runs.count, 1)
        let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: appSupportURL
            .appendingPathComponent("tasks/\(taskID)/runs/\(runs[0])/meta.json"))) as? [String: Any]
        XCTAssertEqual(meta?["status"] as? String, "failed")
        XCTAssertEqual(meta?["exitCode"] as? Int, 3)
    }

    func testScheduledRunSurvivesSchedulerSIGKILLAndRecordsTrueTerminalStatus() throws {
        let markerURL = rootURL.appendingPathComponent("release-marker")
        let taskID = try applyTask([
            "slug": "scheduler-crash-survivor",
            "name": "Scheduler Crash Survivor",
            "schedule": ["type": "cron", "expression": "* * * * *", "timezone": "local"],
            "script": "#!/bin/zsh\necho started\nwhile [[ ! -e '\(markerURL.path)' ]]; do sleep 0.1; done\necho finished\nexit 0\n"
        ])

        let scheduler = try launch("RunShelfScheduler", arguments: [])
        let running = try waitForMeta(taskID: taskID, timeout: 15) { meta in
            meta["status"] as? String == "running" && meta["processGroupID"] is Int
        }
        let hostPID = try XCTUnwrap(running["processID"] as? Int)
        let scriptGroup = try XCTUnwrap(running["processGroupID"] as? Int)
        detachedPIDs += [pid_t(scriptGroup), pid_t(hostPID)]
        XCTAssertNotEqual(Int32(hostPID), scheduler.processIdentifier, "scheduled runs must be supervised by a detached host")

        // 模拟生产崩溃：调度进程直接死掉，不给任何清理机会。
        kill(scheduler.processIdentifier, SIGKILL)
        scheduler.waitUntilExit()
        XCTAssertEqual(scheduler.terminationReason, .uncaughtSignal)
        XCTAssertEqual(kill(pid_t(hostPID), 0), 0, "run host must outlive the scheduler")

        try Data().write(to: markerURL)
        let finished = try waitForMeta(taskID: taskID, timeout: 15) { meta in
            meta["status"] as? String != "running"
        }
        XCTAssertEqual(finished["status"] as? String, "success")
        XCTAssertEqual(finished["exitCode"] as? Int, 0)
        XCTAssertEqual(finished["trigger"] as? String, "scheduled")
        XCTAssertNotNil(finished["scheduledAt"])

        let claimRoot = appSupportURL.appendingPathComponent("tasks/\(taskID)/.run-claim")
        let claims = ((try? FileManager.default.contentsOfDirectory(atPath: claimRoot.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
        XCTAssertEqual(claims, [], "host must release its claim after recording the terminal status")
    }

    func testScheduledTimeoutIsEnforcedByHostAndQueuedOnce() throws {
        let taskID = try applyTask([
            "slug": "scheduler-timeout",
            "name": "Scheduler Timeout",
            "schedule": ["type": "cron", "expression": "* * * * *", "timezone": "local"],
            "timeoutSeconds": 1,
            "script": "#!/bin/zsh\nsleep 30\n"
        ])

        let scheduler = try launch("RunShelfScheduler", arguments: [])
        let finished = try waitForMeta(taskID: taskID, timeout: 20) { meta in
            meta["status"] as? String != nil && meta["status"] as? String != "running"
        }
        XCTAssertEqual(finished["status"] as? String, "timeout")
        XCTAssertTrue(scheduler.isRunning)

        let outboxURL = appSupportURL.appendingPathComponent("notifications/outbox", isDirectory: true)
        let queued = ((try? FileManager.default.contentsOfDirectory(atPath: outboxURL.path)) ?? [])
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
        XCTAssertEqual(queued, ["\(taskID)--\(try XCTUnwrap(finished["runId"] as? String)).json"])
    }

    // MARK: - Helpers

    private func waitForMeta(
        taskID: String,
        timeout: TimeInterval,
        until predicate: ([String: Any]) -> Bool
    ) throws -> [String: Any] {
        let runsURL = appSupportURL.appendingPathComponent("tasks/\(taskID)/runs", isDirectory: true)
        let deadline = Date().addingTimeInterval(timeout)
        var last: [String: Any] = [:]
        while Date() < deadline {
            let runs = ((try? FileManager.default.contentsOfDirectory(atPath: runsURL.path)) ?? []).sorted()
            if let runID = runs.last,
               let data = try? Data(contentsOf: runsURL.appendingPathComponent("\(runID)/meta.json")),
               let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                last = meta
                if predicate(meta) { return meta }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw NSError(
            domain: "RunShelfSchedulerE2ETests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "timed out waiting for run meta; last=\(last)"]
        )
    }

    private func applyTask(_ spec: [String: Any]) throws -> String {
        let specURL = rootURL.appendingPathComponent("\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: spec).write(to: specURL)
        let process = try launch("runshelf", arguments: ["apply", specURL.path, "--json"], captureStdout: true)
        let stdout = (process.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: stdout, as: UTF8.self))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: stdout) as? [String: Any])
        let result = try XCTUnwrap(json["result"] as? [String: Any])
        let task = try XCTUnwrap(result["task"] as? [String: Any])
        return try XCTUnwrap(task["id"] as? String)
    }

    @discardableResult
    private func launch(_ name: String, arguments: [String], captureStdout: Bool = false) throws -> Process {
        let process = Process()
        process.executableURL = productsURL.appendingPathComponent(name)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["RUN_SHELF_APP_SUPPORT_DIR"] = appSupportURL.path
        environment["HOME"] = rootURL.path
        process.environment = environment
        process.standardOutput = captureStdout ? Pipe() : FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        processes.append(process)
        return process
    }
}
