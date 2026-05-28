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

    /// 相对未来时间,例如 "3 小时后" / "10 分钟后" / "现在"。
    static func relativeFuture(_ date: Date, now: Date = Date()) -> String {
        let interval = date.timeIntervalSince(now)
        if interval < 60 {
            return "现在"
        }
        if interval < 3600 {
            return "\(Int(interval / 60)) 分钟后"
        }
        if interval < 86400 {
            return "\(Int(interval / 3600)) 小时后"
        }
        let days = Int(interval / 86400)
        if days < 30 {
            return "\(days) 天后"
        }
        if days < 365 {
            return "\(days / 30) 个月后"
        }
        return "\(days / 365) 年后"
    }

    /// 人类可读的字节大小，例如 "1.0 MB" / "320 KB" / "12 B"。
    static func byteSize(_ bytes: Int64) -> String {
        byteCountFormatter.string(fromByteCount: bytes)
    }

    private static func dateString(_ date: Date, format: String) -> String {
        dateFormatter(format: format).string(from: date)
    }

    private static var byteCountFormatter: ByteCountFormatter {
        let key = "RunShelfFormatters.byteCountFormatter"
        if let formatter = Thread.current.threadDictionary[key] as? ByteCountFormatter {
            return formatter
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        Thread.current.threadDictionary[key] = formatter
        return formatter
    }

    private static func dateFormatter(format: String) -> DateFormatter {
        let key = "RunShelfFormatters.dateFormatter.\(format)"
        if let formatter = Thread.current.threadDictionary[key] as? DateFormatter {
            formatter.timeZone = .current
            return formatter
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = format
        Thread.current.threadDictionary[key] = formatter
        return formatter
    }
}
