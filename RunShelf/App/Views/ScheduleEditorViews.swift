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
            return "`\(text)` 不是有效的 HH:mm 时间。"
        case .dailyTimesNeedSameMinute:
            return "每天多次运行目前要求分钟相同，例如 08:00, 12:00, 18:00。"
        }
    }
}

struct ScheduleEditorView: View {
    @Binding var expression: String
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

    private let labelWidth: CGFloat = 56

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
        VStack(alignment: .leading, spacing: 12) {
            ScheduleModeSwitcher(selection: $mode)
                .onChange(of: mode) { _ in
                    applyIfSimple()
                }

            settingsGroup {
                if mode != .advanced {
                    simpleControls
                } else {
                    advancedField
                }
            }

            if let validationMessage {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Spacer()
                        .frame(width: labelWidth)
                    Label(validationMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .onAppear { syncDraft(from: expression) }
        .onChange(of: expression) { newValue in
            // Skip if this change was just our own write
            if let echo = lastEcho, echo == newValue {
                lastEcho = nil
                return
            }
            syncDraft(from: newValue)
        }
        .onChange(of: intervalUnit) { _ in
            if !validIntervals.contains(intervalValue), let first = validIntervals.first {
                intervalValue = first
            }
            applyIfSimple()
        }
        .onChange(of: intervalValue) { _ in applyIfSimple() }
        .onChange(of: weeklyWeekday) { _ in applyIfSimple() }
        .onChange(of: monthlyDay) { _ in applyIfSimple() }
        .onChange(of: dailyTimes) { _ in applyIfSimple() }
        .onChange(of: timeText) { _ in applyIfSimple() }
    }

    @ViewBuilder
    private var simpleControls: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch mode {
            case .daily:
                fieldRow("时间") {
                    TextField("时间", text: $dailyTimes, prompt: Text("09:00, 12:00, 18:00"))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                }
            case .weekly:
                fieldRow("星期") {
                    Picker("星期", selection: $weeklyWeekday) {
                        ForEach(weekdays, id: \.0) { value, name in
                            Text(name).tag(value)
                        }
                    }
                    .controlSize(.small)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                SettingsDivider()
                fieldRow("时间") {
                    TextField("时间", text: $timeText, prompt: Text("09:00"))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                }
            case .monthly:
                fieldRow("日期") {
                    Stepper(value: $monthlyDay, in: 1...31) {
                        Text("每月 \(monthlyDay) 日")
                    }
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                SettingsDivider()
                fieldRow("时间") {
                    TextField("时间", text: $timeText, prompt: Text("09:00"))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                }
            case .interval:
                fieldRow("间隔") {
                    Picker("每", selection: $intervalValue) {
                        ForEach(validIntervals, id: \.self) { value in
                            Text("\(value)").tag(value)
                        }
                    }
                    .controlSize(.small)
                    .labelsHidden()
                    .frame(width: 82)

                    Picker("单位", selection: $intervalUnit) {
                        ForEach(ScheduleIntervalUnit.allCases) { unit in
                            Text(unit.displayName).tag(unit)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
            case .advanced:
                EmptyView()
            }

            SettingsDivider()
            fieldRow("Cron") {
                Text(simpleCronText)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func fieldRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            content()
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
    }

    private var advancedField: some View {
        VStack(alignment: .leading, spacing: 0) {
            fieldRow("Cron") {
                TextField("Cron", text: advancedExpressionBinding, prompt: Text("0 9 * * *"))
                    .font(.system(.callout, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
            }

            Link("参考 crontab.guru", destination: URL(string: "https://crontab.guru/")!)
                .font(.caption)
                .padding(.leading, labelWidth + 22)
                .padding(.bottom, 10)
        }
    }

    private var simpleCronText: String {
        validationMessage == nil ? expression : "修正输入后生成"
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

    @ViewBuilder
    private func settingsGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
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

    private func syncDraft(from expression: String) {
        validationMessage = nil

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
        onValidityChange(true)
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

private struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 68)
    }
}

private struct ScheduleModeSwitcher: View {
    @Binding var selection: ScheduleMode

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ScheduleMode.allCases) { mode in
                Button {
                    selection = mode
                } label: {
                    Text(mode.displayName)
                        .font(.callout.weight(selection == mode ? .semibold : .regular))
                        .foregroundStyle(selection == mode ? .white : .primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background {
                    if selection == mode {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor)
                    }
                }
            }
        }
        .padding(2)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(nsColor: .separatorColor).opacity(0.3))
        }
    }
}

struct CronPreviewView: View {
    var expression: String
    var nextRunCount = 5

    var body: some View {
        switch CronSchedule.validate(expression) {
        case .success(let schedule):
            VStack(alignment: .leading, spacing: 6) {
                Label(schedule.summary, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)

                Text("接下来 \(nextRunCount) 次")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                ForEach(nextRuns(for: schedule), id: \.self) { date in
                    Text(RunShelfFormatters.scheduleDateTime(date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        case .failure(let error):
            if !expression.isEmpty {
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func nextRuns(for schedule: CronSchedule) -> [Date] {
        (try? schedule.nextRuns(count: nextRunCount)) ?? []
    }
}
