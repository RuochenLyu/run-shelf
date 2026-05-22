import AppKit
import SwiftUI

struct TaskDetailView: View {
    @ObservedObject var store: TaskStore
    let taskID: String

    @State private var selectedRunID: String?
    @State private var selectedLogKind: RunLogKind = .combined

    var body: some View {
        if let task = store.task(withID: taskID) {
            VStack(spacing: 0) {
                header(for: task)

                Divider()

                TabView {
                    VStack(spacing: 0) {
                        ScriptToolbarView(script: scriptBinding)
                        Divider()
                        ShellScriptEditor(text: scriptBinding)
                    }
                        .tabItem { Label("脚本", systemImage: "chevron.left.forwardslash.chevron.right") }

                    TextEditor(text: notesBinding)
                        .font(.body)
                        .padding(8)
                        .tabItem { Label("备注", systemImage: "note.text") }

                    LogView(
                        store: store,
                        task: task,
                        selectedRunID: selectedRunID,
                        selectedLogKind: $selectedLogKind
                    )
                    .tabItem { Label("日志", systemImage: "doc.text") }
                }
            }
            .onAppear {
                selectedRunID = selectedRunID ?? task.latestRun?.runId
            }
            .onChange(of: task.runs) { runs in
                if selectedRunID == nil || !runs.contains(where: { $0.runId == selectedRunID }) {
                    selectedRunID = task.latestRun?.runId
                }
            }
        } else {
            EmptyStateView(title: "任务不存在", systemImage: "exclamationmark.triangle", description: nil)
        }
    }

    private func header(for task: RunShelfTask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(displayName(for: task))
                    .font(.system(size: 30, weight: .semibold))

                if task.isDirty {
                    Text("未保存")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }

            Text(descriptionText(for: task))
                .font(.body)
                .foregroundStyle(.secondary)

            let risks = DangerousCommandScanner.scan(task.script)
            if !risks.isEmpty {
                CommandRiskWarningView(risks: risks)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func displayName(for task: RunShelfTask) -> String {
        let name = task.manifest.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "未命名任务" : name
    }

    private func descriptionText(for task: RunShelfTask) -> String {
        let description = task.manifest.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? "未添加说明" : description
    }

    private var scriptBinding: Binding<String> {
        Binding(
            get: { store.task(withID: taskID)?.script ?? "" },
            set: { value in
                store.updateTask(id: taskID) { task in
                    task.script = value
                }
            }
        )
    }

    private var notesBinding: Binding<String> {
        Binding(
            get: { store.task(withID: taskID)?.notes ?? "" },
            set: { value in
                store.updateTask(id: taskID) { task in
                    task.notes = value
                }
            }
        )
    }
}

struct TaskStatusBadge: View {
    @ObservedObject var store: TaskStore
    var task: RunShelfTask

    var body: some View {
        if store.runningTaskIDs.contains(task.id) {
            StatusBadge(text: "运行中", color: .blue)
        } else if let latestRun = task.latestRun {
            StatusBadge(text: latestRun.status.displayName, color: latestRun.status.badgeColor)
        } else if task.manifest.enabled {
            StatusBadge(text: "已启用", color: .green)
        } else {
            StatusBadge(text: "已停用", color: .secondary)
        }
    }
}

private struct ScriptToolbarView: View {
    @Binding var script: String

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Button("严格模式") {
                    insertSnippet("""
                    set -euo pipefail
                    """)
                }
                Button("进入项目目录") {
                    insertSnippet("""
                    cd "$HOME/Projects/my-project"
                    """)
                }
                Button("Homebrew PATH") {
                    insertSnippet("""
                    export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
                    """)
                }
                Button("Python venv") {
                    insertSnippet("""
                    source .venv/bin/activate
                    """)
                }
            } label: {
                Label("插入片段", systemImage: "text.badge.plus")
            }

            Button {
                chooseDirectoryAndInsertCD()
            } label: {
                Label("插入 cd", systemImage: "folder.badge.plus")
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func chooseDirectoryAndInsertCD() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "插入"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        insertSnippet("cd \(shellDoubleQuoted(url.path))")
    }

    private func insertSnippet(_ snippet: String) {
        let trimmed = snippet.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return }
        if script.isEmpty || script.hasSuffix("\n") {
            script += trimmed + "\n"
        } else {
            script += "\n" + trimmed + "\n"
        }
    }

    private func shellDoubleQuoted(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
        return "\"\(escaped)\""
    }
}

enum ScheduleMode: String, CaseIterable, Identifiable {
    case daily
    case weekly
    case monthly
    case interval
    case advanced

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .daily: return "每天"
        case .weekly: return "每周"
        case .monthly: return "每月"
        case .interval: return "间隔"
        case .advanced: return "高级"
        }
    }
}

enum ScheduleIntervalUnit: String, CaseIterable, Identifiable {
    case minutes
    case hours

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .minutes: return "分钟"
        case .hours: return "小时"
        }
    }
}

enum ScheduleDraftError: LocalizedError {
    case invalidTime(String)
    case dailyTimesNeedSameMinute

    var errorDescription: String? {
        switch self {
        case .invalidTime(let text):
            return "`\(text)` 不是有效的 HH:mm 时间。"
        case .dailyTimesNeedSameMinute:
            return "每天多次运行目前要求分钟相同，例如 08:00, 12:00, 18:00。"
        }
    }
}

struct ScheduleEditorView: View {
    @Binding var expression: String

    @State private var mode: ScheduleMode = .advanced
    @State private var dailyTimes = "09:00"
    @State private var weeklyWeekday = 1
    @State private var monthlyDay = 1
    @State private var timeText = "09:00"
    @State private var intervalUnit: ScheduleIntervalUnit = .minutes
    @State private var intervalValue = 15
    @State private var validationMessage: String?

    private let weekdays = [
        (0, "周日"),
        (1, "周一"),
        (2, "周二"),
        (3, "周三"),
        (4, "周四"),
        (5, "周五"),
        (6, "周六")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("计划模式", selection: $mode) {
                ForEach(ScheduleMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if mode != .advanced {
                simpleControls
            }

            HStack(spacing: 8) {
                Text("Cron")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("0 9 * * *", text: $expression)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)

                if mode != .advanced {
                    Button {
                        applySimpleSchedule()
                    } label: {
                        Label("应用", systemImage: "checkmark")
                    }
                }
            }

            Link("crontab.guru", destination: URL(string: "https://crontab.guru/")!)
                .font(.caption)

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onAppear {
            syncDraft(from: expression)
        }
        .onChange(of: intervalUnit) { _ in
            if !validIntervals.contains(intervalValue), let first = validIntervals.first {
                intervalValue = first
            }
        }
    }

    @ViewBuilder
    private var simpleControls: some View {
        switch mode {
        case .daily:
            HStack {
                TextField("08:00, 12:00, 18:00", text: $dailyTimes)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 190)
            }
        case .weekly:
            HStack {
                Picker("星期", selection: $weeklyWeekday) {
                    ForEach(weekdays, id: \.0) { value, name in
                        Text(name).tag(value)
                    }
                }
                .frame(width: 110)

                TextField("09:00", text: $timeText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
            }
        case .monthly:
            HStack {
                Stepper(value: $monthlyDay, in: 1...31) {
                    Text("每月 \(monthlyDay) 日")
                }
                .frame(width: 120)
                TextField("09:00", text: $timeText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
            }
        case .interval:
            HStack {
                Picker("单位", selection: $intervalUnit) {
                    ForEach(ScheduleIntervalUnit.allCases) { unit in
                        Text(unit.displayName).tag(unit)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 140)

                Picker("间隔", selection: $intervalValue) {
                    ForEach(validIntervals, id: \.self) { value in
                        Text("\(value)").tag(value)
                    }
                }
                .frame(width: 74)
            }
        case .advanced:
            EmptyView()
        }
    }

    private var validIntervals: [Int] {
        switch intervalUnit {
        case .minutes:
            return [1, 2, 3, 4, 5, 6, 10, 12, 15, 20, 30]
        case .hours:
            return [1, 2, 3, 4, 6, 8, 12]
        }
    }

    private func applySimpleSchedule() {
        do {
            expression = try generatedCronExpression()
            validationMessage = nil
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private func generatedCronExpression() throws -> String {
        switch mode {
        case .daily:
            let times = try parseDailyTimes(dailyTimes)
            let minute = times[0].minute
            let hours = Set(times.map { $0.hour }).sorted().map(String.init).joined(separator: ",")
            return "\(minute) \(hours) * * *"
        case .weekly:
            let time = try parseTime(timeText)
            return "\(time.minute) \(time.hour) * * \(weeklyWeekday)"
        case .monthly:
            let time = try parseTime(timeText)
            return "\(time.minute) \(time.hour) \(monthlyDay) * *"
        case .interval:
            switch intervalUnit {
            case .minutes:
                return "*/\(intervalValue) * * * *"
            case .hours:
                return "0 */\(intervalValue) * * *"
            }
        case .advanced:
            return expression
        }
    }

    private func parseDailyTimes(_ text: String) throws -> [(hour: Int, minute: Int)] {
        let times = try text
            .split(separator: ",")
            .map { try parseTime(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard !times.isEmpty else {
            throw ScheduleDraftError.invalidTime(text)
        }
        guard let minute = times.first?.minute, times.allSatisfy({ $0.minute == minute }) else {
            throw ScheduleDraftError.dailyTimesNeedSameMinute
        }
        return times
    }

    private func parseTime(_ text: String) throws -> (hour: Int, minute: Int) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard
            parts.count == 2,
            let hour = Int(parts[0]),
            let minute = Int(parts[1]),
            (0...23).contains(hour),
            (0...59).contains(minute)
        else {
            throw ScheduleDraftError.invalidTime(text)
        }
        return (hour, minute)
    }

    private func syncDraft(from expression: String) {
        guard let schedule = try? CronSchedule.parse(expression) else {
            mode = .advanced
            return
        }

        if schedule.daysOfMonth.isWildcard,
           schedule.months.isWildcard,
           schedule.daysOfWeek.isWildcard,
           schedule.minutes.values.count == 1,
           !schedule.hours.isWildcard,
           let minute = schedule.minutes.values.first {
            mode = .daily
            dailyTimes = schedule.hours.values.sorted().map { hour in
                String(format: "%02d:%02d", hour, minute)
            }.joined(separator: ", ")
            return
        }

        if schedule.daysOfMonth.isWildcard,
           schedule.months.isWildcard,
           !schedule.daysOfWeek.isWildcard,
           schedule.daysOfWeek.values.count == 1,
           schedule.minutes.values.count == 1,
           schedule.hours.values.count == 1,
           let weekday = schedule.daysOfWeek.values.first,
           let minute = schedule.minutes.values.first,
           let hour = schedule.hours.values.first {
            mode = .weekly
            weeklyWeekday = weekday
            timeText = String(format: "%02d:%02d", hour, minute)
            return
        }

        if !schedule.daysOfMonth.isWildcard,
           schedule.daysOfMonth.values.count == 1,
           schedule.months.isWildcard,
           schedule.daysOfWeek.isWildcard,
           schedule.minutes.values.count == 1,
           schedule.hours.values.count == 1,
           let day = schedule.daysOfMonth.values.first,
           let minute = schedule.minutes.values.first,
           let hour = schedule.hours.values.first {
            mode = .monthly
            monthlyDay = day
            timeText = String(format: "%02d:%02d", hour, minute)
            return
        }

        if let minuteStep = stepValue(from: expression, prefix: "*/", suffix: " * * * *", allowed: [1, 2, 3, 4, 5, 6, 10, 12, 15, 20, 30]) {
            mode = .interval
            intervalUnit = .minutes
            intervalValue = minuteStep
            return
        }

        if let hourStep = stepValue(from: expression, prefix: "0 */", suffix: " * * *", allowed: [1, 2, 3, 4, 6, 8, 12]) {
            mode = .interval
            intervalUnit = .hours
            intervalValue = hourStep
            return
        }

        mode = .advanced
    }

    private func stepValue(from expression: String, prefix: String, suffix: String, allowed: [Int]) -> Int? {
        guard expression.hasPrefix(prefix), expression.hasSuffix(suffix) else { return nil }
        let start = expression.index(expression.startIndex, offsetBy: prefix.count)
        let end = expression.index(expression.endIndex, offsetBy: -suffix.count)
        let value = Int(expression[start..<end])
        guard let value, allowed.contains(value) else { return nil }
        return value
    }
}

struct CronPreviewView: View {
    var expression: String

    var body: some View {
        switch CronSchedule.validate(expression) {
        case .success(let schedule):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Label(schedule.summary, systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                    Text("下次运行")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(nextRuns(for: schedule), id: \.self) { date in
                            Text(RunShelfFormatters.scheduleDateTime(date))
                                .font(.caption)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
        case .failure(let error):
            Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .font(.caption)
        }
    }

    private func nextRuns(for schedule: CronSchedule) -> [Date] {
        (try? schedule.nextRuns(count: 5)) ?? []
    }
}

private struct CommandRiskWarningView: View {
    var risks: [CommandRisk]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("脚本包含需要复核的命令", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption.weight(.semibold))

            ForEach(risks) { risk in
                Text(risk.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct LogView: View {
    @ObservedObject var store: TaskStore
    var task: RunShelfTask
    var selectedRunID: String?
    @Binding var selectedLogKind: RunLogKind

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("日志", selection: $selectedLogKind) {
                    ForEach(RunLogKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)

                Spacer()

                Button {
                    store.openTaskDirectory(id: task.id)
                } label: {
                    Label("打开目录", systemImage: "folder")
                }
            }
            .padding(12)

            Divider()

            ScrollView {
                Text(logText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
    }

    private var selectedRun: RunRecord? {
        if let selectedRunID, let run = task.runs.first(where: { $0.runId == selectedRunID }) {
            return run
        }
        return task.latestRun
    }

    private var logText: String {
        store.logText(for: task, run: selectedRun, kind: selectedLogKind)
    }
}
