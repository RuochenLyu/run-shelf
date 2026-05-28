import SwiftUI

struct LogView: View {
    @ObservedObject var store: TaskStore
    var task: RunShelfTask

    var body: some View {
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
        let stdout = store.logText(for: task, run: run, kind: .stdout)
            .trimmingCharacters(in: .newlines)
        let stderr = store.logText(for: task, run: run, kind: .stderr)
            .trimmingCharacters(in: .newlines)

        if stdout.isEmpty && stderr.isEmpty {
            VStack {
                Spacer()
                Text("没有输出")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !stdout.isEmpty {
                        Text(stdout)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !stderr.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("标准错误", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)

                            Text(stderr)
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
        }
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
        task.runs.sorted { $0.startedAt > $1.startedAt }
    }

    private var effectiveRun: RunRecord? {
        if let id = store.selectedRunID,
           let run = task.runs.first(where: { $0.runId == id }) {
            return run
        }
        return task.latestRun
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { effectiveRun?.runId },
            set: { store.selectedRunID = $0 }
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
