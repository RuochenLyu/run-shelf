import Darwin
import Foundation

struct RunShelfCLIInstallationResult: Equatable, Sendable {
    var path: String
    var target: String
    var pathConfigured: Bool
}

struct RunShelfCLIInstallationStatus: Equatable, Sendable {
    var path: String
    var target: String
    var isInstalled: Bool
    var pathConfigured: Bool
}

enum RunShelfCLIInstaller {
    static func defaultPrefixURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let homePath = environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent(".local/bin", isDirectory: true)
    }

    static func inspect(
        executableURL: URL,
        prefixURL: URL = defaultPrefixURL(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> RunShelfCLIInstallationStatus {
        let destinationURL = prefixURL.appendingPathComponent("runshelf")
        let isInstalled = fileManager.fileExists(atPath: destinationURL.path) &&
            destinationURL.resolvingSymlinksInPath().standardizedFileURL ==
            executableURL.resolvingSymlinksInPath().standardizedFileURL
        return RunShelfCLIInstallationStatus(
            path: destinationURL.path,
            target: executableURL.path,
            isInstalled: isInstalled,
            pathConfigured: pathContains(prefixURL: prefixURL, environment: environment)
        )
    }

    static func install(
        executableURL: URL,
        prefixURL: URL,
        force: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> RunShelfCLIInstallationResult {
        let destinationURL = prefixURL.appendingPathComponent("runshelf")
        try fileManager.createDirectory(at: prefixURL, withIntermediateDirectories: true)

        var destinationInfo = stat()
        let destinationExists = lstat(destinationURL.path, &destinationInfo) == 0
        if !destinationExists && errno != ENOENT {
            throw RunShelfCLIInstallerError.cannotInspect(String(cString: strerror(errno)))
        }
        if destinationExists {
            guard force else {
                throw RunShelfCLIInstallerError.targetExists(destinationURL.path)
            }
            let fileType = destinationInfo.st_mode & mode_t(S_IFMT)
            guard fileType == mode_t(S_IFREG) || fileType == mode_t(S_IFLNK) else {
                throw RunShelfCLIInstallerError.unsafeTarget(destinationURL.path)
            }
            guard unlink(destinationURL.path) == 0 else {
                throw RunShelfCLIInstallerError.cannotReplace(String(cString: strerror(errno)))
            }
        }
        try fileManager.createSymbolicLink(at: destinationURL, withDestinationURL: executableURL)
        return RunShelfCLIInstallationResult(
            path: destinationURL.path,
            target: executableURL.path,
            pathConfigured: pathContains(prefixURL: prefixURL, environment: environment)
        )
    }

    private static func pathContains(prefixURL: URL, environment: [String: String]) -> Bool {
        (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
            .contains(prefixURL.path)
    }
}

enum RunShelfCLIInstallerError: LocalizedError {
    case targetExists(String)
    case unsafeTarget(String)
    case cannotInspect(String)
    case cannotReplace(String)

    var isConflict: Bool {
        switch self {
        case .targetExists, .unsafeTarget: return true
        case .cannotInspect, .cannotReplace: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .targetExists(let path):
            return "目标已存在：\(path)。确认要覆盖时使用 --force。"
        case .unsafeTarget(let path):
            return "拒绝覆盖目录或特殊文件：\(path)"
        case .cannotInspect(let reason):
            return "无法检查安装目标：\(reason)"
        case .cannotReplace(let reason):
            return "无法替换安装目标：\(reason)"
        }
    }
}
