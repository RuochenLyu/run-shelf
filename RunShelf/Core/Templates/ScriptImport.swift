import Foundation

/// 一个本地脚本文件被导入后的结果。脚本正文只做规范化（去 BOM、换行统一为 LF、
/// 补末尾换行），缺 shebang 时只在最前面补一行，绝不改写用户代码。
struct ScriptImport: Equatable {
    var fileName: String
    var sourcePath: String
    var script: String
    /// 面向用户的解释器名，例如 `bash`、`python3`。
    var interpreter: String
    var lineCount: Int
    /// 至多一条需要用户知道的提示：补了哪个 shebang，或运行时可能找不到解释器。
    var notice: String?

    var taskName: String {
        let base = (fileName as NSString).deletingPathExtension
        return base.isEmpty ? fileName : base
    }

    var summary: String {
        "\(fileName) · \(interpreter) · \(lineCount) 行"
    }

    var taskDescription: String {
        "导入自 \((sourcePath as NSString).abbreviatingWithTildeInPath)"
    }
}

enum ScriptImportError: LocalizedError, Equatable {
    case notRegularFile
    case unreadable
    case tooLarge(limit: Int)
    case utf16
    case binary
    case notUTF8
    case empty

    var errorDescription: String? {
        switch self {
        case .notRegularFile: "只能导入普通文件"
        case .unreadable: "无法读取这个文件"
        case .tooLarge(let limit): "文件超过 \(limit / 1024) KB，不像是脚本"
        case .utf16: "文件是 UTF-16 编码，请先转成 UTF-8"
        case .binary: "这是二进制文件，不是脚本"
        case .notUTF8: "文件不是 UTF-8 编码"
        case .empty: "文件是空的"
        }
    }
}

struct ScriptImporter {
    static let maxBytes = 128 * 1024
    /// LaunchAgent 与从 Finder/Dock 打开的 App 实际拿到的 PATH。任务进程继承它，
    /// 所以解释器解析只看这份固定列表，不看导入进程自己的 PATH。
    static let runtimeSearchPath = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    /// 用户终端里通常优先的位置；`/usr/bin/python3` 是 CLT shim，`/usr/bin/ruby` 是 2.6。
    static let preferredSearchPath = ["/opt/homebrew/bin", "/usr/local/bin"]

    var isExecutable: (String) -> Bool = ScriptImporter.isExecutableFile

    func load(from url: URL) throws -> ScriptImport {
        let resolved = url.resolvingSymlinksInPath()
        let values: URLResourceValues
        do {
            values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        } catch {
            throw ScriptImportError.unreadable
        }
        // 目录、FIFO、设备文件一律拒绝；读 FIFO 会卡住主线程。
        guard values.isRegularFile == true else { throw ScriptImportError.notRegularFile }
        if let size = values.fileSize, size > Self.maxBytes {
            throw ScriptImportError.tooLarge(limit: Self.maxBytes)
        }

        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: resolved)
            defer { try? handle.close() }
            // 属性可能与实际内容不一致（读取期间被写入），所以读取本身也有界。
            data = try handle.read(upToCount: Self.maxBytes + 1) ?? Data()
        } catch {
            throw ScriptImportError.unreadable
        }
        return try make(data: data, fileName: url.lastPathComponent, sourcePath: url.path)
    }

    func make(data: Data, fileName: String, sourcePath: String) throws -> ScriptImport {
        guard data.count <= Self.maxBytes else { throw ScriptImportError.tooLarge(limit: Self.maxBytes) }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            throw ScriptImportError.utf16
        }
        if data.contains(0) { throw ScriptImportError.binary }
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        guard let text = String(data: bytes, encoding: .utf8) else { throw ScriptImportError.notUTF8 }
        return try make(text: text, fileName: fileName, sourcePath: sourcePath)
    }

    func make(text: String, fileName: String, sourcePath: String) throws -> ScriptImport {
        var body = text
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        body = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScriptImportError.empty
        }
        if !body.hasSuffix("\n") { body += "\n" }
        let lineCount = body.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }

        // 内核只认第 0 字节开始的 `#!`；前面有空格就不是 shebang。
        let firstLine = String(body.prefix { $0 != "\n" })
        if firstLine.hasPrefix("#!") {
            let inspection = inspect(shebang: firstLine)
            return ScriptImport(
                fileName: fileName,
                sourcePath: sourcePath,
                script: body,
                interpreter: inspection.label,
                lineCount: lineCount,
                notice: inspection.notice
            )
        }

        let choice = chooseInterpreter(forExtension: (fileName as NSString).pathExtension)
        return ScriptImport(
            fileName: fileName,
            sourcePath: sourcePath,
            script: "\(choice.shebang)\n\(body)",
            interpreter: choice.label,
            lineCount: lineCount,
            notice: choice.notice
        )
    }

    // MARK: - Interpreter

    private struct Choice {
        var shebang: String
        var label: String
        var notice: String?
    }

    private func chooseInterpreter(forExtension ext: String) -> Choice {
        switch ext.lowercased() {
        case "sh", "bash":
            return prepended("/bin/bash", label: "bash")
        case "py":
            return resolved("python3")
        case "js", "mjs", "cjs":
            return resolved("node")
        case "rb":
            return resolved("ruby")
        case "pl":
            return resolved("perl")
        case "applescript":
            return prepended("/usr/bin/osascript", label: "osascript")
        default:
            // `.zsh`、`.command`、无扩展名、`.txt` 等：Run Shelf 的原生任务语言。
            return prepended("/bin/zsh", label: "zsh")
        }
    }

    private func prepended(_ path: String, label: String) -> Choice {
        Choice(shebang: "#!\(path)", label: label, notice: "已补 #!\(path)，可在创建后修改")
    }

    private func resolved(_ name: String) -> Choice {
        if let path = locate(name, in: Self.preferredSearchPath + Self.runtimeSearchPath) {
            return prepended(path, label: name)
        }
        return Choice(
            shebang: "#!/usr/bin/env \(name)",
            label: name,
            notice: "没找到 \(name)，已补 #!/usr/bin/env \(name)，运行前请改为实际路径"
        )
    }

    private func inspect(shebang line: String) -> (label: String, notice: String?) {
        let parts = line.dropFirst(2)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard let program = parts.first else {
            return ("未知", "首行 #! 没有写解释器")
        }
        guard program.hasPrefix("/") else {
            return (program, "解释器 \(program) 不是绝对路径，运行会失败")
        }
        guard isExecutable(program) else {
            return ((program as NSString).lastPathComponent, "解释器 \(program) 不存在")
        }
        guard (program as NSString).lastPathComponent == "env" else {
            return ((program as NSString).lastPathComponent, nil)
        }
        guard let name = envTarget(Array(parts.dropFirst())) else {
            return ("env", nil)
        }
        let label = (name as NSString).lastPathComponent
        if name.contains("/") {
            return (label, nil)
        }
        let runtime = locate(name, in: Self.runtimeSearchPath)
        let preferred = locate(name, in: Self.preferredSearchPath)
        switch (runtime, preferred) {
        case (nil, let preferred?):
            return (label, "运行时找不到 \(name)，建议改为 #!\(preferred)")
        case (nil, nil):
            return (label, "运行时找不到 \(name)")
        case (let runtime?, let preferred?):
            return (label, "运行时 \(name) 会是 \(runtime)，建议改为 #!\(preferred)")
        case (_?, nil):
            return (label, nil)
        }
    }

    /// `env` 之后第一个真正的程序名；跳过选项和 `VAR=value`。
    /// 带 `-P altpath` 时 env 自己换了搜索路径，不再推断。
    private func envTarget(_ args: [String]) -> String? {
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "-P" { return nil }
            if ["-u", "-L", "-U"].contains(arg) {
                index += 2
                continue
            }
            if arg.hasPrefix("-") || arg.contains("=") {
                index += 1
                continue
            }
            return arg
        }
        return nil
    }

    private func locate(_ name: String, in directories: [String]) -> String? {
        directories
            .map { ($0 as NSString).appendingPathComponent(name) }
            .first(where: isExecutable)
    }

    static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }
}

extension TaskTemplate {
    static let importedTemplateID = "imported-file"

    /// 新建任务表单里的「导入文件」卡片；不在 `builtIns` 里。
    static func imported(_ source: ScriptImport) -> TaskTemplate {
        TaskTemplate(
            id: importedTemplateID,
            name: source.taskName,
            description: source.taskDescription,
            defaultSchedule: .defaultDaily,
            script: source.script,
            notes: "",
            enabledByDefault: true
        )
    }
}
