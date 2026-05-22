import Foundation

struct CommandRisk: Identifiable, Equatable {
    var id: String { pattern }
    var pattern: String
    var message: String
}

enum DangerousCommandScanner {
    private static let checks: [(pattern: String, expression: NSRegularExpression, message: String)] = [
        ("rm -rf /", try! NSRegularExpression(pattern: #"rm\s+-[^\n;]*r[^\n;]*f[^\n;]*\s+/"#, options: [.caseInsensitive]), "`rm -rf /` 可能删除系统或根目录内容。"),
        ("sudo", try! NSRegularExpression(pattern: #"(^|\s)sudo\s+"#, options: [.caseInsensitive]), "`sudo` 会请求管理员权限，后台运行时也可能卡住。"),
        ("chmod -R", try! NSRegularExpression(pattern: #"chmod\s+-R\s+"#, options: [.caseInsensitive]), "`chmod -R` 会递归修改权限。"),
        ("chown -R", try! NSRegularExpression(pattern: #"chown\s+-R\s+"#, options: [.caseInsensitive]), "`chown -R` 会递归修改所有者。"),
        ("curl | sh", try! NSRegularExpression(pattern: #"(curl|wget)[^\n|;]*\|\s*(sh|bash|zsh)"#, options: [.caseInsensitive]), "通过网络下载后直接执行脚本风险较高。"),
        ("disk erase", try! NSRegularExpression(pattern: #"diskutil\s+(erase|partition|apfs\s+delete)"#, options: [.caseInsensitive]), "`diskutil` 擦除或分区命令会修改磁盘。")
    ]

    static func scan(_ script: String) -> [CommandRisk] {
        let range = NSRange(script.startIndex..<script.endIndex, in: script)
        return checks.compactMap { check in
            guard check.expression.firstMatch(in: script, range: range) != nil else { return nil }
            return CommandRisk(pattern: check.pattern, message: check.message)
        }
    }
}
