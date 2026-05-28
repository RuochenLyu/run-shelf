import SwiftUI

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
            return "「\(text)」不是合法的 HH:mm 时间"
        case .dailyTimesNeedSameMinute:
            return "一天多次运行时，每个时间的分钟数得一样，比如 08:00, 12:00, 18:00"
        }
    }
}

struct ScheduleEditorView: View {
    @Binding var expression: String
    var initialMode: ScheduleMode? = nil
    var onModeChange: ((ScheduleMode) -> Void)? = nil
    var onValidityChange: (Bool) -> Void = { _ in }

    @State private var mode: ScheduleMode = .advanced
    @State private var dailyTimes = "09:00"
    @State private var weeklyWeekday = 1
    @State private var monthlyDay = 1
    @State private var timeText = "09:00"
    @State private var intervalUnit: ScheduleIntervalUnit = .minutes
    @State private var intervalValue = 15
    @State private var validationMessage: String?
    @State private var lastEcho: String?
    @State private var hasInitialized = false

    private let weekdays: [(Int, String)] = [
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
            ScheduleModePicker(selection: userPickedMode)

            modeFields

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onAppear {
            guard !hasInitialized else { return }
            hasInitialized = true
            if let pinned = initialMode {
                // 用户之前选过 tab，按用户的选择来；只读表达式同步子字段，不再推断 tab
                // 这里是程序性赋值，不走 userPickedMode 的 setter，所以不会触发 applyIfSimple
                mode = pinned
                loadSubFields(from: expression)
            } else {
                // 没有保存过偏好，按表达式推断一次 tab
                syncDraft(from: expression)
            }
        }
        .onChange(of: expression) { _, newValue in
            if let echo = lastEcho, echo == newValue {
                lastEcho = nil
                return
            }
            // 表达式外部变化（例如切到别的任务）：
            //  - 用户对当前任务有 pinned mode 时尊重它，只重新同步子字段
            //  - 否则推断 mode
            if initialMode != nil {
                loadSubFields(from: newValue)
            } else {
                syncDraft(from: newValue)
            }
        }
    }

    @ViewBuilder
    private var modeFields: some View {
        switch mode {
        case .daily:
            ScheduleEditorRow("时间") {
                TextField("", text: userDailyTimes, prompt: Text("09:00, 12:00, 18:00"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity)
            }
        case .weekly:
            ScheduleEditorRow("星期") {
                Picker("", selection: userWeeklyWeekday) {
                    ForEach(weekdays, id: \.0) { value, name in
                        Text(name).tag(value)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            ScheduleEditorRow("时间") {
                TextField("", text: userTimeText, prompt: Text("09:00"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity)
            }
        case .monthly:
            ScheduleEditorRow("日期") {
                Picker("", selection: userMonthlyDay) {
                    ForEach(1...31, id: \.self) { day in
                        Text("\(day) 日").tag(day)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            ScheduleEditorRow("时间") {
                TextField("", text: userTimeText, prompt: Text("09:00"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity)
            }
        case .interval:
            ScheduleEditorRow("每隔") {
                HStack(spacing: 8) {
                    Picker("", selection: userIntervalValue) {
                        ForEach(validIntervals, id: \.self) { value in
                            Text("\(value)").tag(value)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()

                    Picker("", selection: userIntervalUnit) {
                        ForEach(ScheduleIntervalUnit.allCases) { unit in
                            Text(unit.displayName).tag(unit)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        case .advanced:
            ScheduleEditorRow("表达式") {
                TextField("", text: advancedExpressionBinding, prompt: Text("0 9 * * *"))
                    .font(.system(.callout, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // Picker 专用 binding：只有用户主动点 tab 才走 setter，
    // 这样 applyIfSimple 和 onModeChange 不会在 onAppear / syncDraft 这种程序性 mode 赋值时被触发。
    private var userPickedMode: Binding<ScheduleMode> {
        Binding(
            get: { mode },
            set: { newMode in
                guard newMode != mode else { return }
                mode = newMode
                applyIfSimple()
                onModeChange?(newMode)
            }
        )
    }

    private var userDailyTimes: Binding<String> {
        Binding(
            get: { dailyTimes },
            set: { newValue in
                guard dailyTimes != newValue else { return }
                dailyTimes = newValue
                applyIfSimple()
            }
        )
    }

    private var userTimeText: Binding<String> {
        Binding(
            get: { timeText },
            set: { newValue in
                guard timeText != newValue else { return }
                timeText = newValue
                applyIfSimple()
            }
        )
    }

    private var userWeeklyWeekday: Binding<Int> {
        Binding(
            get: { weeklyWeekday },
            set: { newValue in
                guard weeklyWeekday != newValue else { return }
                weeklyWeekday = newValue
                applyIfSimple()
            }
        )
    }

    private var userMonthlyDay: Binding<Int> {
        Binding(
            get: { monthlyDay },
            set: { newValue in
                guard monthlyDay != newValue else { return }
                monthlyDay = newValue
                applyIfSimple()
            }
        )
    }

    private var userIntervalValue: Binding<Int> {
        Binding(
            get: { intervalValue },
            set: { newValue in
                guard intervalValue != newValue else { return }
                intervalValue = newValue
                applyIfSimple()
            }
        )
    }

    private var userIntervalUnit: Binding<ScheduleIntervalUnit> {
        Binding(
            get: { intervalUnit },
            set: { newValue in
                guard intervalUnit != newValue else { return }
                intervalUnit = newValue
                if !validIntervals.contains(intervalValue), let first = validIntervals.first {
                    intervalValue = first
                }
                applyIfSimple()
            }
        )
    }

    private var advancedExpressionBinding: Binding<String> {
        Binding(
            get: { expression },
            set: { newValue in
                if expression != newValue {
                    lastEcho = newValue
                    expression = newValue
                }
                validateAdvancedExpression(newValue)
            }
        )
    }

    private var validIntervals: [Int] {
        switch intervalUnit {
        case .minutes:
            return [1, 2, 3, 4, 5, 6, 10, 12, 15, 20, 30]
        case .hours:
            return [1, 2, 3, 4, 6, 8, 12]
        }
    }

    private func applyIfSimple() {
        guard mode != .advanced else {
            validateAdvancedExpression(expression)
            return
        }
        do {
            let next = try generatedCronExpression()
            if expression != next {
                lastEcho = next
                expression = next
            }
            validationMessage = nil
            onValidityChange(true)
        } catch {
            validationMessage = error.localizedDescription
            if !expression.isEmpty {
                lastEcho = ""
                expression = ""
            }
            onValidityChange(false)
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

    // 已经知道用户选的 tab 时（pinned mode），只按当前 mode 读子字段，不再推断 mode。
    private func loadSubFields(from expression: String) {
        validationMessage = nil
        if expression.isEmpty { return }

        guard let schedule = try? CronSchedule.parse(expression) else {
            if mode == .advanced { validateAdvancedExpression(expression) }
            return
        }
        onValidityChange(true)

        switch mode {
        case .daily:
            if schedule.minutes.values.count == 1, let minute = schedule.minutes.values.first {
                dailyTimes = schedule.hours.values.sorted()
                    .map { String(format: "%02d:%02d", $0, minute) }
                    .joined(separator: ", ")
            }
        case .weekly:
            if let weekday = schedule.daysOfWeek.values.first,
               let minute = schedule.minutes.values.first,
               let hour = schedule.hours.values.first {
                weeklyWeekday = weekday
                timeText = String(format: "%02d:%02d", hour, minute)
            }
        case .monthly:
            if let day = schedule.daysOfMonth.values.first,
               let minute = schedule.minutes.values.first,
               let hour = schedule.hours.values.first {
                monthlyDay = day
                timeText = String(format: "%02d:%02d", hour, minute)
            }
        case .interval:
            if let m = stepValue(from: expression, prefix: "*/", suffix: " * * * *", allowed: [1,2,3,4,5,6,10,12,15,20,30]) {
                intervalUnit = .minutes
                intervalValue = m
            } else if let h = stepValue(from: expression, prefix: "0 */", suffix: " * * *", allowed: [1,2,3,4,6,8,12]) {
                intervalUnit = .hours
                intervalValue = h
            }
        case .advanced:
            validateAdvancedExpression(expression)
        }
    }

    private func syncDraft(from expression: String) {
        validationMessage = nil

        if expression.isEmpty { return }

        guard let schedule = try? CronSchedule.parse(expression) else {
            mode = .advanced
            validateAdvancedExpression(expression)
            return
        }
        onValidityChange(true)

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

    private func validateAdvancedExpression(_ expression: String) {
        switch CronSchedule.validate(expression) {
        case .success:
            validationMessage = nil
            onValidityChange(true)
        case .failure(let error):
            validationMessage = error.localizedDescription
            onValidityChange(false)
        }
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
    var nextRunCount = 3

    var body: some View {
        switch CronSchedule.validate(expression) {
        case .success(let schedule):
            ScheduleEditorRow("接下来") {
                VStack(alignment: .trailing, spacing: 2) {
                    let runs = nextRuns(for: schedule)
                    if runs.isEmpty {
                        Text("暂无")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(runs, id: \.self) { date in
                            Text(RunShelfFormatters.scheduleDateTime(date))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        case .failure:
            EmptyView()
        }
    }

    private func nextRuns(for schedule: CronSchedule) -> [Date] {
        (try? schedule.nextRuns(count: nextRunCount)) ?? []
    }
}

private struct ScheduleModePicker: View {
    @Binding var selection: ScheduleMode

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(ScheduleMode.allCases) { item in
                Text(item.displayName).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: .infinity)
    }
}

struct ScheduleEditorRow<Content: View>: View {
    private let title: String
    private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        LabeledContent {
            content
        } label: {
            Text(title)
        }
    }
}
