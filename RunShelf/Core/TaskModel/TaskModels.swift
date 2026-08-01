import Foundation

enum TaskRunStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case running
    case success
    case failed
    case skipped
    case timeout
    case cancelled
    case stale

    var displayName: String {
        switch self {
        case .pending: return "等待中"
        case .running: return "运行中"
        case .success: return "成功"
        case .failed: return "失败"
        case .skipped: return "跳过"
        case .timeout: return "超时"
        case .cancelled: return "已取消"
        case .stale: return "已过期"
        }
    }
}

enum RunTrigger: String, Codable, Sendable {
    case scheduled
    case manual

    var displayName: String {
        switch self {
        case .scheduled: return "定时"
        case .manual: return "手动"
        }
    }
}

struct TaskSchedule: Codable, Equatable, Sendable {
    var type: String
    var expression: String
    var timezone: String

    init(type: String, expression: String, timezone: String) {
        self.type = type
        self.expression = expression
        self.timezone = timezone
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case type
        case expression
        case timezone
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownKeys(in: decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        expression = try container.decode(String.self, forKey: .expression)
        timezone = try container.decode(String.self, forKey: .timezone)
    }

    static let defaultDaily = TaskSchedule(
        type: "cron",
        expression: "0 9 * * *",
        timezone: "local"
    )
}

extension TaskSchedule {
    var validationError: CronParseError? {
        guard type == "cron" else {
            return CronParseError.invalidToken("类型", type)
        }

        guard timezone == "local" else {
            return CronParseError.invalidToken("时区", timezone)
        }

        if case .failure(let error) = CronSchedule.validate(expression) {
            return error
        }
        return nil
    }

    var isValid: Bool {
        validationError == nil
    }
}

private struct ArbitraryCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
    }
}

func rejectUnknownKeys(in decoder: Decoder, allowed: Set<String>) throws {
    let container = try decoder.container(keyedBy: ArbitraryCodingKey.self)
    if let unknown = container.allKeys.map(\.stringValue).filter({ !allowed.contains($0) }).sorted().first {
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath + [ArbitraryCodingKey(stringValue: unknown)!],
            debugDescription: "未知字段：\(unknown)"
        ))
    }
}

struct MissedRunPolicy: Codable, Equatable, Sendable {
    var type: String
    var maxDelaySeconds: Int

    static let defaultPolicy = MissedRunPolicy(type: "skipIfLate", maxDelaySeconds: 1800)
}

struct TaskRunnerPolicy: Codable, Equatable, Sendable {
    var concurrency: String
    var timeoutSeconds: Int
    var missedRunPolicy: MissedRunPolicy

    static let defaultPolicy = TaskRunnerPolicy(
        concurrency: "skip",
        timeoutSeconds: 0,
        missedRunPolicy: .defaultPolicy
    )
}

struct NotificationPolicy: Codable, Equatable, Sendable {
    var onFailure: Bool
    var onSuccess: Bool

    static let defaultPolicy = NotificationPolicy(onFailure: true, onSuccess: false)
}

struct RetentionPolicy: Codable, Equatable, Sendable {
    var days: Int
    var maxRuns: Int

    static let defaultPolicy = RetentionPolicy(days: 30, maxRuns: 500)
}

struct TaskManifest: Codable, Identifiable, Equatable, Sendable {
    var schemaVersion: Int
    var id: String
    var slug: String? = nil
    var name: String
    var description: String
    var enabled: Bool
    var createdAt: Date
    var updatedAt: Date
    var schedule: TaskSchedule
    var runner: TaskRunnerPolicy
    var notifications: NotificationPolicy
    var retention: RetentionPolicy

    static func create(
        id: String = UUID().uuidString,
        slug: String? = nil,
        name: String,
        description: String,
        enabled: Bool,
        schedule: TaskSchedule = .defaultDaily,
        retention: RetentionPolicy = RunShelfSettings.defaultRetentionPolicy
    ) -> TaskManifest {
        let now = Date()
        return TaskManifest(
            schemaVersion: 1,
            id: id,
            slug: slug,
            name: name,
            description: description,
            enabled: enabled,
            createdAt: now,
            updatedAt: now,
            schedule: schedule,
            runner: .defaultPolicy,
            notifications: .defaultPolicy,
            retention: retention
        )
    }
}

struct RunRecord: Codable, Identifiable, Equatable, Sendable {
    var runId: String
    var taskId: String
    var trigger: RunTrigger
    var status: TaskRunStatus
    var exitCode: Int?
    var scheduledAt: Date?
    var startedAt: Date
    var endedAt: Date?
    var durationMs: Int?
    var scriptSha256: String
    var stdoutPath: String
    var stderrPath: String
    var message: String?
    var processID: Int32? = nil
    var processGroupID: Int32? = nil

    var id: String { runId }
}

struct RunShelfTask: Identifiable, Equatable, Sendable {
    var manifest: TaskManifest
    var directoryURL: URL
    var script: String
    var notes: String
    var runs: [RunRecord]
    var isDirty: Bool

    var id: String { manifest.id }

    var latestRun: RunRecord? {
        runs.first
    }

    var hasValidSchedule: Bool {
        manifest.schedule.isValid
    }
}
