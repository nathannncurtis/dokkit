import Foundation

public enum Level: Equatable, Hashable, Sendable {
    case ok, degraded, down, unknown, unwatched, other(String)

    public init(_ s: String?) {
        switch s {
        case "ok": self = .ok
        case "degraded": self = .degraded
        case "down": self = .down
        case "unknown", nil: self = .unknown
        case "unwatched", "not_watched": self = .unwatched
        case let s?: self = .other(s)
        }
    }

    public var word: String {
        switch self {
        case .ok: "OK"
        case .degraded: "Degraded"
        case .down: "Down"
        case .unknown: "No signal yet"
        case .unwatched: "Not watched"
        case .other(let s): s.prefix(1).uppercased() + s.dropFirst()
        }
    }

    public var rank: Int {
        switch self {
        case .down: 3
        case .degraded: 2
        case .unknown, .other: 1
        case .ok, .unwatched: 0
        }
    }
}

public enum Age {
    public static let warnAfter: TimeInterval = 300

    public static func seconds(_ from: Date, _ now: Date) -> Int { max(0, Int(now.timeIntervalSince(from))) }

    public static func ago(_ from: Date, now: Date) -> String {
        let s = seconds(from, now)
        switch s {
        case 0..<5: return "just now"
        case 5..<60: return "\(s) seconds ago"
        case 60..<3600: return "\(s / 60) min ago"
        case 3600..<86400: return "\(s / 3600) h ago"
        default: return "\(s / 86400) d ago"
        }
    }

    public static func isStale(_ from: Date, now: Date, late: TimeInterval = warnAfter) -> Bool { now.timeIntervalSince(from) > late }
}

public struct Freshness: Equatable, Sendable {
    public var text: String
    public var isWarning: Bool
    public var detail: String?

    public static func make(madeAt: Date?, hasSnapshot: Bool, problem: String?, now: Date, late: TimeInterval = Age.warnAfter) -> Freshness {
        guard hasSnapshot else { return Freshness(text: "No snapshot yet", isWarning: problem != nil, detail: problem) }
        guard let madeAt else { return Freshness(text: "Snapshot age unknown", isWarning: true, detail: problem) }
        let stale = Age.isStale(madeAt, now: now, late: late)
        let late = stale ? "The server, its network or the relay is not delivering." : nil
        return Freshness(
            text: "Snapshot made \(Age.ago(madeAt, now: now))", isWarning: stale,
            detail: [problem, late].compactMap { $0 }.joined(separator: " ").nilIfEmpty)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

public func leftOutText(_ s: Snapshot) -> String? {
    guard let parts = s.server?.leftOut, !parts.isEmpty else { return nil }
    let names: [String] = parts.map { part in
        switch part {
        case "logs": return "Log lines"
        case "issues": return "Issue histories"
        case "jobs": return "Jobs"
        case "services": return "Service details"
        default: return part.prefix(1).uppercased() + part.dropFirst()
        }
    }
    return names.joined(separator: ", ") + " were left out of this snapshot to keep it small."
}

public func shortTime(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .shortened) }

public struct IssueRow: Identifiable, Equatable, Sendable {
    public var id: String
    public var shortId: String
    public var title: String
    public var level: Level
    public var machine: String
    public var serviceName: String?
    public var serviceID: String?
    public var since: String?
    public var count: String?
    public var note: String?
    public var flags: [String]
}

public struct CheckRow: Equatable, Sendable {
    public var name: String
    public var kind: String?
    public var level: Level
    public var note: String?
    public var checked: String?
}

public struct HistoryRow: Equatable, Sendable {
    public var when: String?
    public var text: String
}

public struct LogRow: Equatable, Sendable {
    public var time: String
    public var level: String
    public var message: String
    public var isError: Bool
    public var text: String { "\(time) \(level.uppercased().padding(toLength: 5, withPad: " ", startingAt: 0)) \(message)" }
}

public struct ServiceScreen: Equatable, Sendable {
    public var id: String
    public var name: String
    public var machine: String?
    public var kind: String?
    public var level: Level
    public var version: String?
    public var environment: String?
    public var note: String?
    public var checks: [CheckRow]
    public var issue: IssueRow?
    public var history: [HistoryRow]
    public var chart: [Double?]
    public var job: [[String]]
    public var logs: [LogRow]
    public var metric: String?
}

public enum Screens {
    public static func service(_ s: Snapshot, id: String, now: Date) -> ServiceScreen? {
        let top: Service? = (s.services ?? []).first { $0.id == id }
        let nested: Service? = (s.machines ?? []).flatMap { $0.services ?? [] }.first { $0.id == id }
        guard let full = top ?? nested else { return nil }
        let names = serviceNames(s)
        let open = full.openIssue ?? (s.issues ?? []).first { $0.service == id && $0.closedAt == nil }
        let detail = (s.issues ?? []).first { $0.id == open?.id } ?? open
        let job = (s.jobs ?? []).first { $0.id == id }
        return ServiceScreen(
            id: id, name: full.name ?? "Unnamed", machine: full.machine, kind: full.kind, level: Level(full.state),
            version: full.version, environment: full.environment, note: full.note,
            checks: (full.checks ?? []).map {
                CheckRow(name: $0.name ?? "check", kind: $0.type, level: Level($0.state), note: $0.note, checked: $0.checkedAt.map { Age.ago($0, now: now) })
            },
            issue: open.map { issueRow($0, names: names, now: now) },
            history: (detail?.history ?? []).map(historyRow),
            chart: full.chart?.values ?? [],
            job: job.map(jobLines) ?? [],
            logs: ((s.logs ?? [:])[id] ?? []).map {
                LogRow(time: $0.t.map { $0.formatted(date: .omitted, time: .standard) } ?? "--:--:--", level: $0.level ?? "info", message: $0.msg ?? "", isError: $0.level == "error")
            },
            metric: full.chart?.metric)
    }

    static func serviceNames(_ s: Snapshot) -> [String: String] {
        var out: [String: String] = [:]
        for m in s.machines ?? [] { for svc in m.services ?? [] { out[svc.id] = svc.name } }
        for svc in s.services ?? [] { out[svc.id] = svc.name }
        return out
    }

    static func issueRow(_ i: Issue, names: [String: String], now: Date) -> IssueRow {
        var flags: [String] = []
        if let until = i.snoozedUntil, until > now { flags.append("Snoozed until \(shortTime(until))") }
        if i.acknowledgedAt != nil { flags.append("Seen") }
        if i.alert?.status == "held" {
            var text = "Alert held for the night"
            if let until = i.alert?.until { text += " until " + shortTime(until) }
            flags.append(text)
        }
        return IssueRow(
            id: i.id, shortId: i.shortId ?? "", title: i.title ?? "Untitled", level: Level(i.state), machine: i.machine ?? "",
            serviceName: i.service.flatMap { names[$0] }, serviceID: i.service,
            since: i.since.map { "Open since \(Age.ago($0, now: now).replacingOccurrences(of: " ago", with: ""))" },
            count: (i.count ?? 1) > 1 ? "\(i.count ?? 1) times" : nil, note: i.note, flags: flags)
    }

    private static func historyRow(_ e: IssueEvent) -> HistoryRow {
        let name = e.event ?? "event"
        var text = name.prefix(1).uppercased() + name.dropFirst()
        if name == "snoozed", let u = e.until { text += " until \(shortTime(u))" }
        if let n = e.note, !n.isEmpty { text += ": \(n)" }
        if let by = e.by { text += " (\(by))" }
        return HistoryRow(when: e.at.map(shortTime), text: text)
    }

    private static func jobLines(_ j: Job) -> [[String]] {
        var out: [[String]] = []
        if let s = j.schedule { out.append(["Schedule", s]) }
        if let r = j.lastRun {
            var v = (r.result ?? "unknown")
            if let c = r.exitCode { v += ", exit code \(c)" }
            if let ms = r.durationMs { v += ", took \(ms / 1000) s" }
            if r.result == "running", let d = r.done, let t = r.total, t > 0 { v += ", \(Int(d / t * 100)) percent" }
            out.append(["Last run", v])
            if let st = r.startedAt { out.append(["Started", shortTime(st)]) }
        }
        if let g = j.lastGoodRun { out.append(["Last good run", shortTime(g)]) }
        if let n = j.nextExpected { out.append(["Next expected", shortTime(n)]) }
        return out
    }
}
