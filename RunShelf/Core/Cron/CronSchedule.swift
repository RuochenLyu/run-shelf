import Foundation

enum CronParseError: LocalizedError, Equatable {
    case wrongFieldCount(Int)
    case emptyField(String)
    case invalidToken(String, String)
    case numberOutOfRange(String, Int, ClosedRange<Int>)
    case invalidRange(String, String)
    case invalidStep(String, String)
    case noFutureRun

    var errorDescription: String? {
        switch self {
        case .wrongFieldCount(let count):
            return "需要 5 段 Cron 表达式，当前为 \(count) 段。"
        case .emptyField(let name):
            return "\(name) 不能为空。"
        case .invalidToken(let name, let token):
            return "\(name) 中的 `\(token)` 无法解析。"
        case .numberOutOfRange(let name, let value, let range):
            return "\(name) 的 \(value) 超出范围 \(range.lowerBound)-\(range.upperBound)。"
        case .invalidRange(let name, let token):
            return "\(name) 中的范围 `\(token)` 无效。"
        case .invalidStep(let name, let token):
            return "\(name) 中的步进 `\(token)` 无效。"
        case .noFutureRun:
            return "未来 5 年内找不到匹配时间。"
        }
    }
}

struct CronField: Equatable {
    var values: Set<Int>
    var isWildcard: Bool
}

struct CronSchedule: Equatable {
    var expression: String
    var minutes: CronField
    var hours: CronField
    var daysOfMonth: CronField
    var months: CronField
    var daysOfWeek: CronField

    static func parse(_ expression: String) throws -> CronSchedule {
        let parts = expression
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)

        guard parts.count == 5 else {
            throw CronParseError.wrongFieldCount(parts.count)
        }

        return CronSchedule(
            expression: expression,
            minutes: try parseField(name: "分钟", text: parts[0], range: 0...59),
            hours: try parseField(name: "小时", text: parts[1], range: 0...23),
            daysOfMonth: try parseField(name: "日期", text: parts[2], range: 1...31),
            months: try parseField(name: "月份", text: parts[3], range: 1...12),
            daysOfWeek: try parseField(name: "星期", text: parts[4], range: 0...7, normalizeSevenToZero: true)
        )
    }

    static func validate(_ expression: String) -> Result<CronSchedule, CronParseError> {
        do {
            return .success(try parse(expression))
        } catch let error as CronParseError {
            return .failure(error)
        } catch {
            return .failure(.invalidToken("表达式", expression))
        }
    }

    func nextRuns(after date: Date = Date(), count: Int = 5, calendar inputCalendar: Calendar = .current) throws -> [Date] {
        var calendar = inputCalendar
        calendar.timeZone = .current

        let start = calendar.dateInterval(of: .minute, for: date)?.end ?? date.addingTimeInterval(60)
        let limit = calendar.date(byAdding: .year, value: 5, to: start) ?? start.addingTimeInterval(60 * 60 * 24 * 366 * 5)
        let results = candidateRuns(after: start, through: limit, limit: count, calendar: calendar)

        if results.isEmpty {
            throw CronParseError.noFutureRun
        }
        return results
    }

    func matchingRuns(after start: Date, through end: Date, limit: Int = 64, calendar inputCalendar: Calendar = .current) -> [Date] {
        guard start < end else { return [] }

        var calendar = inputCalendar
        calendar.timeZone = .current

        let startMinute = calendar.dateInterval(of: .minute, for: start)?.end ?? start.addingTimeInterval(60)
        let endMinute = calendar.dateInterval(of: .minute, for: end)?.start ?? end
        return candidateRuns(after: startMinute, through: endMinute, limit: limit, calendar: calendar)
    }

    func latestMatchingRun(after start: Date, through end: Date, calendar inputCalendar: Calendar = .current) -> Date? {
        guard start < end else { return nil }

        var calendar = inputCalendar
        calendar.timeZone = .current

        let startMinute = calendar.dateInterval(of: .minute, for: start)?.end ?? start.addingTimeInterval(60)
        let endMinute = calendar.dateInterval(of: .minute, for: end)?.start ?? end
        let firstDay = calendar.startOfDay(for: startMinute)
        var cursorDay = calendar.startOfDay(for: endMinute)
        let sortedHours = hours.values.sorted(by: >)
        let sortedMinutes = minutes.values.sorted(by: >)

        while cursorDay >= firstDay {
            if dayMatches(cursorDay, calendar: calendar) {
                for hour in sortedHours {
                    for minute in sortedMinutes {
                        guard let candidate = date(on: cursorDay, hour: hour, minute: minute, calendar: calendar),
                              candidate >= startMinute,
                              candidate <= endMinute
                        else {
                            continue
                        }
                        return candidate
                    }
                }
            }

            guard let previousDay = calendar.date(byAdding: .day, value: -1, to: cursorDay) else {
                break
            }
            cursorDay = previousDay
        }

        return nil
    }

    private func candidateRuns(after start: Date, through limitDate: Date, limit: Int, calendar: Calendar) -> [Date] {
        guard limit > 0 else { return [] }

        let sortedHours = hours.values.sorted()
        let sortedMinutes = minutes.values.sorted()
        var cursorDay = calendar.startOfDay(for: start)
        var results: [Date] = []

        while cursorDay <= limitDate, results.count < limit {
            if dayMatches(cursorDay, calendar: calendar) {
                for hour in sortedHours {
                    for minute in sortedMinutes {
                        guard let candidate = date(on: cursorDay, hour: hour, minute: minute, calendar: calendar) else {
                            continue
                        }
                        guard candidate >= start, candidate <= limitDate else { continue }
                        guard results.last != candidate else { continue }
                        results.append(candidate)
                        if results.count >= limit {
                            return results
                        }
                    }
                }
            }

            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: cursorDay) else {
                break
            }
            cursorDay = nextDay
        }

        return results
    }

    private func date(on day: Date, hour: Int, minute: Int, calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = hour
        components.minute = minute
        components.second = 0

        guard let date = calendar.date(from: components) else {
            return nil
        }

        let actual = calendar.dateComponents([.hour, .minute, .second], from: date)
        guard actual.hour == hour, actual.minute == minute, actual.second == 0 else {
            return nil
        }
        guard calendar.isDate(date, inSameDayAs: day) else {
            return nil
        }
        return date
    }

    func matches(_ date: Date, calendar: Calendar = .current) -> Bool {
        let components = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: date)
        guard
            let minute = components.minute,
            let hour = components.hour,
            let day = components.day,
            let month = components.month,
            let weekday = components.weekday
        else {
            return false
        }

        let cronWeekday = weekday == 1 ? 0 : weekday - 1
        guard minutes.values.contains(minute), hours.values.contains(hour), months.values.contains(month) else {
            return false
        }

        let dayOfMonthMatches = daysOfMonth.values.contains(day)
        let dayOfWeekMatches = daysOfWeek.values.contains(cronWeekday)

        if !daysOfMonth.isWildcard && !daysOfWeek.isWildcard {
            return dayOfMonthMatches || dayOfWeekMatches
        }
        if !daysOfMonth.isWildcard {
            return dayOfMonthMatches
        }
        if !daysOfWeek.isWildcard {
            return dayOfWeekMatches
        }
        return true
    }

    private func dayMatches(_ date: Date, calendar: Calendar) -> Bool {
        let components = calendar.dateComponents([.day, .month, .weekday], from: date)
        guard let day = components.day, let month = components.month, let weekday = components.weekday else {
            return false
        }
        guard months.values.contains(month) else { return false }

        let cronWeekday = weekday == 1 ? 0 : weekday - 1
        let dayOfMonthMatches = daysOfMonth.values.contains(day)
        let dayOfWeekMatches = daysOfWeek.values.contains(cronWeekday)

        if !daysOfMonth.isWildcard && !daysOfWeek.isWildcard {
            return dayOfMonthMatches || dayOfWeekMatches
        }
        if !daysOfMonth.isWildcard {
            return dayOfMonthMatches
        }
        if !daysOfWeek.isWildcard {
            return dayOfWeekMatches
        }
        return true
    }

    var summary: String {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "* * * * *" { return "每分钟" }
        if minutes.isWildcard, hours.isWildcard, daysOfMonth.isWildcard, months.isWildcard, daysOfWeek.isWildcard {
            return "每分钟"
        }
        if daysOfMonth.isWildcard, months.isWildcard, daysOfWeek.isWildcard, minutes.values.count == 1, hours.values.count == 1 {
            return "每天 \(timeText)"
        }
        if daysOfMonth.isWildcard, months.isWildcard, !daysOfWeek.isWildcard, minutes.values.count == 1, hours.values.count == 1 {
            return "每周 \(weekdayText) \(timeText)"
        }
        if !daysOfMonth.isWildcard, months.isWildcard, daysOfWeek.isWildcard, minutes.values.count == 1, hours.values.count == 1 {
            return "每月 \(sorted(daysOfMonth.values).map(String.init).joined(separator: ",")) 日 \(timeText)"
        }
        if hours.isWildcard, daysOfMonth.isWildcard, months.isWildcard, daysOfWeek.isWildcard, let step = evenlySpacedStep(values: minutes.values, range: 0...59) {
            return "每 \(step) 分钟"
        }
        if minutes.values == [0], daysOfMonth.isWildcard, months.isWildcard, daysOfWeek.isWildcard, let step = evenlySpacedStep(values: hours.values, range: 0...23) {
            return "每 \(step) 小时"
        }
        return "高级 Cron 表达式"
    }

    private var timeText: String {
        guard let hour = hours.values.min(), let minute = minutes.values.min() else { return "" }
        return String(format: "%02d:%02d", hour, minute)
    }

    private var weekdayText: String {
        let names = [0: "周日", 1: "周一", 2: "周二", 3: "周三", 4: "周四", 5: "周五", 6: "周六"]
        return sorted(daysOfWeek.values).compactMap { names[$0] }.joined(separator: ",")
    }

    private static func parseField(
        name: String,
        text: String,
        range: ClosedRange<Int>,
        normalizeSevenToZero: Bool = false
    ) throws -> CronField {
        guard !text.isEmpty else { throw CronParseError.emptyField(name) }

        var values = Set<Int>()
        var hasFullWildcardToken = false

        for rawToken in text.split(separator: ",").map(String.init) {
            let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { throw CronParseError.invalidToken(name, rawToken) }

            let expanded = try expandToken(name: name, token: token, range: range)
            if expanded.isWildcard {
                hasFullWildcardToken = true
            }
            for value in expanded.values {
                let normalized = normalizeSevenToZero && value == 7 ? 0 : value
                values.insert(normalized)
            }
        }

        let fullSet = Set(range.map { normalizeSevenToZero && $0 == 7 ? 0 : $0 })
        return CronField(values: values, isWildcard: hasFullWildcardToken && values == fullSet)
    }

    private static func expandToken(name: String, token: String, range: ClosedRange<Int>) throws -> CronField {
        let stepParts = token.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard stepParts.count <= 2 else { throw CronParseError.invalidStep(name, token) }

        let base = stepParts[0]
        let step: Int
        if stepParts.count == 2 {
            guard let parsedStep = Int(stepParts[1]), parsedStep > 0 else {
                throw CronParseError.invalidStep(name, token)
            }
            step = parsedStep
        } else {
            step = 1
        }

        let baseRange: ClosedRange<Int>
        let wildcard: Bool
        if base == "*" {
            baseRange = range
            wildcard = step == 1
        } else if base.contains("-") {
            let bounds = base.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            guard
                bounds.count == 2,
                let lower = Int(bounds[0]),
                let upper = Int(bounds[1]),
                lower <= upper
            else {
                throw CronParseError.invalidRange(name, token)
            }
            try validate(value: lower, name: name, range: range)
            try validate(value: upper, name: name, range: range)
            baseRange = lower...upper
            wildcard = false
        } else if let value = Int(base) {
            try validate(value: value, name: name, range: range)
            baseRange = value...value
            wildcard = false
        } else {
            throw CronParseError.invalidToken(name, token)
        }

        let values = Set(stride(from: baseRange.lowerBound, through: baseRange.upperBound, by: step))
        guard !values.isEmpty else { throw CronParseError.invalidToken(name, token) }
        return CronField(values: values, isWildcard: wildcard)
    }

    private static func validate(value: Int, name: String, range: ClosedRange<Int>) throws {
        guard range.contains(value) else {
            throw CronParseError.numberOutOfRange(name, value, range)
        }
    }

    private func sorted(_ values: Set<Int>) -> [Int] {
        values.sorted()
    }

    private func evenlySpacedStep(values: Set<Int>, range: ClosedRange<Int>) -> Int? {
        let sortedValues = sorted(values)
        guard sortedValues.count > 1, sortedValues.first == range.lowerBound else { return nil }
        let deltas = zip(sortedValues, sortedValues.dropFirst()).map { $1 - $0 }
        guard let firstDelta = deltas.first, deltas.allSatisfy({ $0 == firstDelta }) else { return nil }
        let expected = Set(stride(from: range.lowerBound, through: range.upperBound, by: firstDelta))
        return expected == values ? firstDelta : nil
    }
}
