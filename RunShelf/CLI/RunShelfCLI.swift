import Darwin
import Foundation

@main
enum RunShelfCLI {
    static func main() {
        var context = CLIContext(arguments: Array(CommandLine.arguments.dropFirst()))
        let exitCode: Int32
        do {
            exitCode = try context.run()
        } catch let error as CLIExitError {
            context.emitError(error)
            exitCode = Int32(error.exitCode)
        } catch let error as TaskRepositoryError {
            let mapped = CLIExitError.from(error)
            context.emitError(mapped)
            exitCode = Int32(mapped.exitCode)
        } catch let error as TaskRunClaimError {
            let mapped: CLIExitError
            if case .alreadyRunning = error {
                mapped = .running(error.localizedDescription)
            } else {
                mapped = .conflict(error.localizedDescription)
            }
            context.emitError(mapped)
            exitCode = Int32(mapped.exitCode)
        } catch let error as TaskRunnerError {
            let mapped = CLIExitError.from(error)
            context.emitError(mapped)
            exitCode = Int32(mapped.exitCode)
        } catch {
            context.emitError(.unexpected(error.localizedDescription))
            exitCode = 1
        }
        exit(exitCode)
    }
}

private struct CLIContext {
    private var arguments: [String]
    private let repository: TaskRepository
    private let jsonOutput: Bool

    init(arguments: [String]) {
        var args = arguments
        let envJSON = ProcessInfo.processInfo.environment["RUNSHELF_JSON"] == "1"
        let json = args.removeAll("--json") || envJSON
        self.arguments = args
        self.jsonOutput = json
        self.repository = TaskRepository()
    }

    mutating func run() throws -> Int32 {
        guard let command = arguments.popFirst() else {
            printGeneralHelp()
            return 0
        }

        switch command {
        case "task":
            return try runTaskCommand()
        case "apply":
            return try runApply()
        case "run":
            return try runRunCommand()
        case "doctor":
            return try runDoctor()
        case "install-cli":
            return try runInstallCLI()
        case "agent-setup":
            return try runAgentSetup()
        case "help":
            return try runHelp()
        case "schema":
            return try runSchema()
        case "version":
            return try runVersion()
        case "__run-host":
            return try runHost()
        default:
            throw CLIExitError.usage("未知命令：\(command)")
        }
    }

    func emitError(_ error: CLIExitError) {
        if jsonOutput {
            emit(Envelope(ok: false, result: Optional<String>.none, error: ErrorPayload(code: error.code, message: error.message)))
        } else {
            FileHandle.standardError.write(Data(("runshelf: \(error.message)\n").utf8))
        }
    }

    private mutating func runTaskCommand() throws -> Int32 {
        guard let subcommand = arguments.popFirst() else {
            throw CLIExitError.usage("task 需要子命令：list/show/delete")
        }

        switch subcommand {
        case "list":
            try rejectUnexpectedArguments()
            let tasks = try repository.loadTasksWithLatestRun().map { TaskPayload(task: $0) }
            emitOrPrint(tasks) {
                tasks.map { "\($0.id)\t\($0.slug ?? "-")\t\($0.name)" }.joined(separator: "\n")
            }
            return 0
        case "show":
            let selector = try takeValue("任务 id 或 slug")
            try rejectUnexpectedArguments()
            let read = try repository.loadTaskWithLatestRun(selector: .idOrSlug(selector))
            emitOrPrint(TaskDetailPayload(task: read.task, revision: read.revision)) {
                formatTask(read.task, revision: read.revision)
            }
            return 0
        case "delete":
            let selector = try takeValue("任务 id 或 slug")
            try rejectUnexpectedArguments()
            let id = try repository.deleteTask(selector: .idOrSlug(selector))
            emitOrPrint(["deleted": id]) {
                "已移到废纸篓：\(id)"
            }
            return 0
        default:
            throw CLIExitError.usage("未知 task 子命令：\(subcommand)")
        }
    }

    private mutating func runApply() throws -> Int32 {
        let dryRun = arguments.removeAll("--dry-run")
        let allowDangerous = arguments.removeAll("--allow-dangerous")
        let expectedRevision = try takeOptionalFlagValue("--expected-revision").map(TaskDefinitionRevision.init(token:))
        let path = try takeValue("TaskSpec JSON 文件路径，或 -")
        try rejectUnexpectedArguments()
        let spec = try readTaskSpec(path: path)
        let selector: TaskRepositorySelector?
        if let id = spec.id {
            selector = .id(id)
        } else if let slug = spec.slug {
            selector = .slug(slug)
        } else {
            selector = nil
        }

        let existing: TaskRepositoryReadResult?
        if let selector {
            do {
                existing = try repository.loadTask(selector: selector, includeRuns: true)
            } catch TaskRepositoryError.notFound(_) {
                existing = nil
            }
        } else {
            existing = nil
        }

        if existing != nil, expectedRevision == nil {
            throw CLIExitError.usage("更新已有任务必须提供 --expected-revision。请先运行 task show 获取 revisionToken。")
        }

        _ = try repository.validate(spec: spec, creating: existing == nil)
        let risks = DangerousCommandScanner.scan(spec.script ?? existing?.task.script ?? "")
        try rejectDangerousCommandRisks(risks, allowDangerous: allowDangerous)
        let action = existing == nil ? "create" : "update"
        if dryRun {
            let changes = applyChanges(spec: spec, existing: existing?.task)
            let payload = ApplyPayload(
                action: action,
                dryRun: true,
                task: existing.map { TaskPayload(task: $0.task) },
                revision: existing?.revision,
                revisionToken: existing?.revision.token,
                changes: changes,
                risks: risks.map(RiskPayload.init)
            )
            emitOrPrint(payload) {
                formatApply(payload)
            }
            return 0
        }

        let result: TaskRepositoryWriteResult
        if existing != nil, let selector {
            guard let expectedRevision else {
                throw CLIExitError.usage("更新已有任务必须提供 --expected-revision。请先运行 task show 获取 revisionToken。")
            }
            result = try repository.updateTask(selector: selector, with: spec, expectedRevision: expectedRevision)
        } else {
            if expectedRevision != nil {
                throw CLIExitError.conflict("--expected-revision 只能用于更新已有任务。")
            }
            result = try repository.createTask(from: spec, origin: .cli)
        }
        let payload = ApplyPayload(
            action: action,
            dryRun: false,
            task: TaskPayload(task: result.task),
            revision: result.revision,
            revisionToken: result.revision.token,
            changes: applyChanges(spec: spec, existing: existing?.task),
            risks: risks.map(RiskPayload.init)
        )
        emitOrPrint(payload) {
            formatApply(payload)
        }
        return 0
    }

    private mutating func runRunCommand() throws -> Int32 {
        guard let firstArgument = arguments.first else {
            throw CLIExitError.usage("run 需要任务 id/slug，或 status/log 子命令")
        }

        switch firstArgument {
        case "status":
            _ = arguments.popFirst()
            let runID = try takeValue("run id")
            try rejectUnexpectedArguments()
            let status = try findRun(runID: runID)
            emitOrPrint(status) {
                formatRunStatus(status)
            }
            return 0
        case "log":
            _ = arguments.popFirst()
            let runID = try takeValue("run id")
            let readsStdout = arguments.removeAll("--stdout")
            let readsStderr = arguments.removeAll("--stderr")
            guard !(readsStdout && readsStderr) else {
                throw CLIExitError.usage("--stdout 与 --stderr 不能同时使用。")
            }
            let stream = readsStderr ? "stderr" : "stdout"
            let full = arguments.removeAll("--full")
            let requestedBytes = try takeOptionalFlagValue("--bytes").map { value -> Int in
                guard let bytes = Int(value), (1...67_108_864).contains(bytes) else {
                    throw CLIExitError.validation("--bytes 必须是 1 到 67108864 之间的整数。")
                }
                return bytes
            }
            guard !(full && requestedBytes != nil) else {
                throw CLIExitError.usage("--full 与 --bytes 不能同时使用。")
            }
            try rejectUnexpectedArguments()
            let status = try findRun(runID: runID)
            let log = try readLog(
                status: status,
                stream: stream,
                byteLimit: full ? nil : (requestedBytes ?? 1_048_576)
            )
            if jsonOutput {
                emit(LogPayload(
                    runId: runID,
                    stream: stream,
                    text: log.text,
                    truncated: log.truncated,
                    totalBytes: log.totalBytes,
                    returnedBytes: log.returnedBytes
                ))
            } else {
                if log.truncated {
                    print("[仅显示最后 \(log.returnedBytes) 字节，共 \(log.totalBytes) 字节]")
                }
                print(log.text, terminator: "")
            }
            return 0
        case "cancel", "stop":
            _ = arguments.popFirst()
            let runID = try takeValue("run id")
            try rejectUnexpectedArguments()
            let payload = try cancelRun(runID: runID)
            emitOrPrint(payload) {
                "已发送终止信号：\(payload.runId)"
            }
            return 0
        default:
            let detach = arguments.removeAll("--detach")
            _ = arguments.removeAll("--wait")
            let allowDangerous = arguments.removeAll("--allow-dangerous")
            let selector = try takeValue("任务 id 或 slug")
            try rejectUnexpectedArguments()
            let read = try repository.loadTask(selector: .idOrSlug(selector), includeRuns: false)
            let risks = DangerousCommandScanner.scan(read.task.script)
            try rejectDangerousCommandRisks(risks, allowDangerous: allowDangerous)
            if detach {
                let payload = try startDetached(task: read.task)
                emitOrPrint(payload) {
                    "已在后台启动：\(payload.runId)"
                }
                return 0
            }

            let record = try TaskRunner.run(task: read.task, trigger: .manual, host: "cli")
            let payload = RunPayload(taskId: read.task.id, run: record)
            if record.status == .success {
                emitOrPrint(payload) {
                    "\(record.runId)\t\(record.status.rawValue)"
                }
                return 0
            }
            let error = CLIExitError.runFailed("任务运行失败：\(record.status.rawValue)")
            if jsonOutput {
                emit(Envelope(ok: false, result: payload, error: ErrorPayload(code: error.code, message: error.message)))
            } else {
                print("\(record.runId)\t\(record.status.rawValue)")
                FileHandle.standardError.write(Data(("runshelf: \(error.message)\n").utf8))
            }
            return Int32(error.exitCode)
        }
    }

    private mutating func runDoctor() throws -> Int32 {
        try rejectUnexpectedArguments()
        let loadResult = try repository.loadTasksWithIssues(includeRuns: false)
        let heartbeat = readJSONFile(at: RunShelfPaths.schedulerHeartbeatURL(), as: SchedulerHeartbeat.self)
        let payload = DoctorPayload(
            appSupportDirectory: RunShelfPaths.appSupportDirectoryURL().path,
            tasksDirectory: RunShelfPaths.tasksDirectoryURL().path,
            taskCount: loadResult.tasks.count,
            loadIssues: loadResult.issues,
            schedulerHeartbeat: heartbeat,
            path: ProcessInfo.processInfo.environment["PATH"] ?? ""
        )
        emitOrPrint(payload) {
            """
            App Support: \(payload.appSupportDirectory)
            Tasks: \(payload.tasksDirectory)
            任务数: \(payload.taskCount)
            读取问题: \(payload.loadIssues.count)
            PATH: \(payload.path)
            """
        }
        return loadResult.issues.isEmpty ? 0 : 1
    }

    private mutating func runInstallCLI() throws -> Int32 {
        let force = arguments.removeAll("--force")
        let prefix = (try takeOptionalFlagValue("--prefix")) ?? "~/.local/bin"
        try rejectUnexpectedArguments()
        let prefixURL = URL(fileURLWithPath: (prefix as NSString).expandingTildeInPath, isDirectory: true)
        guard let executableURL = Bundle.main.executableURL else {
            throw CLIExitError.unexpected("无法定位 runshelf 可执行文件。")
        }
        let result: RunShelfCLIInstallationResult
        do {
            result = try RunShelfCLIInstaller.install(
                executableURL: executableURL,
                prefixURL: prefixURL,
                force: force
            )
        } catch let error as RunShelfCLIInstallerError {
            if error.isConflict {
                throw CLIExitError.conflict(error.localizedDescription)
            }
            throw CLIExitError.unexpected(error.localizedDescription)
        }
        let payload = InstallCLIPayload(
            path: result.path,
            target: result.target,
            pathConfigured: result.pathConfigured
        )
        emitOrPrint(payload) {
            if payload.pathConfigured {
                return "已安装：\(payload.path)"
            }
            return "已安装：\(payload.path)\n当前 PATH 还不包含 \(prefixURL.path)"
        }
        return 0
    }

    private mutating func runHelp() throws -> Int32 {
        guard let topic = arguments.popFirst() else {
            printGeneralHelp()
            return 0
        }
        switch topic {
        case "agent":
            try rejectUnexpectedArguments()
            print(RunShelfAgentGuide.markdown())
            return 0
        default:
            throw CLIExitError.usage("未知帮助主题：\(topic)")
        }
    }

    private mutating func runAgentSetup() throws -> Int32 {
        let writeTarget = try takeOptionalFlagValue("--write")
        try rejectUnexpectedArguments()
        guard let writeTarget else {
            let content = RunShelfAgentGuide.markdown()
            if jsonOutput {
                emit(AgentSetupContentPayload(content: content))
            } else {
                print(content)
            }
            return 0
        }

        let targetURL: URL
        switch writeTarget {
        case "claude":
            targetURL = RunShelfAgentSetupWriter.claudeInstructionsURL()
        case "agents":
            targetURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent("AGENTS.md")
        default:
            throw CLIExitError.usage("--write 只支持 claude 或 agents。")
        }

        let changed = try RunShelfAgentSetupWriter.writeMarkedBlock(to: targetURL)
        let payload = AgentSetupWritePayload(target: writeTarget, path: targetURL.path, changed: changed)
        emitOrPrint(payload) {
            changed ? "已写入：\(targetURL.path)" : "无需更改：\(targetURL.path)"
        }
        return 0
    }

    private mutating func runSchema() throws -> Int32 {
        guard let name = arguments.popFirst() else {
            throw CLIExitError.usage("schema 需要名称：task-spec 或 cli-result")
        }
        let example = arguments.removeAll("--example")
        try rejectUnexpectedArguments()
        switch name {
        case "task-spec":
            print(example ? taskSpecExample : GeneratedSchemas.taskSpec)
            return 0
        case "cli-result":
            guard !example else {
                throw CLIExitError.usage("--example 只支持 schema task-spec。")
            }
            print(GeneratedSchemas.cliResult)
            return 0
        default:
            throw CLIExitError.usage("未知 schema：\(name)")
        }
    }

    private mutating func runVersion() throws -> Int32 {
        try rejectUnexpectedArguments()
        let appVersion = resolvedAppVersion()
        let payload = VersionPayload(appVersion: appVersion, envelopeSchemaVersion: cliEnvelopeSchemaVersion)
        emitOrPrint(payload) {
            "Run Shelf \(appVersion)\nCLI envelope schema \(cliEnvelopeSchemaVersion)"
        }
        return 0
    }

    private func resolvedAppVersion() -> String {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            return version
        }
        guard let executableURL = Bundle.main.executableURL else { return "unknown" }
        let productsDirectoryURL = executableURL.deletingLastPathComponent()
        let candidateAppURLs = [
            productsDirectoryURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent(),
            productsDirectoryURL.appendingPathComponent("Run Shelf.app", isDirectory: true)
        ]
        for appURL in candidateAppURLs where appURL.pathExtension == "app" {
            if let version = Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                return version
            }
        }
        return "unknown"
    }

    private mutating func runHost() throws -> Int32 {
        let taskID = try takeFlagValue("--task-id")
        let runID = try takeFlagValue("--run-id")
        try rejectUnexpectedArguments()
        let read = try repository.loadTask(selector: .id(taskID), includeRuns: false)
        let record = try TaskRunner.run(
            task: read.task,
            trigger: .manual,
            runId: runID,
            host: "cli-detach",
            claimMode: .existing
        )
        return record.status == .success ? 0 : 1
    }

    private mutating func startDetached(task: RunShelfTask) throws -> DetachedRunPayload {
        let runID = TaskRunner.makeRunID(from: Date())
        let lease = try TaskRunClaimManager.acquire(task: task, runID: runID, host: "cli-detach-launcher")
        do {
            let pid = try spawnDetachedHost(taskID: task.id, runID: runID)
            try lease.update(processID: pid, host: "cli-detach")
            return DetachedRunPayload(taskId: task.id, runId: runID, hostProcessID: pid)
        } catch {
            lease.release()
            throw error
        }
    }

    private func spawnDetachedHost(taskID: String, runID: String) throws -> pid_t {
        guard let executableURL = Bundle.main.executableURL else {
            throw CLIExitError.unexpected("无法定位 runshelf 可执行文件。")
        }

        var attributes: posix_spawnattr_t?
        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw CLIExitError.unexpected("无法初始化后台进程属性。")
        }
        defer { posix_spawnattr_destroy(&attributes) }

        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw CLIExitError.unexpected("无法初始化后台进程文件动作。")
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        let flags = Int16(POSIX_SPAWN_SETSID)
        guard posix_spawnattr_setflags(&attributes, flags) == 0 else {
            throw CLIExitError.unexpected("无法设置后台进程组。")
        }

        let redirectResult = "/dev/null".withCString { devNull in
            posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, devNull, O_RDONLY, 0) == 0 &&
                posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, devNull, O_WRONLY, 0) == 0 &&
                posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, devNull, O_WRONLY, 0) == 0
        }
        guard redirectResult else {
            throw CLIExitError.unexpected("无法重定向后台进程 stdio。")
        }

        let executablePath = strdup(executableURL.path)
        let command = strdup("__run-host")
        let taskFlag = strdup("--task-id")
        let taskValue = strdup(taskID)
        let runFlag = strdup("--run-id")
        let runValue = strdup(runID)
        guard let executablePath, let command, let taskFlag, let taskValue, let runFlag, let runValue else {
            throw CLIExitError.unexpected("无法编码后台运行参数。")
        }
        defer {
            free(executablePath)
            free(command)
            free(taskFlag)
            free(taskValue)
            free(runFlag)
            free(runValue)
        }

        var argv: [UnsafeMutablePointer<CChar>?] = [
            executablePath,
            command,
            taskFlag,
            taskValue,
            runFlag,
            runValue,
            nil
        ]
        var environment = ProcessInfo.processInfo.environment.map { key, value in
            strdup("\(key)=\(value)")
        }
        environment.append(nil)
        defer {
            for entry in environment where entry != nil {
                free(entry)
            }
        }

        var pid = pid_t()
        let result = argv.withUnsafeMutableBufferPointer { argvBuffer in
            environment.withUnsafeMutableBufferPointer { environmentBuffer in
                posix_spawn(
                    &pid,
                    executablePath,
                    &fileActions,
                    &attributes,
                    argvBuffer.baseAddress,
                    environmentBuffer.baseAddress
                )
            }
        }
        guard result == 0 else {
            throw CLIExitError.unexpected("无法启动后台运行宿主：\(String(cString: strerror(result)))")
        }
        return pid
    }

    private func findRun(runID: String) throws -> RunStatusPayload {
        guard TaskFileStore.isSafeRunID(runID) else {
            throw CLIExitError.validation("run id 不合法：\(runID)")
        }
        let tasks = try repository.loadTasks(includeRuns: false)
        for task in tasks {
            if let run = try repository.loadRun(task: task, runID: runID) {
                let claim = TaskRunClaimManager.activeClaim(for: task, runID: runID)
                return RunStatusPayload(
                    task: TaskPayload(task: task),
                    run: run,
                    claim: claim
                )
            }
            if let claim = TaskRunClaimManager.activeClaim(for: task, runID: runID) {
                return RunStatusPayload(task: TaskPayload(task: task), run: nil, claim: claim)
            }
        }
        throw CLIExitError.notFound("找不到运行记录：\(runID)")
    }

    private func cancelRun(runID: String) throws -> CancelRunPayload {
        guard TaskFileStore.isSafeRunID(runID) else {
            throw CLIExitError.validation("run id 不合法：\(runID)")
        }
        let tasks = try repository.loadTasks(includeRuns: false)
        for task in tasks {
            guard let claim = TaskRunClaimManager.activeClaim(for: task, runID: runID) else {
                continue
            }
            let runURL = task.directoryURL
                .appendingPathComponent("runs", isDirectory: true)
                .appendingPathComponent(runID, isDirectory: true)
            try? "cancelled by runshelf CLI\n".write(
                to: runURL.appendingPathComponent("cancel-requested"),
                atomically: true,
                encoding: .utf8
            )
            guard TaskRunClaimManager.canSafelySignal(claim) else {
                throw CLIExitError.conflict("无法验证运行进程身份；已写入取消请求，但为避免终止无关进程，未发送信号。")
            }
            if let processGroupID = claim.processGroupID, processGroupID > 0 {
                guard kill(-processGroupID, SIGTERM) == 0 || errno == ESRCH else {
                    throw CLIExitError.unexpected("无法终止进程组 \(processGroupID)：\(String(cString: strerror(errno)))")
                }
                return CancelRunPayload(taskId: task.id, runId: runID, signal: SIGTERM, processID: claim.processID, processGroupID: processGroupID)
            }
            guard kill(claim.processID, SIGTERM) == 0 || errno == ESRCH else {
                throw CLIExitError.unexpected("无法终止进程 \(claim.processID)：\(String(cString: strerror(errno)))")
            }
            return CancelRunPayload(taskId: task.id, runId: runID, signal: SIGTERM, processID: claim.processID, processGroupID: nil)
        }
        throw CLIExitError.notFound("找不到运行中的任务：\(runID)。运行可能已经结束；请用 run status 查看最终状态。")
    }

    private func readLog(
        status: RunStatusPayload,
        stream: String,
        byteLimit: Int?
    ) throws -> LogReadResult {
        guard let run = status.run else {
            throw CLIExitError.conflict("运行记录尚未写入日志文件。")
        }
        let runURL = RunShelfPaths.tasksDirectoryURL()
            .appendingPathComponent(status.task.id, isDirectory: true)
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(run.runId, isDirectory: true)
        let path = stream == "stderr" ? run.stderrPath : run.stdoutPath
        let url = runURL.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIExitError.notFound("日志文件不存在：\(stream)")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let totalBytes = Int(try handle.seekToEnd())
        let offset = byteLimit.map { max(totalBytes - $0, 0) } ?? 0
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.readToEnd() ?? Data()
        return LogReadResult(
            text: Self.decodeUTF8Tail(data),
            truncated: offset > 0,
            totalBytes: totalBytes,
            returnedBytes: data.count
        )
    }

    private static func decodeUTF8Tail(_ data: Data) -> String {
        for prefixBytesToDrop in 0...min(3, data.count) {
            if let text = String(data: data.dropFirst(prefixBytesToDrop), encoding: .utf8) {
                return text
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    private mutating func readTaskSpec(path: String) throws -> TaskSpec {
        let data: Data
        if path == "-" {
            data = FileHandle.standardInput.readDataToEndOfFile()
        } else {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(TaskSpec.self, from: data)
        } catch {
            throw CLIExitError.validation("TaskSpec JSON 无法解析：\(decodingErrorDescription(error))")
        }
    }

    private func decodingErrorDescription(_ error: Error) -> String {
        func path(_ codingPath: [CodingKey]) -> String {
            let value = codingPath.map(\.stringValue).joined(separator: ".")
            return value.isEmpty ? "$" : value
        }

        switch error {
        case DecodingError.dataCorrupted(let context):
            return "\(path(context.codingPath))：\(context.debugDescription)"
        case DecodingError.keyNotFound(let key, let context):
            return "\(path(context.codingPath + [key]))：缺少必填字段"
        case DecodingError.typeMismatch(_, let context):
            return "\(path(context.codingPath))：\(context.debugDescription)"
        case DecodingError.valueNotFound(_, let context):
            return "\(path(context.codingPath))：\(context.debugDescription)"
        default:
            return error.localizedDescription
        }
    }

    private func applyChanges(spec: TaskSpec, existing: RunShelfTask?) -> [ChangePayload] {
        guard let existing else {
            return [
                ChangePayload(field: "task", before: nil, after: "create")
            ]
        }

        var changes: [ChangePayload] = []
        appendChange(&changes, field: "slug", before: existing.manifest.slug, after: spec.slug)
        appendChange(&changes, field: "name", before: existing.manifest.name, after: spec.name)
        appendChange(&changes, field: "description", before: existing.manifest.description, after: spec.description)
        appendChange(&changes, field: "enabled", before: String(existing.manifest.enabled), after: spec.enabled.map(String.init))
        appendChange(&changes, field: "schedule", before: existing.manifest.schedule.expression, after: spec.schedule?.expression)
        appendChange(&changes, field: "timeoutSeconds", before: String(existing.manifest.runner.timeoutSeconds), after: spec.timeoutSeconds.map(String.init))
        appendChange(&changes, field: "script", before: hashSummary(existing.script), after: spec.script.map(hashSummary))
        appendChange(&changes, field: "notes", before: hashSummary(existing.notes), after: spec.notes.map(hashSummary))
        return changes
    }

    private func appendChange(_ changes: inout [ChangePayload], field: String, before: String?, after: String?) {
        guard let after, before != after else { return }
        changes.append(ChangePayload(field: field, before: before, after: after))
    }

    private func hashSummary(_ value: String) -> String {
        "\(value.count) chars"
    }

    private func rejectDangerousCommandRisks(_ risks: [CommandRisk], allowDangerous: Bool) throws {
        guard !risks.isEmpty, !allowDangerous else { return }
        let summary = risks.map { "\($0.pattern)：\($0.message)" }.joined(separator: "；")
        throw CLIExitError.dangerous("脚本包含高风险命令，默认拒绝写入或运行。确认要执行时加 --allow-dangerous。\(summary)")
    }

    private mutating func takeValue(_ label: String) throws -> String {
        guard let value = arguments.popFirst(), !value.hasPrefix("--") else {
            throw CLIExitError.usage("缺少参数：\(label)")
        }
        return value
    }

    private mutating func takeFlagValue(_ flag: String) throws -> String {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            throw CLIExitError.usage("缺少参数：\(flag)")
        }
        let value = arguments[index + 1]
        arguments.remove(at: index + 1)
        arguments.remove(at: index)
        return value
    }

    private mutating func takeOptionalFlagValue(_ flag: String) throws -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        guard arguments.indices.contains(index + 1) else {
            throw CLIExitError.usage("缺少参数：\(flag)")
        }
        let value = arguments[index + 1]
        arguments.remove(at: index + 1)
        arguments.remove(at: index)
        return value
    }

    private func rejectUnexpectedArguments() throws {
        guard arguments.isEmpty else {
            throw CLIExitError.usage("未知参数：\(arguments.joined(separator: " "))")
        }
    }

    private func emitOrPrint<T: Encodable>(_ payload: T, text: () -> String) {
        if jsonOutput {
            emit(payload)
        } else {
            print(text())
        }
    }

    private func emit<T: Encodable>(_ payload: T) {
        emit(Envelope(ok: true, result: payload, error: Optional<ErrorPayload>.none))
    }

    private func emit<T: Encodable>(_ envelope: Envelope<T>) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(envelope)
        } catch {
            let message = "runshelf: JSON envelope 编码失败：\(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(Int32(CLIExitError.unexpected(message).exitCode))
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private func printGeneralHelp() {
        print(
            """
            AI agent：先运行 runshelf help agent
            机器可读输出：命令加 --json，或设置 RUNSHELF_JSON=1

            runshelf task list [--json]
            runshelf task show <id|slug> [--json]
            runshelf task delete <id|slug> [--json]
            runshelf apply <task-spec.json|-> [--dry-run] [--expected-revision <token>] [--allow-dangerous] [--json]
            runshelf run <id|slug> [--wait|--detach] [--allow-dangerous] [--json]
            runshelf run status <run-id> [--json]
            runshelf run cancel <run-id> [--json]
            runshelf run stop <run-id> [--json]  # cancel 的别名
            runshelf run log <run-id> [--stdout|--stderr] [--bytes <n>|--full] [--json]
            runshelf doctor [--json]
            runshelf install-cli [--prefix ~/.local/bin] [--force] [--json]
            runshelf agent-setup [--write claude|agents] [--json]
            runshelf help agent
            runshelf schema task-spec [--example]
            runshelf schema cli-result
            runshelf version [--json]
            """
        )
    }
}

private enum CLIExitError: Error {
    case usage(String)
    case validation(String)
    case notFound(String)
    case conflict(String)
    case dangerous(String)
    case running(String)
    case runFailed(String)
    case unexpected(String)

    var exitCode: Int {
        switch self {
        case .usage: return 2
        case .validation: return 4
        case .notFound: return 3
        case .conflict: return 5
        case .dangerous: return 6
        case .running: return 7
        case .runFailed: return 8
        case .unexpected: return 1
        }
    }

    var code: String {
        switch self {
        case .usage: return "usage"
        case .validation: return "validation"
        case .notFound: return "not_found"
        case .conflict: return "conflict"
        case .dangerous: return "dangerous_command"
        case .running: return "already_running"
        case .runFailed: return "run_failed"
        case .unexpected: return "unexpected"
        }
    }

    var message: String {
        switch self {
        case .usage(let message),
             .validation(let message),
             .notFound(let message),
             .conflict(let message),
             .dangerous(let message),
             .running(let message),
             .runFailed(let message),
             .unexpected(let message):
            return message
        }
    }

    static func from(_ error: TaskRepositoryError) -> CLIExitError {
        switch error {
        case .notFound(_):
            return .notFound(error.localizedDescription)
        case .ambiguous(_, _), .conflict(_):
            return .conflict(error.localizedDescription)
        case .invalidSlug(_), .reservedSlug(_), .invalidSchedule(_), .invalidTimeoutSeconds(_), .invalidTaskID(_), .invalidRevision(_), .missingRequiredField(_):
            return .validation(error.localizedDescription)
        case .taskDirectoryMissing(_):
            return .notFound(error.localizedDescription)
        case .taskIdentityMismatch(_, _):
            return .validation(error.localizedDescription)
        case .taskRunning(_, _):
            return .running(error.localizedDescription)
        }
    }

    static func from(_ error: TaskRunnerError) -> CLIExitError {
        switch error {
        case .runAlreadyActive(_):
            return .running(error.localizedDescription)
        case .missingScript(_):
            return .validation(error.localizedDescription)
        case .processDidNotStart(_):
            return .unexpected(error.localizedDescription)
        }
    }
}

private struct Envelope<Result: Encodable>: Encodable {
    var schemaVersion: Int = cliEnvelopeSchemaVersion
    var ok: Bool
    var result: Result?
    var error: ErrorPayload?
}

private struct ErrorPayload: Encodable {
    var code: String
    var message: String
}

private struct TaskPayload: Encodable {
    var id: String
    var slug: String?
    var origin: String?
    var name: String
    var description: String
    var enabled: Bool
    var schedule: TaskSchedule
    var timeoutSeconds: Int
    var updatedAt: Date
    var latestRun: RunRecord?

    init(task: RunShelfTask) {
        self.id = task.id
        self.slug = task.manifest.slug
        self.origin = task.manifest.origin?.rawValue
        self.name = task.manifest.name
        self.description = task.manifest.description
        self.enabled = task.manifest.enabled
        self.schedule = task.manifest.schedule
        self.timeoutSeconds = task.manifest.runner.timeoutSeconds
        self.updatedAt = task.manifest.updatedAt
        self.latestRun = task.latestRun
    }
}

private struct TaskDetailPayload: Encodable {
    var task: TaskPayload
    var revision: TaskDefinitionRevision
    var revisionToken: String
    var script: String
    var notes: String
    var directoryPath: String

    init(task: RunShelfTask, revision: TaskDefinitionRevision) {
        self.task = TaskPayload(task: task)
        self.revision = revision
        self.revisionToken = revision.token
        self.script = task.script
        self.notes = task.notes
        self.directoryPath = task.directoryURL.path
    }
}

private struct ApplyPayload: Encodable {
    var action: String
    var dryRun: Bool
    var task: TaskPayload?
    var revision: TaskDefinitionRevision?
    var revisionToken: String?
    var changes: [ChangePayload]
    var risks: [RiskPayload]
}

private struct ChangePayload: Encodable {
    var field: String
    var before: String?
    var after: String?
}

private struct RiskPayload: Encodable {
    var pattern: String
    var message: String

    init(_ risk: CommandRisk) {
        self.pattern = risk.pattern
        self.message = risk.message
    }
}

private struct RunPayload: Encodable {
    var taskId: String
    var run: RunRecord
}

private struct DetachedRunPayload: Encodable {
    var taskId: String
    var runId: String
    var hostProcessID: Int32
}

private struct RunStatusPayload: Encodable {
    var task: TaskPayload
    var run: RunRecord?
    var claim: TaskRunClaim?
}

private struct CancelRunPayload: Encodable {
    var taskId: String
    var runId: String
    var signal: Int32
    var processID: Int32
    var processGroupID: Int32?
}

private struct LogPayload: Encodable {
    var runId: String
    var stream: String
    var text: String
    var truncated: Bool
    var totalBytes: Int
    var returnedBytes: Int
}

private struct LogReadResult {
    var text: String
    var truncated: Bool
    var totalBytes: Int
    var returnedBytes: Int
}

private struct DoctorPayload: Encodable {
    var appSupportDirectory: String
    var tasksDirectory: String
    var taskCount: Int
    var loadIssues: [TaskLoadIssue]
    var schedulerHeartbeat: SchedulerHeartbeat?
    var path: String
}

private struct InstallCLIPayload: Encodable {
    var path: String
    var target: String
    var pathConfigured: Bool
}

private struct VersionPayload: Encodable {
    var appVersion: String
    var envelopeSchemaVersion: Int
}

private struct AgentSetupContentPayload: Encodable {
    var content: String
}

private struct AgentSetupWritePayload: Encodable {
    var target: String
    var path: String
    var changed: Bool
}

private func formatTask(_ task: RunShelfTask, revision: TaskDefinitionRevision) -> String {
    """
    \(task.manifest.name)
    id: \(task.id)
    slug: \(task.manifest.slug ?? "-")
    enabled: \(task.manifest.enabled)
    schedule: \(task.manifest.schedule.expression)
    timeoutSeconds: \(task.manifest.runner.timeoutSeconds)
    revision: \(revision.manifest?.size ?? 0)/\(revision.script?.size ?? 0)/\(revision.notes?.size ?? 0)
    revisionToken: \(revision.token)
    """
}

private func formatApply(_ payload: ApplyPayload) -> String {
    let changes = payload.changes.isEmpty ? "无字段变化" : payload.changes.map { "\($0.field): \($0.before ?? "-") -> \($0.after ?? "-")" }.joined(separator: "\n")
    let risks = payload.risks.isEmpty ? "未发现高风险命令" : payload.risks.map { "\($0.pattern)：\($0.message)" }.joined(separator: "\n")
    return """
    action: \(payload.action)
    dryRun: \(payload.dryRun)
    revisionToken: \(payload.revisionToken ?? "-")
    \(changes)
    \(risks)
    """
}

private func formatRunStatus(_ payload: RunStatusPayload) -> String {
    if let run = payload.run {
        return "\(run.runId)\t\(payload.task.name)\t\(run.status.rawValue)"
    }
    if let claim = payload.claim {
        return "\(claim.runId)\t\(payload.task.name)\trunning\tpid=\(claim.processID)"
    }
    return "\(payload.task.name)\tunknown"
}

private func readJSONFile<T: Decodable>(at url: URL, as type: T.Type) -> T? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(T.self, from: data)
}

private extension Array where Element == String {
    mutating func popFirst() -> String? {
        isEmpty ? nil : removeFirst()
    }

    mutating func removeAll(_ value: String) -> Bool {
        let oldCount = count
        self = filter { $0 != value }
        return oldCount != count
    }
}

private let cliEnvelopeSchemaVersion = 1

private let taskSpecExample = """
{
  "name": "Example task",
  "script": "#!/bin/zsh\\nset -euo pipefail\\n\\necho hello\\n"
}
"""
