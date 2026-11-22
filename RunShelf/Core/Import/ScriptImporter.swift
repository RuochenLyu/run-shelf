import Foundation

/// 从本地文件导入脚本的结果。
///
/// Run Shelf 的 `run.sh` 是被直接 `exec` 的，所以第一行必须是 shebang；
/// 导入时如果原文件没有 shebang，这里会按识别出的语言补一行。
struct ImportedScript: Equatable {
    enum Language: String, Equatable, CaseIterable {
        case zsh
        case bash
        case sh
        case python
        case node
        case ruby
        case perl
        case osascript
        case unknown

        var displayName: String {
            switch self {
            case .zsh: return "zsh"
            case .bash: return "bash"
            case .sh: return "sh"
            case .python: return "python"
            case .node: return "node"
            case .ruby: return "ruby"
            case .perl: return "perl"
            case .osascript: return "osascript"
            case .unknown: return "未知"
            }
        }

        /// 补 shebang 时用的解释器；`unknown` 退回 `/bin/zsh`。
        var defaultShebang: String {
            switch self {
            case .zsh: return "#!/bin/zsh"
            case .bash: return "#!/bin/bash"
            case .sh: return "#!/bin/sh"
            case .python: return "#!/usr/bin/env python3"
            case .node: return "#!/usr/bin/env node"
            case .ruby: return "#!/usr/bin/env ruby"
            case .perl: return "#!/usr/bin/env perl"
            case .osascript: return "#!/usr/bin/osascript"
            case .unknown: return "#!/bin/zsh"
            }
        }
    }

    /// 已归一化（去 BOM、CRLF → LF、必要时补 shebang）的脚本文本。
    let script: String
    let language: Language
    let shebang: String?
    let didAddShebang: Bool
    let byteCount: Int
    let lineCount: Int
    let warnings: [String]

    var summary: String {
        var parts = ["检测为 \(language.displayName)"]
        if didAddShebang { parts.append("已补 shebang") }
        parts.append("\(lineCount) 行")
        return parts.joined(separator: " · ")
    }
}

enum ScriptImportError: LocalizedError, Equatable {
    case unreadable(String)
    case tooLarge(limitBytes: Int, actualBytes: Int)
    case binary
    case empty

    var errorDescription: String? {
        switch self {
        case .unreadable(let reason):
            return "读取文件失败：\(reason)"
        case .tooLarge(let limitBytes, let actualBytes):
            let limit = ByteCountFormatter.string(fromByteCount: Int64(limitBytes), countStyle: .file)
            let actual = ByteCountFormatter.string(fromByteCount: Int64(actualBytes), countStyle: .file)
            return "文件太大（\(actual)，上限 \(limit)）"
        case .binary:
            return "这不是文本文件，无法作为脚本导入"
        case .empty:
            return "文件内容为空"
        }
    }
}

/// 内容优先的脚本识别：先看 shebang，再看语法特征，最后才参考扩展名。
enum ScriptImporter {
    typealias Language = ImportedScript.Language

    /// 512 KiB。run.sh 是纯文本定义，超过这个量级基本不是手写脚本。
    static let maxBytes = 512 * 1024

    static func load(from url: URL) throws -> ImportedScript {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ScriptImportError.unreadable(error.localizedDescription)
        }
        guard data.count <= maxBytes else {
            throw ScriptImportError.tooLarge(limitBytes: maxBytes, actualBytes: data.count)
        }
        guard !data.contains(0) else {
            throw ScriptImportError.binary
        }
        let text = decode(data)
        return try makeScript(fromText: text, fileName: url.lastPathComponent, byteCount: data.count)
    }

    /// 纯文本 → 脚本。UI 和测试共用这一层，不碰文件系统。
    static func makeScript(
        fromText rawText: String,
        fileName: String? = nil,
        byteCount: Int? = nil
    ) throws -> ImportedScript {
        var text = rawText
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        text = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ScriptImportError.empty
        }

        var warnings: [String] = []
        let shebang = firstShebang(in: text)
        // 先 shebang → 解释器名（/usr/bin/env -S node … → node），再解释器名 → 语言
        let interpreter = shebang.flatMap(Self.interpreterName(from:))
        var detected = interpreter.flatMap(Self.language(forInterpreter:)) ?? .unknown

        if shebang == nil {
            if let sniffed = sniffLanguage(in: text) {
                detected = sniffed
            } else if let byExtension = Self.language(forFileExtension: fileName) {
                detected = byExtension
                warnings.append("内容没看出语言特征，按扩展名识别为 \(byExtension.displayName)")
            } else {
                detected = .unknown
                warnings.append("未识别脚本类型，按 zsh 导入，请确认内容")
            }
        }

        var didAddShebang = false
        if shebang == nil {
            text = detected.defaultShebang + "\n" + text
            didAddShebang = true
            warnings.append("原文件没有 shebang，已补 \(detected.defaultShebang)")
        }
        if !text.hasSuffix("\n") {
            text += "\n"
        }

        return ImportedScript(
            script: text,
            language: detected,
            shebang: shebang ?? detected.defaultShebang,
            didAddShebang: didAddShebang,
            byteCount: byteCount ?? text.utf8.count,
            lineCount: text.split(separator: "\n", omittingEmptySubsequences: false).count - 1,
            warnings: warnings
        )
    }

    // MARK: - 识别

    static func firstShebang(in text: String) -> String? {
        guard let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first else {
            return nil
        }
        let line = firstLine.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("#!") else { return nil }
        return line
    }

    /// `#!/usr/bin/env python3` → `python3`；`#!/bin/zsh -e` → `zsh`
    static func interpreterName(from shebang: String) -> String? {
        var body = shebang.trimmingCharacters(in: .whitespaces)
        guard body.hasPrefix("#!") else { return nil }
        body = String(body.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        let parts = body.split(whereSeparator: \.isWhitespace).map(String.init)
        guard var interpreter = parts.first else { return nil }
        if interpreter.hasSuffix("/env") {
            // env VAR=1 python3 这种形式，取第一个既不是选项、也不含 = 的参数
            guard let real = parts.dropFirst().first(where: { !$0.hasPrefix("-") && !$0.contains("=") }) else {
                return nil
            }
            interpreter = real
        }
        return (interpreter as NSString).lastPathComponent
    }

    static func language(forInterpreter name: String) -> Language? {
        let lower = name.lowercased()
        if lower.contains("zsh") { return .zsh }
        if lower.contains("bash") { return .bash }
        if lower == "sh" || lower == "dash" || lower == "ksh" { return .sh }
        if lower.hasPrefix("python") { return .python }
        if lower == "node" || lower == "deno" || lower == "bun" { return .node }
        if lower.hasPrefix("ruby") { return .ruby }
        if lower.hasPrefix("perl") { return .perl }
        if lower.hasPrefix("osascript") { return .osascript }
        return nil
    }

    static func language(forFileExtension fileName: String?) -> Language? {
        guard let fileName else { return nil }
        switch (fileName as NSString).pathExtension.lowercased() {
        case "py": return .python
        case "js", "mjs", "cjs": return .node
        case "rb": return .ruby
        case "pl": return .perl
        case "zsh": return .zsh
        case "bash": return .bash
        case "sh", "command", "tool": return .sh
        case "scpt", "applescript": return .osascript
        default: return nil
        }
    }

    /// 没有 shebang 时的语法特征判断。只看前 4000 字符，够用且不拖慢大文件。
    static func sniffLanguage(in text: String) -> Language? {
        let sample = text.count > 4000 ? String(text.prefix(4000)) : text

        func matches(_ pattern: String) -> Bool {
            sample.range(of: pattern, options: [.regularExpression]) != nil
        }

        if matches("(?m)^\\s*(import\\s+[A-Za-z_][\\w.]*|from\\s+[A-Za-z_][\\w.]*\\s+import)\\b")
            || matches("(?m)^\\s*def\\s+\\w+\\s*\\(")
            || matches("(?m)^if\\s+__name__\\s*==")
            || matches("\\bprint\\s*\\(") {
            return .python
        }
        if matches("\\brequire\\s*\\(")
            || matches("\\bmodule\\.exports\\b")
            || matches("\\bprocess\\.(argv|env|exit)\\b")
            || matches("(?m)^\\s*(const|let)\\s+\\w+\\s*=")
            || matches("=>") {
            return .node
        }
        if matches("(?m)^\\s*puts\\s+")
            || (matches("(?m)^\\s*def\\s+\\w+") && matches("(?m)^\\s*end\\s*$")) {
            return .ruby
        }
        if matches("\\buse\\s+strict\\b") || matches("\\bmy\\s+\\$") {
            return .perl
        }
        if matches("\\$\\(")
            || matches("(?m)^\\s*set\\s+-[A-Za-z]*e")
            || matches("(?m)^\\s*(fi|done|esac)\\s*$")
            || matches("\\[\\[")
            || matches("(?m)^\\s*export\\s+\\w+=")
            || matches("(?m)^\\s*(if|for|while)\\s+\\[") {
            return .zsh
        }
        return nil
    }

    private static func decode(_ data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        // 老脚本常见 GB18030 / Latin-1 混排；能读出来总比报错好
        if let gb = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        ))) {
            return gb
        }
        return String(decoding: data, as: UTF8.self)
    }
}
