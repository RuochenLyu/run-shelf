import Foundation
import XCTest

final class ScriptImportTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        temporaryDirectories.forEach { try? FileManager.default.removeItem(at: $0) }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    // MARK: - Shebang and extension

    func testOwnShebangIsKeptVerbatim() throws {
        let importer = fakeImporter(["/bin/bash"])
        let source = "#!/bin/bash -eu\necho hi\n"
        let result = try importer.make(text: source, fileName: "a.py", sourcePath: "/tmp/a.py")
        XCTAssertEqual(result.script, source)
        XCTAssertEqual(result.interpreter, "bash")
        XCTAssertNil(result.notice)
    }

    func testEnvDashSShebangIsKeptAndResolvesProgram() throws {
        let importer = fakeImporter(["/usr/bin/env", "/usr/bin/node"])
        let source = "#!/usr/bin/env -S node --no-warnings\nconsole.log(1)\n"
        let result = try importer.make(text: source, fileName: "a.js", sourcePath: "/tmp/a.js")
        XCTAssertEqual(result.script, source)
        XCTAssertEqual(result.interpreter, "node")
        XCTAssertNil(result.notice)
    }

    func testIndentedHashBangIsNotAShebang() throws {
        let result = try fakeImporter([]).make(text: "  #!/usr/bin/python3\necho hi\n", fileName: "a.sh", sourcePath: "/tmp/a.sh")
        XCTAssertEqual(result.script, "#!/bin/bash\n  #!/usr/bin/python3\necho hi\n")
    }

    func testExtensionMapWithoutShebang() throws {
        let importer = fakeImporter([
            "/opt/homebrew/bin/python3",
            "/opt/homebrew/bin/node",
            "/usr/bin/ruby",
            "/usr/bin/perl",
        ])
        let cases: [(String, String, String)] = [
            ("a.zsh", "#!/bin/zsh", "zsh"),
            ("a.command", "#!/bin/zsh", "zsh"),
            ("Makefile-ish", "#!/bin/zsh", "zsh"),
            ("a.txt", "#!/bin/zsh", "zsh"),
            ("a.weird", "#!/bin/zsh", "zsh"),
            ("a.sh", "#!/bin/bash", "bash"),
            ("a.BASH", "#!/bin/bash", "bash"),
            ("a.py", "#!/opt/homebrew/bin/python3", "python3"),
            ("a.js", "#!/opt/homebrew/bin/node", "node"),
            ("a.mjs", "#!/opt/homebrew/bin/node", "node"),
            ("a.cjs", "#!/opt/homebrew/bin/node", "node"),
            ("a.rb", "#!/usr/bin/ruby", "ruby"),
            ("a.pl", "#!/usr/bin/perl", "perl"),
            ("a.applescript", "#!/usr/bin/osascript", "osascript"),
        ]
        for (fileName, shebang, label) in cases {
            let result = try importer.make(text: "x\n", fileName: fileName, sourcePath: "/tmp/\(fileName)")
            XCTAssertEqual(result.script, "\(shebang)\nx\n", fileName)
            XCTAssertEqual(result.interpreter, label, fileName)
            XCTAssertEqual(result.notice, "已补 \(shebang)，可在创建后修改", fileName)
        }
    }

    // MARK: - Normalization

    func testBOMAndLineEndingsAreNormalized() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("#!/bin/zsh\r\necho a\recho b".utf8)
        let result = try fakeImporter(["/bin/zsh"]).make(data: data, fileName: "a.zsh", sourcePath: "/tmp/a.zsh")
        XCTAssertEqual(result.script, "#!/bin/zsh\necho a\necho b\n")
        XCTAssertEqual(result.lineCount, 3)
    }

    func testTrailingNewlinesAreNotTrimmed() throws {
        let result = try fakeImporter(["/bin/zsh"]).make(text: "#!/bin/zsh\necho a\n\n", fileName: "a", sourcePath: "/tmp/a")
        XCTAssertEqual(result.script, "#!/bin/zsh\necho a\n\n")
        XCTAssertEqual(result.lineCount, 3)
    }

    func testLineCountCountsSourceLinesNotPrependedShebang() throws {
        let result = try fakeImporter([]).make(text: "a\nb\nc", fileName: "a.sh", sourcePath: "/tmp/a.sh")
        XCTAssertEqual(result.lineCount, 3)
        XCTAssertEqual(result.summary, "a.sh · bash · 3 行")
    }

    func testRejectsEmptyUTF16BinaryAndInvalidUTF8() {
        let importer = fakeImporter([])
        XCTAssertThrowsError(try importer.make(data: Data(" \n\t\n".utf8), fileName: "a", sourcePath: "/a")) {
            XCTAssertEqual($0 as? ScriptImportError, .empty)
        }
        XCTAssertThrowsError(try importer.make(data: Data([0xFF, 0xFE, 0x23, 0x00]), fileName: "a", sourcePath: "/a")) {
            XCTAssertEqual($0 as? ScriptImportError, .utf16)
        }
        XCTAssertThrowsError(try importer.make(data: Data([0x23, 0x21, 0x00, 0x01]), fileName: "a", sourcePath: "/a")) {
            XCTAssertEqual($0 as? ScriptImportError, .binary)
        }
        XCTAssertThrowsError(try importer.make(data: Data([0x65, 0xC3, 0x28]), fileName: "a", sourcePath: "/a")) {
            XCTAssertEqual($0 as? ScriptImportError, .notUTF8)
        }
    }

    // MARK: - Interpreter resolution

    func testHomebrewWinsOverRuntimePath() throws {
        let importer = fakeImporter(["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"])
        let result = try importer.make(text: "print(1)\n", fileName: "a.py", sourcePath: "/tmp/a.py")
        XCTAssertTrue(result.script.hasPrefix("#!/opt/homebrew/bin/python3\n"))
    }

    func testFallsBackToRuntimePathWhenNoHomebrewCopy() throws {
        let importer = fakeImporter(["/usr/bin/python3"])
        let result = try importer.make(text: "print(1)\n", fileName: "a.py", sourcePath: "/tmp/a.py")
        XCTAssertTrue(result.script.hasPrefix("#!/usr/bin/python3\n"))
    }

    func testMissingInterpreterUsesEnvWithNotice() throws {
        let result = try fakeImporter([]).make(text: "console.log(1)\n", fileName: "a.js", sourcePath: "/tmp/a.js")
        XCTAssertEqual(result.script, "#!/usr/bin/env node\nconsole.log(1)\n")
        XCTAssertEqual(result.notice, "没找到 node，已补 #!/usr/bin/env node，运行前请改为实际路径")
    }

    func testOwnEnvShebangWarnsWhenRuntimePathCannotResolve() throws {
        let importer = fakeImporter(["/usr/bin/env", "/opt/homebrew/bin/node"])
        let source = "#!/usr/bin/env node\nconsole.log(1)\n"
        let result = try importer.make(text: source, fileName: "a.js", sourcePath: "/tmp/a.js")
        XCTAssertEqual(result.script, source)
        XCTAssertEqual(result.notice, "运行时找不到 node，建议改为 #!/opt/homebrew/bin/node")
    }

    func testOwnEnvShebangWarnsWhenRuntimePathResolvesElsewhere() throws {
        let importer = fakeImporter(["/usr/bin/env", "/usr/bin/python3", "/opt/homebrew/bin/python3"])
        let result = try importer.make(text: "#!/usr/bin/env python3\nprint(1)\n", fileName: "a", sourcePath: "/tmp/a")
        XCTAssertEqual(result.notice, "运行时 python3 会是 /usr/bin/python3，建议改为 #!/opt/homebrew/bin/python3")
    }

    func testOwnEnvShebangIsQuietWhenOnlyRuntimeCopyExists() throws {
        let importer = fakeImporter(["/usr/bin/env", "/bin/bash"])
        let result = try importer.make(text: "#!/usr/bin/env bash\necho\n", fileName: "a", sourcePath: "/tmp/a")
        XCTAssertNil(result.notice)
        XCTAssertEqual(result.interpreter, "bash")
    }

    func testEnvWithCustomSearchPathIsNotSecondGuessed() throws {
        let importer = fakeImporter(["/usr/bin/env"])
        let result = try importer.make(text: "#!/usr/bin/env -P /opt/x node\n", fileName: "a", sourcePath: "/tmp/a")
        XCTAssertNil(result.notice)
    }

    func testMissingAbsoluteInterpreterWarns() throws {
        let result = try fakeImporter([]).make(text: "#!/usr/local/bin/bash\necho\n", fileName: "a.sh", sourcePath: "/tmp/a.sh")
        XCTAssertEqual(result.script, "#!/usr/local/bin/bash\necho\n")
        XCTAssertEqual(result.interpreter, "bash")
        XCTAssertEqual(result.notice, "解释器 /usr/local/bin/bash 不存在")
    }

    // MARK: - File loading

    func testLoadRejectsOversizeFileWithoutReadingIt() throws {
        let url = try makeTemporaryDirectory().appendingPathComponent("big.sh")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(ScriptImporter.maxBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try ScriptImporter().load(from: url)) {
            XCTAssertEqual($0 as? ScriptImportError, .tooLarge(limit: ScriptImporter.maxBytes))
        }
    }

    func testLoadRejectsDirectoryAndFIFOAndMissingFile() throws {
        let root = try makeTemporaryDirectory()
        XCTAssertThrowsError(try ScriptImporter().load(from: root)) {
            XCTAssertEqual($0 as? ScriptImportError, .notRegularFile)
        }
        let fifo = root.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try ScriptImporter().load(from: fifo)) {
            XCTAssertEqual($0 as? ScriptImportError, .notRegularFile)
        }
        XCTAssertThrowsError(try ScriptImporter().load(from: root.appendingPathComponent("missing.sh"))) {
            XCTAssertEqual($0 as? ScriptImportError, .unreadable)
        }
    }

    func testLoadFollowsSymlinkButKeepsLinkName() throws {
        let root = try makeTemporaryDirectory()
        let target = root.appendingPathComponent("real.sh")
        try "echo hi\n".write(to: target, atomically: true, encoding: .utf8)
        let link = root.appendingPathComponent("backup.sh")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let result = try ScriptImporter().load(from: link)
        XCTAssertEqual(result.fileName, "backup.sh")
        XCTAssertEqual(result.taskName, "backup")
        XCTAssertEqual(result.script, "#!/bin/bash\necho hi\n")
    }

    // MARK: - Store and runner

    @MainActor
    func testImportedTaskIsWrittenVerbatimAndRuns() throws {
        let root = try makeTemporaryDirectory()
        let tasksURL = root.appendingPathComponent("tasks", isDirectory: true)
        try FileManager.default.createDirectory(at: tasksURL, withIntermediateDirectories: true)
        try "seeded\n".write(to: tasksURL.appendingPathComponent(".examples-seeded"), atomically: true, encoding: .utf8)

        let marker = root.appendingPathComponent("ran.txt")
        let sourceURL = root.appendingPathComponent("hello.sh")
        try "printf '%s' \"${BASH_VERSION:+bash}\" > '\(marker.path)'\r\n"
            .write(to: sourceURL, atomically: true, encoding: .utf8)
        let imported = try ScriptImporter().load(from: sourceURL)

        let store = TaskStore(tasksDirectoryURL: tasksURL, startsDiskMonitor: false)
        let id = try XCTUnwrap(store.createTask(from: .imported(imported), name: "", scheduleExpression: "0 9 * * *"))
        let task = try XCTUnwrap(store.tasks.first { $0.id == id })

        let scriptURL = task.directoryURL.appendingPathComponent("run.sh")
        XCTAssertEqual(try String(contentsOf: scriptURL, encoding: .utf8), imported.script)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: scriptURL.path))
        XCTAssertEqual(task.manifest.name, "hello")
        XCTAssertEqual(task.manifest.description, imported.taskDescription)
        XCTAssertTrue(task.manifest.description.hasPrefix("导入自 "))
        XCTAssertEqual(task.manifest.origin, .app)
        XCTAssertEqual(task.notes, "")

        let record = try TaskRunner.run(task: task, trigger: .manual)
        XCTAssertEqual(record.status, .success)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "bash")
    }

    // MARK: - Helpers

    private func fakeImporter(_ executables: Set<String>) -> ScriptImporter {
        var importer = ScriptImporter()
        importer.isExecutable = { executables.contains($0) }
        return importer
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScriptImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }
}
