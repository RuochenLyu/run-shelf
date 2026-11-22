import XCTest

final class ScriptImporterTests: XCTestCase {
    func testPythonWithoutShebangGetsEnvShebang() throws {
        let imported = try ScriptImporter.makeScript(
            fromText: "import os\nprint(os.getcwd())\n",
            fileName: "check.py"
        )

        XCTAssertEqual(imported.language, .python)
        XCTAssertTrue(imported.didAddShebang)
        XCTAssertTrue(imported.script.hasPrefix("#!/usr/bin/env python3\n"))
        XCTAssertTrue(imported.script.hasSuffix("\n"))
    }

    func testExistingShebangIsPreserved() throws {
        let imported = try ScriptImporter.makeScript(
            fromText: "#!/bin/bash\nset -e\necho hi\n",
            fileName: "no-extension"
        )

        XCTAssertEqual(imported.language, .bash)
        XCTAssertFalse(imported.didAddShebang)
        XCTAssertEqual(imported.shebang, "#!/bin/bash")
        XCTAssertEqual(imported.script, "#!/bin/bash\nset -e\necho hi\n")
    }

    func testEnvShebangWithFlagsResolvesInterpreter() throws {
        let imported = try ScriptImporter.makeScript(
            fromText: "#!/usr/bin/env -S node --enable-source-maps\nconsole.log(1)\n"
        )

        XCTAssertEqual(imported.language, .node)
        XCTAssertFalse(imported.didAddShebang)
    }

    func testCRLFAndBOMAreNormalized() throws {
        let raw = "\u{FEFF}#!/bin/zsh\r\necho one\r\necho two\r\n"
        let imported = try ScriptImporter.makeScript(fromText: raw)

        XCTAssertFalse(imported.script.contains("\r"))
        XCTAssertFalse(imported.script.hasPrefix("\u{FEFF}"))
        XCTAssertEqual(imported.language, .zsh)
        XCTAssertEqual(imported.lineCount, 3)
    }

    func testContentBeatsUnusualExtension() throws {
        // .txt 里装的其实是 python：内容优先
        let imported = try ScriptImporter.makeScript(
            fromText: "def main():\n    print('hi')\n",
            fileName: "notes.txt"
        )

        XCTAssertEqual(imported.language, .python)
    }

    func testExtensionIsOnlyAFallbackWithWarning() throws {
        let imported = try ScriptImporter.makeScript(fromText: "hello world\n", fileName: "tool.py")

        XCTAssertEqual(imported.language, .python)
        XCTAssertFalse(imported.warnings.isEmpty)
        XCTAssertTrue(imported.warnings.contains { $0.contains("扩展名") })
    }

    func testUnknownTextFallsBackToZshWithWarning() throws {
        let imported = try ScriptImporter.makeScript(fromText: "只是一段普通文字\n", fileName: "readme")

        XCTAssertEqual(imported.language, .unknown)
        XCTAssertTrue(imported.didAddShebang)
        XCTAssertTrue(imported.script.hasPrefix("#!/bin/zsh\n"))
        XCTAssertTrue(imported.warnings.contains { $0.contains("未识别") })
    }

    func testShellSniffingDetectsZshFeatures() throws {
        let imported = try ScriptImporter.makeScript(
            fromText: "set -euo pipefail\nvalue=\"$(date +%F)\"\necho \"$value\"\n"
        )

        XCTAssertEqual(imported.language, .zsh)
    }

    func testEmptyTextThrows() {
        XCTAssertThrowsError(try ScriptImporter.makeScript(fromText: "  \n\t\n")) { error in
            XCTAssertEqual(error as? ScriptImportError, .empty)
        }
    }

    func testInterpreterNameParsing() {
        XCTAssertEqual(ScriptImporter.interpreterName(from: "#!/bin/zsh -e"), "zsh")
        XCTAssertEqual(ScriptImporter.interpreterName(from: "#!/usr/bin/env python3"), "python3")
        XCTAssertNil(ScriptImporter.interpreterName(from: "echo hi"))
    }

    func testSummaryMentionsLanguageAndLines() throws {
        let imported = try ScriptImporter.makeScript(fromText: "import sys\nprint(sys.argv)\n")

        XCTAssertTrue(imported.summary.contains("python"))
        XCTAssertTrue(imported.summary.contains("行"))
    }

    func testLoadReadsFileFromDisk() throws {
        let contents = Data("print('hi')\n".utf8)
        let url = try temporaryFile(named: "backup.py", contents: contents)

        let imported = try ScriptImporter.load(from: url)

        XCTAssertEqual(imported.language, .python)
        XCTAssertEqual(imported.byteCount, contents.count)
        XCTAssertTrue(imported.script.hasPrefix("#!/usr/bin/env python3\n"))
    }

    func testBinaryFileIsRejected() throws {
        var contents = Data("#!/bin/zsh\necho hi\n".utf8)
        contents.append(0)
        contents.append(Data("tail\n".utf8))
        let url = try temporaryFile(named: "binary.sh", contents: contents)

        XCTAssertThrowsError(try ScriptImporter.load(from: url)) { error in
            XCTAssertEqual(error as? ScriptImportError, .binary)
        }
    }

    func testOversizedFileIsRejected() throws {
        let oversized = Data(repeating: 0x23, count: ScriptImporter.maxBytes + 1)
        let url = try temporaryFile(named: "huge.sh", contents: oversized)

        XCTAssertThrowsError(try ScriptImporter.load(from: url)) { error in
            guard case .tooLarge(let limitBytes, let actualBytes)? = error as? ScriptImportError else {
                XCTFail("expected .tooLarge, got \(error)")
                return
            }
            XCTAssertEqual(limitBytes, ScriptImporter.maxBytes)
            XCTAssertEqual(actualBytes, ScriptImporter.maxBytes + 1)
        }
    }

    /// 每个用例独立的临时目录，teardown 时删除；不触碰真实 Run Shelf 数据目录。
    private func temporaryFile(named name: String, contents: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScriptImporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }
}
