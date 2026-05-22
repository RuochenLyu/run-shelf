import Foundation

enum RunShelfFormatters {
    static func scheduleDateTime(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = timeOnly(date)

        if calendar.isDateInToday(date) {
            return "今天 \(time)"
        }
        if calendar.isDateInTomorrow(date) {
            return "明天 \(time)"
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return dateString(date, format: "M月d日 HH:mm")
        }
        return dateString(date, format: "yyyy年M月d日 HH:mm")
    }

    static func dateTime(_ date: Date) -> String {
        dateString(date, format: "yyyy年M月d日 HH:mm")
    }

    static func dateTimeWithSeconds(_ date: Date) -> String {
        dateString(date, format: "yyyy年M月d日 HH:mm:ss")
    }

    static func timeOnly(_ date: Date) -> String {
        dateString(date, format: "HH:mm")
    }

    static func duration(_ durationMs: Int?) -> String {
        guard let durationMs else { return "-" }
        if durationMs < 1000 {
            return "\(durationMs)毫秒"
        }
        return String(format: "%.2f秒", Double(durationMs) / 1000.0)
    }

    private static func dateString(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
