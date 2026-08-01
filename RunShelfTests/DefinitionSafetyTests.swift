import AppKit
import Foundation
import SwiftUI
import XCTest

final class DefinitionSafetyTests: XCTestCase {
    func testReusedEditorCoordinatorWritesOnlyToCurrentBinding() {
        final class Box {
            var value: String
            init(_ value: String) { self.value = value }
        }

        let first = Box("first")
        let second = Box("second")
        let firstEditor = ShellScriptEditor(text: Binding(
            get: { first.value },
            set: { first.value = $0 }
        ))
        let secondEditor = ShellScriptEditor(text: Binding(
            get: { second.value },
            set: { second.value = $0 }
        ))
        let coordinator = ShellScriptEditor.Coordinator(firstEditor)
        coordinator.update(parent: secondEditor)

        let textView = NSTextView()
        textView.string = "changed"
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))

        XCTAssertEqual(first.value, "first")
        XCTAssertEqual(second.value, "changed")
    }

    func testDirtyScanDoesNotAdvanceDefinitionSignature() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = try writeTask(root: root)
        let originalSignature = TaskFileSignature.capture(for: task.directoryURL)

        Thread.sleep(forTimeInterval: 0.02)
        try "#!/bin/zsh\necho outside\n".write(
            to: task.directoryURL.appendingPathComponent("run.sh"),
            atomically: true,
            encoding: .utf8
        )

        let result = DiskScanner.scan(DiskScanInput(
            tasksDirectoryURL: root,
            knownTasks: [.init(
                id: task.id,
                directoryURL: task.directoryURL,
                isDirty: true,
                generation: 0,
                runningRunIDs: []
            )],
            signatureCache: [task.id: originalSignature],
            runsCache: [task.id: TaskRunsCache.capture(for: task)]
        ))

        XCTAssertNil(result.newSignatures[task.id])
    }

    func testMissingNotesRemainCompatibleButInvalidUTF8Fails() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = try writeTask(root: root)
        let store = TaskFileStore(tasksDirectoryURL: root)
        let notesURL = task.directoryURL.appendingPathComponent("notes.md")

        try FileManager.default.removeItem(at: notesURL)
        XCTAssertEqual(try store.loadTask(at: task.directoryURL, includeRuns: false).notes, "")

        try Data([0xFF, 0xFE]).write(to: notesURL)
        XCTAssertThrowsError(try store.loadTask(at: task.directoryURL, includeRuns: false))
    }

    func testInvalidUTF8ScriptFailsInsteadOfLoadingEmptyText() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = try writeTask(root: root)
        try Data([0xFF, 0xFE]).write(to: task.directoryURL.appendingPathComponent("run.sh"))

        XCTAssertThrowsError(try TaskFileStore(tasksDirectoryURL: root).loadTask(
            at: task.directoryURL,
            includeRuns: false
        ))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunShelfDefinitionSafetyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeTask(root: URL) throws -> RunShelfTask {
        let id = UUID().uuidString
        let directoryURL = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL.appendingPathComponent("runs", isDirectory: true),
            withIntermediateDirectories: true
        )
        let manifest = TaskManifest.create(id: id, name: "Safety", description: "", enabled: true)
        let task = RunShelfTask(
            manifest: manifest,
            directoryURL: directoryURL,
            script: "#!/bin/zsh\necho safe\n",
            notes: "notes",
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
