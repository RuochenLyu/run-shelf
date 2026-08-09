import Combine
import Foundation

/// 异步读 stdout/stderr 日志文件。
/// - 切 run 时 cancel 上一次未完成的读，结果不会污染新选中的 run。
/// - 大文件只读尾部，避免 SwiftUI Text 在主线程做巨型字符串布局。
@MainActor
final class LogContentLoader: ObservableObject {
    /// 单条日志文件最多读取的字节数（截尾）。超过部分丢弃，但记录原始大小让 UI 提示。
    nonisolated static let maxBytes: Int64 = 1_048_576  // 1 MB
    /// SwiftUI Text 布局超长单行很贵；保留行尾即可覆盖日志里常见的长 JSON / blob。
    nonisolated private static let maxLineCharacters = 16_384
    private static let cacheLimit = 8
    private static let loadingIndicatorDelayNanoseconds: UInt64 = 150_000_000

    struct Content: Equatable {
        var text: String
        var byteCount: Int64
        var isFileTruncated: Bool
        var hasLineTruncation: Bool

        static let empty = Content(
            text: "",
            byteCount: 0,
            isFileTruncated: false,
            hasLineTruncation: false
        )
    }

    @Published private(set) var stdout: Content = .empty
    @Published private(set) var stderr: Content = .empty
    @Published private(set) var isLoading = false
    @Published private(set) var isWaitingForContent = false

    /// 当前正在加载的 (taskID, runID) 组合，防止 stale 结果污染。
    private var currentKey: LoadKey?
    private var loadTask: Task<Void, Never>?
    private var loadingIndicatorTask: Task<Void, Never>?
    private var cache: [LoadKey: CachedContent] = [:]
    private var cacheOrder: [LoadKey] = []

    func load(task: RunShelfTask, run: RunRecord, force: Bool = false) {
        let key = LoadKey(taskID: task.id, runID: run.runId, status: run.status.rawValue)
        // 已经在加载同一组合：跳过（避免 view body 重算反复触发）
        if !force, currentKey == key, loadTask != nil { return }
        if !force, currentKey == key { return }

        loadTask?.cancel()
        loadingIndicatorTask?.cancel()

        if !force, let cached = cache[key] {
            currentKey = key
            publish(cached)
            touchCacheKey(key)
            loadTask = nil
            setLoading(false)
            setWaitingForContent(false)
            return
        }

        let isInitialLoad = currentKey != key
        currentKey = key
        setWaitingForContent(isInitialLoad)
        if isInitialLoad || (stdout.text.isEmpty && stderr.text.isEmpty) {
            setLoading(false)
            loadingIndicatorTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.loadingIndicatorDelayNanoseconds)
                guard !Task.isCancelled, let self else { return }
                guard self.currentKey == key, self.loadTask != nil else { return }
                self.setLoading(true)
            }
        }

        let runURL = task.directoryURL
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(run.runId, isDirectory: true)
        let stdoutURL = runURL.appendingPathComponent(run.stdoutPath)
        let stderrURL = runURL.appendingPathComponent(run.stderrPath)

        loadTask = Task { [weak self] in
            async let outAsync = Self.readTail(at: stdoutURL)
            async let errAsync = Self.readTail(at: stderrURL)
            let (out, err) = await (outAsync, errAsync)

            guard !Task.isCancelled else { return }
            guard let self else { return }
            // 二次校验：load 期间用户切了别的 run，丢弃这次结果
            guard self.currentKey == key else { return }

            let content = CachedContent(stdout: out, stderr: err)
            self.storeInCache(content, for: key)
            self.publish(content)
            self.loadingIndicatorTask?.cancel()
            self.loadingIndicatorTask = nil
            self.setWaitingForContent(false)
            self.setLoading(false)
            self.loadTask = nil
        }
    }

    func clear() {
        loadTask?.cancel()
        loadingIndicatorTask?.cancel()
        loadTask = nil
        loadingIndicatorTask = nil
        currentKey = nil
        stdout = .empty
        stderr = .empty
        setLoading(false)
        setWaitingForContent(false)
    }

    /// 测试和确定性调用可等待当前读取完成，无需猜测文件系统时序。
    func waitForCurrentLoad() async {
        let task = loadTask
        await task?.value
    }

    private func publish(_ content: CachedContent) {
        if stdout != content.stdout {
            stdout = content.stdout
        }
        if stderr != content.stderr {
            stderr = content.stderr
        }
    }

    private func setLoading(_ value: Bool) {
        if isLoading != value {
            isLoading = value
        }
    }

    private func setWaitingForContent(_ value: Bool) {
        if isWaitingForContent != value {
            isWaitingForContent = value
        }
    }

    private func storeInCache(_ content: CachedContent, for key: LoadKey) {
        cache[key] = content
        touchCacheKey(key)
        while cacheOrder.count > Self.cacheLimit {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }

    private func touchCacheKey(_ key: LoadKey) {
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
    }

    /// 后台读：文件 ≤ maxBytes 整读；超过则 seek 到末尾倒退 maxBytes 字节，
    /// 从最近一个换行符开始切，避免显示半截 UTF-8 序列或被截断的行。
    nonisolated private static func readTail(at url: URL) async -> Content {
        await Task.detached(priority: .userInitiated) {
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                return Content.empty
            }
            defer { try? handle.close() }

            let totalSize: Int64
            do {
                totalSize = Int64(try handle.seekToEnd())
            } catch {
                return Content.empty
            }

            if totalSize <= LogContentLoader.maxBytes {
                do {
                    try handle.seek(toOffset: 0)
                } catch {
                    return Content.empty
                }
                let data = (try? handle.readToEnd()) ?? Data()
                let prepared = preparedDisplayText(from: data)
                return Content(
                    text: prepared.text,
                    byteCount: totalSize,
                    isFileTruncated: false,
                    hasLineTruncation: prepared.didTruncateLine
                )
            }

            // 大文件：只读尾部 maxBytes
            let offset = UInt64(totalSize - LogContentLoader.maxBytes)
            do {
                try handle.seek(toOffset: offset)
            } catch {
                return Content.empty
            }
            let data = (try? handle.readToEnd()) ?? Data()
            // 切到第一个换行符之后，避免半截行
            var trimmed = data
            if let newlineIdx = data.firstIndex(of: 0x0A) {
                trimmed = data.subdata(in: (newlineIdx + 1)..<data.endIndex)
            }
            let prepared = preparedDisplayText(from: trimmed)
            return Content(
                text: prepared.text,
                byteCount: totalSize,
                isFileTruncated: true,
                hasLineTruncation: prepared.didTruncateLine
            )
        }.value
    }

    nonisolated private static func preparedDisplayText(from data: Data) -> (text: String, didTruncateLine: Bool) {
        let text = String(decoding: data, as: UTF8.self)
        return truncateLongLines(in: text)
    }

    nonisolated private static func truncateLongLines(in text: String) -> (text: String, didTruncateLine: Bool) {
        guard text.count > maxLineCharacters else {
            return (text, false)
        }

        var didTruncate = false
        var output = String()
        output.reserveCapacity(text.count)

        var isFirstLine = true
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if isFirstLine {
                isFirstLine = false
            } else {
                output.append("\n")
            }

            guard line.count > maxLineCharacters else {
                output.append(contentsOf: line)
                continue
            }

            didTruncate = true
            output.append("[单行过长，已省略中间内容，仅显示最后 ")
            output.append(String(maxLineCharacters))
            output.append(" 个字符]\n")
            output.append(contentsOf: line.suffix(maxLineCharacters))
        }

        return (output, didTruncate)
    }

    private struct CachedContent {
        let stdout: Content
        let stderr: Content
    }

    private struct LoadKey: Hashable {
        let taskID: String
        let runID: String
        let status: String
    }
}
