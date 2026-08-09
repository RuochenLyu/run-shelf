import Foundation

enum RunShelfAgentGuide {
    static let beginMarker = "<!-- runshelf:begin -->"
    static let endMarker = "<!-- runshelf:end -->"

    static func markdown(executableURL: URL? = Bundle.main.executableURL) -> String {
        let executablePath = executableURL?.resolvingSymlinksInPath().path ?? "runshelf"
        return """
        # Run Shelf CLI for AI Agents

        Run Shelf 是本机优先的 macOS 自动化工具；AI agent 通过 `runshelf` CLI 安全地创建、运行、查询和删除任务。

        - CLI 绝对路径：`\(executablePath)`
        - 完整操作约定：`\(executablePath) help agent`
        - TaskSpec schema：`\(executablePath) schema task-spec`
        - 最小示例：`\(executablePath) schema task-spec --example`

        ## 操作约定

        1. 不要直接编辑 `task.json`、`run.sh`、`notes.md`；使用 `runshelf apply`，由 CLI 完成校验、CAS 冲突检测和原子写入。
        2. 读取任务使用 `task list --json` 和 `task show <id|slug> --json`；优先使用 id 或 slug，不要靠 name 猜测。
        3. 创建任务先执行 `apply spec.json --dry-run --json`，确认后再执行 `apply spec.json --json`。
        4. 更新任务前先用 `task show` 取得 `revisionToken`；dry-run 和正式 apply 都必须带 `--expected-revision <token>`。
        5. 前台运行使用 `run <id|slug> --wait --json`；长任务使用 `--detach`，再通过 `run status <runId> --json` 轮询。
        6. 日志使用 `run log <runId> --stdout|--stderr --json`；默认读取最后 1 MiB，可用 `--bytes` 或 `--full`。
        7. 停止任务使用 `run cancel <runId> --json`（`run stop` 是别名）；运行结束后可用 `task delete <id|slug> --json` 删除任务。
        8. JSON envelope 必含 `schemaVersion`。也可以设置 `RUNSHELF_JSON=1` 强制 JSON 输出。
        9. 前台 run 失败时退出码为 8，`ok=false`、`error.code=run_failed`，完整运行记录仍保留在 `result.run`。
        10. slug 不能使用 CLI 保留字 `status`、`log`、`cancel`、`stop`。

        ## 最小 TaskSpec

        ```json
        {
          "name": "Example task",
          "script": "#!/bin/zsh\\nset -euo pipefail\\n\\necho hello\\n"
        }
        ```

        ## 高风险命令

        `apply` 和 `run` 会扫描脚本。命中 `rm -rf`、`sudo` 等高风险模式时，默认返回 `dangerous_command`/退出码 6。只有用户明确确认后，才可为当次命令添加 `--allow-dangerous`；该开关不会写入任务配置。

        ## 退出码

        | 退出码 | 含义 |
        |---:|---|
        | 0 | 成功 |
        | 1 | 未分类错误；或 `doctor` 发现任务读取问题 |
        | 2 | 命令用法错误 |
        | 3 | 任务或运行记录不存在 |
        | 4 | 输入校验失败 |
        | 5 | 写入冲突或选择器歧义 |
        | 6 | 高风险命令被默认拦截 |
        | 7 | 任务正在运行 |
        | 8 | 脚本运行失败、超时或被取消 |

        遇到 `conflict`、`not_found`、`validation` 或 `already_running` 时，应重新读取状态或等待运行结束，不要猜测磁盘状态。
        """
    }

    static func markedBlock(executableURL: URL? = Bundle.main.executableURL) -> String {
        """
        \(beginMarker)
        \(markdown(executableURL: executableURL))
        \(endMarker)
        """
    }
}

enum RunShelfAgentSetupWriter {
    static func writeMarkedBlock(
        to targetURL: URL,
        executableURL: URL? = Bundle.main.executableURL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        let existingData = try? Data(contentsOf: targetURL)
        let existing = existingData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let block = RunShelfAgentGuide.markedBlock(executableURL: executableURL)
        let updated: String

        let beginRange = existing.range(of: RunShelfAgentGuide.beginMarker)
        let endRange = existing.range(of: RunShelfAgentGuide.endMarker)
        switch (beginRange, endRange) {
        case (nil, nil):
            let separator: String
            if existing.isEmpty || existing.hasSuffix("\n\n") {
                separator = ""
            } else if existing.hasSuffix("\n") {
                separator = "\n"
            } else {
                separator = "\n\n"
            }
            updated = existing + separator + block + "\n"
        case (.some(let begin), .some(let end)) where begin.lowerBound < end.upperBound:
            updated = existing.replacingCharacters(in: begin.lowerBound..<end.upperBound, with: block)
        default:
            throw RunShelfAgentSetupError.invalidMarkerBlock(targetURL.path)
        }

        guard updated != existing else { return false }
        try fileManager.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(updated.utf8).write(to: targetURL, options: .atomic)
        return true
    }
}

enum RunShelfAgentSetupError: LocalizedError {
    case invalidMarkerBlock(String)

    var errorDescription: String? {
        switch self {
        case .invalidMarkerBlock(let path):
            return "Run Shelf 标记块不完整，未修改文件：\(path)"
        }
    }
}
