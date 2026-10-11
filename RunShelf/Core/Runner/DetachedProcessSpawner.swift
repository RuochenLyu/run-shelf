import Darwin
import Foundation

enum DetachedProcessSpawnerError: LocalizedError {
    case setupFailed(String)
    case spawnFailed(String)

    var errorDescription: String? {
        switch self {
        case .setupFailed(let message):
            return message
        case .spawnFailed(let message):
            return "无法启动后台运行宿主：\(message)"
        }
    }
}

/// 以新 session（`POSIX_SPAWN_SETSID`）启动运行宿主。
///
/// 新 session 意味着宿主不在调用方（CLI、调度进程）的进程组里：调用方退出、崩溃，
/// 或被 launchd 结束作业时，宿主继续监督脚本并写入真实终态。
enum DetachedProcessSpawner {
    static func spawn(
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        stderrAppendURL: URL? = nil
    ) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw DetachedProcessSpawnerError.setupFailed("无法初始化后台进程属性。")
        }
        defer { posix_spawnattr_destroy(&attributes) }

        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw DetachedProcessSpawnerError.setupFailed("无法初始化后台进程文件动作。")
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID)) == 0 else {
            throw DetachedProcessSpawnerError.setupFailed("无法设置后台进程组。")
        }

        let stderrPath = stderrAppendURL?.path ?? "/dev/null"
        let stderrFlags = stderrAppendURL == nil ? O_WRONLY : (O_WRONLY | O_APPEND | O_CREAT)
        let redirectResult = "/dev/null".withCString { devNull in
            stderrPath.withCString { stderrTarget in
                posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, devNull, O_RDONLY, 0) == 0 &&
                    posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, devNull, O_WRONLY, 0) == 0 &&
                    posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, stderrTarget, stderrFlags, 0o600) == 0
            }
        }
        guard redirectResult else {
            throw DetachedProcessSpawnerError.setupFailed("无法重定向后台进程 stdio。")
        }

        let argumentStrings = [executableURL.path] + arguments
        var argv: [UnsafeMutablePointer<CChar>?] = argumentStrings.map { strdup($0) }
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { key, value in strdup("\(key)=\(value)") }
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        guard !argv.contains(where: { $0 == nil }), !envp.contains(where: { $0 == nil }) else {
            throw DetachedProcessSpawnerError.setupFailed("无法编码后台运行参数。")
        }
        argv.append(nil)
        envp.append(nil)

        var pid = pid_t()
        let result = argv.withUnsafeMutableBufferPointer { argvBuffer in
            envp.withUnsafeMutableBufferPointer { envpBuffer in
                posix_spawn(
                    &pid,
                    executableURL.path,
                    &fileActions,
                    &attributes,
                    argvBuffer.baseAddress,
                    envpBuffer.baseAddress
                )
            }
        }
        guard result == 0 else {
            throw DetachedProcessSpawnerError.spawnFailed(String(cString: strerror(result)))
        }
        return pid
    }

    /// 阻塞回收子进程，返回原始 wait status；不是自己的子进程时返回 nil。
    static func waitForExit(pid: pid_t) -> Int32? {
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, 0)
            if result == pid { return status }
            if result == -1, errno == EINTR { continue }
            return nil
        }
    }
}
