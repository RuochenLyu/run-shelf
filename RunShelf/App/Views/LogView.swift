import SwiftUI

struct LogView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var selection: TaskSelectionState
    @StateObject private var loader = LogContentLoader()
    var task: RunShelfTask

    var body: some View {
        Group {
            if task.runs.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    RunHistoryList(runs: sortedRuns, selection: selectionBinding)
                        .frame(width: 200)

                    Divider()

                    logPane
                }
            }
        }
        .task(id: reloadKey) {
            reloadIfNeeded(force: effectiveRun?.status == .running)
            while !Task.isCancelled, effectiveRun?.status == .running {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                reloadIfNeeded(force: true)
            }
        }
    }

    private func reloadIfNeeded(force: Bool = false) {
        if let run = effectiveRun {
            loader.load(task: task, run: run, force: force)
        } else {
            loader.clear()
        }
    }

    private var reloadKey: String {
        "\(task.id):\(effectiveRun?.runId ?? "none"):\(effectiveRun.map { String(describing: $0.status) } ?? "none")"
    }

    private var logPane: some View {
        VStack(spacing: 0) {
            if let run = effectiveRun {
                header(for: run)
                Divider()
                output(for: run)
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func header(for run: RunRecord) -> some View {
        HStack(spacing: 10) {
            StatusBadge(text: run.status.displayName, color: run.status.badgeColor)

            Text(RunShelfFormatters.dateTimeWithSeconds(run.startedAt))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if let exitCode = run.exitCode, exitCode != 0 {
                Text("退出码 \(exitCode)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.red)
            }

            Spacer(minLength: 8)

            if let duration = run.durationMs {
                Text(RunShelfFormatters.duration(duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func output(for run: RunRecord) -> some View {
        let stdout = loader.stdout.text
        let stderr = loader.stderr.text

        if stdout.isEmpty && stderr.isEmpty && loader.isWaitingForContent {
            VStack {
                Spacer()
                if loader.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if stdout.isEmpty && stderr.isEmpty {
            VStack {
                Spacer()
                Text("没有输出")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZStack {
                LogTextView(
                    content: LogTextView.Content(
                        stdout: stdout,
                        stderr: stderr,
                        stdoutNotice: truncationNotice(for: loader.stdout),
                        stderrNotice: truncationNotice(for: loader.stderr)
                    ),
                    scrollKey: "\(task.id):\(run.runId)"
                )

                if loader.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func truncationNotice(for content: LogContentLoader.Content) -> String? {
        guard content.isFileTruncated else { return nil }
        return "仅显示最后 \(RunShelfFormatters.byteSize(LogContentLoader.maxBytes))（总 \(RunShelfFormatters.byteSize(content.byteCount))）"
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("暂无运行记录")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("点右上角的运行按钮跑一次试试")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sortedRuns: [RunRecord] {
        task.runs
    }

    private var effectiveRun: RunRecord? {
        if let id = selection.selectedRunID,
           let run = task.runs.first(where: { $0.runId == id }) {
            return run
        }
        return task.latestRun
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { effectiveRun?.runId },
            set: { selection.selectedRunID = $0 }
        )
    }
}

private struct RunHistoryList: View {
    var runs: [RunRecord]
    @Binding var selection: String?

    var body: some View {
        List(selection: $selection) {
            ForEach(runs) { run in
                RunHistoryRow(run: run)
                    .tag(run.runId)
            }
        }
        .listStyle(.inset)
    }
}

private struct RunHistoryRow: View {
    var run: RunRecord

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: run.status.statusSymbol)
                .foregroundStyle(run.status.badgeColor)
                .imageScale(.small)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                Text(RunShelfFormatters.scheduleDateTime(run.startedAt))
                    .font(.callout)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts = [run.status.displayName, run.trigger.displayName]
        if let duration = run.durationMs {
            parts.append(RunShelfFormatters.duration(duration))
        }
        return parts.joined(separator: " · ")
    }
}
