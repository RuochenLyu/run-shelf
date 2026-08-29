import Foundation
import XCTest

final class DiskScannerTests: XCTestCase {
    func testStableRunsSignatureSkipsHistoryReloadUntilFallbackInterval() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let task = try writeTask(root: root, id: "disk-scan-cache")
        let loadedAt = Date()
        let input = makeInput(task: task, loadedAt: loadedAt, now: loadedAt.addingTimeInterval(15))

        let stableResult = DiskScanner.scan(input)
        XCTAssertTrue(stableResult.entries.isEmpty)
        XCTAssertTrue(stableResult.newRunsCache.isEmpty)

        let fallbackInput = makeInput(task: task, loadedAt: loadedAt, now: loadedAt.addingTimeInterval(301))
        let fallbackResult = DiskScanner.scan(fallbackInput)
        guard case let .runsOnly(taskID, runs, _) = try XCTUnwrap(fallbackResult.entries.first) else {
            return XCTFail("expected fallback runs reload")
        }
        XCTAssertEqual(taskID, task.id)
        XCTAssertTrue(runs.isEmpty)
    }

    func testRunsDirectoryChangeTriggersHistoryReload() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let task = try writeTask(root: root, id: "disk-scan-change")
        let loadedAt = Date()
        let cachedInput = makeInput(task: task, loadedAt: loadedAt, now: loadedAt.addingTimeInterval(15))

        let run = RunRecord(
            runId: "20260711T120000Z-new-run",
            taskId: task.id,
            trigger: .manual,
            status: .success,
            exitCode: 0,
            scheduledAt: nil,
            startedAt: loadedAt,
            endedAt: loadedAt,
            durationMs: 1,
            scriptSha256: "hash",
            stdoutPath: "stdout.log",
            stderrPath: "stderr.log",
            message: nil
        )
        let runURL = task.directoryURL
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(run.runId, isDirectory: true)
        try FileManager.default.createDirectory(at: runURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(run).write(to: runURL.appendingPathComponent("meta.json"), options: [.atomic])

        let result = DiskScanner.scan(cachedInput)
        guard case let .runsOnly(taskID, runs, _) = try XCTUnwrap(result.entries.first) else {
            return XCTFail("expected changed runs reload")
        }
        XCTAssertEqual(taskID, task.id)
        XCTAssertEqual(runs.map(\.runId), [run.runId])
    }

    func testScanProjectsExternalClaimActivity() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = try writeTask(root: root, id: UUID().uuidString)
        let lease = try TaskRunClaimManager.acquire(
            task: task,
            runID: "external-run",
            host: "scheduler"
        )
        defer { lease.release() }
        let loadedAt = Date()
        let input = DiskScanInput(
            tasksDirectoryURL: root,
            knownTasks: [.init(
                id: task.id,
                directoryURL: task.directoryURL,
                isDirty: false,
                generation: 0,
                runningRunIDs: [],
                task: task
            )],
            signatureCache: [task.id: TaskFileSignature.capture(for: task.directoryURL)],
            runsCache: [task.id: TaskRunsCache.capture(for: task, at: loadedAt)],
            now: loadedAt
        )

        let result = DiskScanner.scan(input)
        XCTAssertEqual(result.activities[task.id]?.runIDs, ["external-run"])
        XCTAssertEqual(result.activities[task.id]?.hosts, ["scheduler"])
    }

    func testClaimedRunAppearsWhenMetaArrivesAfterRunsDirectoryWasScanned() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = try writeTask(root: root, id: UUID().uuidString)
        let loadedAt = Date()
        let initialInput = makeInput(task: task, loadedAt: loadedAt, now: loadedAt.addingTimeInterval(1))
        let runID = "manual-run"
        let lease = try TaskRunClaimManager.acquire(
            task: task,
            runID: runID,
            host: "app",
            now: loadedAt.addingTimeInterval(1)
        )
        defer { lease.release() }

        let runURL = task.directoryURL
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
        try FileManager.default.createDirectory(at: runURL, withIntermediateDirectories: true)

        let scanBeforeMeta = DiskScanner.scan(initialInput)
        guard case let .runsOnly(_, runsBeforeMeta, _) = try XCTUnwrap(scanBeforeMeta.entries.first) else {
            return XCTFail("expected claim change to reload runs")
        }
        XCTAssertTrue(runsBeforeMeta.isEmpty)

        let running = RunRecord(
            runId: runID,
            taskId: task.id,
            trigger: .manual,
            status: .running,
            exitCode: nil,
            scheduledAt: nil,
            startedAt: loadedAt.addingTimeInterval(1),
            endedAt: nil,
            durationMs: nil,
            scriptSha256: "hash",
            stdoutPath: "stdout.log",
            stderrPath: "stderr.log",
            message: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(running).write(to: runURL.appendingPathComponent("meta.json"), options: [.atomic])

        let scanAfterMeta = DiskScanner.scan(DiskScanInput(
            tasksDirectoryURL: root,
            knownTasks: [.init(
                id: task.id,
                directoryURL: task.directoryURL,
                isDirty: false,
                generation: 0,
                runningRunIDs: [],
                task: task
            )],
            signatureCache: [task.id: TaskFileSignature.capture(for: task.directoryURL)],
            runsCache: scanBeforeMeta.newRunsCache,
            now: loadedAt.addingTimeInterval(2)
        ))

        guard case let .runsOnly(_, runsAfterMeta, _) = try XCTUnwrap(scanAfterMeta.entries.first) else {
            return XCTFail("expected new meta to reload runs")
        }
        XCTAssertEqual(runsAfterMeta.map(\.runId), [runID])
        XCTAssertEqual(runsAfterMeta.first?.status, .running)
    }

    private func makeInput(task: RunShelfTask, loadedAt: Date, now: Date) -> DiskScanInput {
        DiskScanInput(
            tasksDirectoryURL: task.directoryURL.deletingLastPathComponent(),
            knownTasks: [DiskScanInput.KnownTask(
                id: task.id,
                directoryURL: task.directoryURL,
                isDirty: false,
                generation: 0,
                runningRunIDs: []
            )],
            signatureCache: [task.id: TaskFileSignature.capture(for: task.directoryURL)],
            runsCache: [task.id: TaskRunsCache.capture(for: task, at: loadedAt)],
            now: now
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunShelfDiskScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeTask(root: URL, id: String) throws -> RunShelfTask {
        let directoryURL = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL.appendingPathComponent("runs", isDirectory: true),
            withIntermediateDirectories: true
        )
        let manifest = TaskManifest.create(id: id, name: id, description: "", enabled: true)
        let task = RunShelfTask(
            manifest: manifest,
            directoryURL: directoryURL,
            script: "#!/bin/zsh\n",
            notes: "",
            runs: [],
            isDirty: false
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: directoryURL.appendingPathComponent("task.json"), options: [.atomic])
        try task.script.write(to: directoryURL.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)
        try task.notes.write(to: directoryURL.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        return task
    }
}
