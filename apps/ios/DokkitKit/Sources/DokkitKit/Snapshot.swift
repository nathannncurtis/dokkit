import Foundation

public struct Snapshot: Codable, Sendable, Equatable {
    public var schema: Int?
    public var server: ServerInfo?
    public var inbox: Inbox?
    public var machines: [Machine]?
    public var services: [Service]?
    public var issues: [Issue]?
    public var jobs: [Job]?
    public var logs: [String: [LogLine]]?

    public static func decode(_ data: Data) throws -> Snapshot {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let date = parseDate(s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "date"))
        }
        return try d.decode(Snapshot.self, from: data)
    }

    public static func parseDate(_ s: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s)) ?? (try? Date.ISO8601FormatStyle().parse(s))
    }
}

public struct ServerInfo: Codable, Sendable, Equatable {
    public var name: String?
    public var version: String?
    public var madeAt: Date?
    public var counter: Int?
    public var leftOut: [String]?
    enum CodingKeys: String, CodingKey { case name, version, madeAt = "made_at", counter, leftOut = "left_out" }
}

public struct Inbox: Codable, Sendable, Equatable {
    public var needsYou: [Issue]?
    public var soon: [Issue]?
    public var snoozed: [Issue]?
    public var notWatched: [NotWatched]?
    public var otherEnvironments: [OtherEnvironment]?
    public var fine: Fine?
    enum CodingKeys: String, CodingKey {
        case needsYou = "needs_you", soon, snoozed, notWatched = "not_watched", otherEnvironments = "other_environments", fine
    }
}

public struct Fine: Codable, Sendable, Equatable {
    public var services: Int?
    public var machines: Int?
}

public struct OtherEnvironment: Codable, Sendable, Equatable {
    public var environment: String?
    public var issues: [Issue]?
}

public struct NotWatched: Codable, Sendable, Equatable {
    public var id: String?
    public var machine: String?
    public var name: String?
    public var kind: String?
    public var detail: Detail?
    public struct Detail: Codable, Sendable, Equatable {
        public var label: String?
        public var saw: String?
    }
}

public struct AlertInfo: Codable, Sendable, Equatable {
    public var status: String?
    public var channel: String?
    public var until: Date?
}

public struct IssueEvent: Codable, Sendable, Equatable {
    public var at: Date?
    public var event: String?
    public var until: Date?
    public var note: String?
    public var by: String?
}

public struct Issue: Codable, Sendable, Equatable {
    public var id: String
    public var shortId: String?
    public var title: String?
    public var service: String?
    public var machine: String?
    public var state: String?
    public var kind: String?
    public var since: Date?
    public var count: Int?
    public var note: String?
    public var soon: Bool?
    public var snoozedUntil: Date?
    public var acknowledgedAt: Date?
    public var closedAt: Date?
    public var alert: AlertInfo?
    public var history: [IssueEvent]?
    enum CodingKeys: String, CodingKey {
        case id, shortId = "short_id", title, service, machine, state, kind, since, count, note, soon
        case snoozedUntil = "snoozed_until", acknowledgedAt = "acknowledged_at", closedAt = "closed_at", alert, history
    }
}

public struct Check: Codable, Sendable, Equatable {
    public var name: String?
    public var type: String?
    public var state: String?
    public var note: String?
    public var checkedAt: Date?
    enum CodingKeys: String, CodingKey { case name, type, state, note, checkedAt = "checked_at" }
}

public struct Chart: Codable, Sendable, Equatable {
    public var metric: String?
    public var values: [Double?]?
}

public struct Service: Codable, Sendable, Equatable {
    public var id: String
    public var machine: String?
    public var name: String?
    public var kind: String?
    public var state: String?
    public var version: String?
    public var environment: String?
    public var note: String?
    public var checks: [Check]?
    public var openIssue: Issue?
    public var chart: Chart?
    enum CodingKeys: String, CodingKey {
        case id, machine, name, kind, state, version, environment, note, checks, openIssue = "open_issue", chart
    }
}

public struct Window: Codable, Sendable, Equatable {
    public var until: Date?
    public var reason: String?
}

public struct Schedule: Codable, Sendable, Equatable {
    public var id: String?
    public var reason: String?
    public var time: String?
    public var next: Date?
    public var at: Date?
    public var days: [Int]?
    public var repeats: String?
    public var forSeconds: Int?
    enum CodingKeys: String, CodingKey { case id, reason, time, next, at, days, repeats = "repeat", forSeconds = "for_seconds" }
}

public struct Machine: Codable, Sendable, Equatable {
    public var id: String
    public var name: String?
    public var os: String?
    public var kind: String?
    public var down: Bool?
    public var lastSeenAt: Date?
    public var vitals: [String: Double]?
    public var plannedDowntime: Window?
    public var schedules: [Schedule]?
    public var services: [Service]?
    public var needsALook: Int?
    public var lastDay: [String]?
    enum CodingKeys: String, CodingKey {
        case id, name, os, kind, down, lastSeenAt = "last_seen_at", vitals, plannedDowntime = "planned_downtime"
        case schedules, services, needsALook = "needs_a_look", lastDay = "last_day"
    }
}

public struct JobRun: Codable, Sendable, Equatable {
    public var run: String?
    public var result: String?
    public var startedAt: Date?
    public var finishedAt: Date?
    public var durationMs: Int?
    public var exitCode: Int?
    public var done: Double?
    public var total: Double?
    enum CodingKeys: String, CodingKey {
        case run, result, startedAt = "started_at", finishedAt = "finished_at", durationMs = "duration_ms", exitCode = "exit_code", done, total
    }
}

public struct Job: Codable, Sendable, Equatable {
    public var id: String
    public var machine: String?
    public var name: String?
    public var state: String?
    public var schedule: String?
    public var nextExpected: Date?
    public var lastGoodRun: Date?
    public var lastRun: JobRun?
    enum CodingKeys: String, CodingKey {
        case id, machine, name, state, schedule, nextExpected = "next_expected", lastGoodRun = "last_good_run", lastRun = "last_run"
    }
}

public struct LogLine: Codable, Sendable, Equatable {
    public var msg: String?
    public var level: String?
    public var t: Date?
}
