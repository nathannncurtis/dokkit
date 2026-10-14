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
        case .unknown: "Unknown"
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

    public static func isStale(_ from: Date, now: Date) -> Bool { now.timeIntervalSince(from) > warnAfter }
}

public struct Freshness: Equatable, Sendable {
    public var text: String
    public var isWarning: Bool
    public var detail: String?

    public static func make(madeAt: Date?, hasSnapshot: Bool, problem: String?, now: Date) -> Freshness {
        guard hasSnapshot else { return Freshness(text: "No snapshot yet", isWarning: problem != nil, detail: problem) }
        guard let madeAt else { return Freshness(text: "Snapshot age unknown", isWarning: true, detail: problem) }
        let stale = Age.isStale(madeAt, now: now)
        let late = stale ? "The server, its network or the relay is not delivering." : nil
        return Freshness(
            text: "Snapshot made \(Age.ago(madeAt, now: now))", isWarning: stale,
            detail: [problem, late].compactMap { $0 }.joined(separator: " ").nilIfEmpty)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
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

public struct NotWatchedRow: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var machine: String
    public var kind: String
    public var saw: String?
}

public struct NeedsYouScreen: Equatable, Sendable {
    public struct Section: Identifiable, Equatable, Sendable {
        public var title: String
        public var rows: [IssueRow]
        public var id: String { title }
    }
    public var sections: [Section]
    public var notWatched: [NotWatchedRow]
    public var fine: String?
    public var nothingNeedsYou: Bool
}

public struct Vital: Equatable, Sendable {
    public var label: String
    public var percent: Int
    public var isHot: Bool
}

public struct ServiceRow: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var level: Level
    public var kind: String
    public var version: String?
    public var environment: String?
    public var note: String?
    public var chart: [Double]
}

public struct MachineRow: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var os: String?
    public var level: Level
    public var notice: String?
    public var vitals: [Vital]
    public var nextWindow: String?
    public var services: [ServiceRow]
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
    public var chart: [Double]
    public var job: [[String]]
    public var logs: [LogRow]
}

public enum Screens {
    public static func needsYou(_ s: Snapshot, now: Date) -> NeedsYouScreen {
        let names = serviceNames(s)
        let box = s.inbox
        func rows(_ l: [Issue]?) -> [IssueRow] { (l ?? []).map { issueRow($0, names: names, now: now) } }
        let sections = [
            ("Needs you", rows(box?.needsYou)), ("Soon", rows(box?.soon)), ("Snoozed", rows(box?.snoozed)),
        ].filter { !$0.1.isEmpty }.map { NeedsYouScreen.Section(title: $0.0, rows: $0.1) }
        let notWatched = (box?.notWatched ?? []).map {
            NotWatchedRow(
                id: $0.id ?? UUID().uuidString, name: $0.detail?.label ?? $0.name ?? "Unnamed",
                machine: $0.machine ?? "", kind: $0.kind ?? "", saw: $0.detail?.saw)
        }
        var fine: String?
        if let f = box?.fine, f.services != nil || f.machines != nil {
            fine = [f.services.map { "\($0) service\($0 == 1 ? "" : "s")" }, f.machines.map { "\($0) machine\($0 == 1 ? "" : "s")" }]
                .compactMap { $0 }.joined(separator: " and ") + " fine"
        }
        return NeedsYouScreen(
            sections: sections, notWatched: notWatched, fine: fine,
            nothingNeedsYou: (box?.needsYou ?? []).isEmpty)
    }

    public static func everything(_ s: Snapshot) -> [MachineRow] {
        let top = Dictionary((s.services ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return (s.machines ?? []).map { m in
            let services = (m.services ?? []).map { svc -> ServiceRow in
                let full = top[svc.id] ?? svc
                return ServiceRow(
                    id: svc.id, name: svc.name ?? "Unnamed", level: Level(svc.state ?? full.state), kind: svc.kind ?? full.kind ?? "service",
                    version: svc.version ?? full.version, environment: envTag(svc.environment ?? full.environment),
                    note: svc.note ?? full.note, chart: (full.chart ?? []).compactMap(\.value))
            }.sorted(by: worse)
            let worst = services.map(\.level).max { $0.rank < $1.rank } ?? .ok
            var notice: String?
            if m.down == true {
                notice = "Stopped reporting" + (m.lastSeenAt.map { ", last seen \(shortTime($0))" } ?? "")
            } else if let w = m.plannedDowntime {
                notice = "Planned downtime" + (w.until.map { " until \(shortTime($0))" } ?? "")
            }
            let next = (m.schedules ?? []).compactMap { sc in (sc.next ?? sc.at).map { ($0, sc) } }.min { $0.0 < $1.0 }
            return MachineRow(
                id: m.id, name: m.name ?? "Unnamed", os: m.os, level: m.down == true ? .down : worst, notice: notice,
                vitals: vitals(m.vitals ?? [:]),
                nextWindow: next.map { "Next planned downtime \(shortTime($0.0))" + ($0.1.reason.map { ", \($0)" } ?? "") },
                services: services)
        }.sorted {
            $0.level.rank != $1.level.rank ? $0.level.rank > $1.level.rank : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public static func service(_ s: Snapshot, id: String, now: Date) -> ServiceScreen? {
        let all = (s.services ?? []) + (s.machines ?? []).flatMap { $0.services ?? [] }
        guard let svc = all.first(where: { $0.id == id }) else { return nil }
        let full = (s.services ?? []).first { $0.id == id } ?? svc
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
            chart: (full.chart ?? []).compactMap(\.value),
            job: job.map(jobLines) ?? [],
            logs: ((s.logs ?? [:])[id] ?? []).map {
                LogRow(time: $0.t.map { $0.formatted(date: .omitted, time: .standard) } ?? "--:--:--", level: $0.level ?? "info", message: $0.msg ?? "", isError: $0.level == "error")
            })
    }

    private static func serviceNames(_ s: Snapshot) -> [String: String] {
        var out: [String: String] = [:]
        for svc in (s.machines ?? []).flatMap({ $0.services ?? [] }) + (s.services ?? []) { out[svc.id] = svc.name }
        return out
    }

    static func issueRow(_ i: Issue, names: [String: String], now: Date) -> IssueRow {
        var flags: [String] = []
        if let until = i.snoozedUntil, until > now { flags.append("Snoozed until \(shortTime(until))") }
        if i.acknowledgedAt != nil { flags.append("Seen") }
        if i.alert?.status == "held" { flags.append("Alert held for the night" + (i.alert?.until.map { " until \(shortTime($0))" } ?? "")) }
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

    private static func vitals(_ v: [String: Double]) -> [Vital] {
        func make(_ label: String, _ x: Double) -> Vital { Vital(label: label, percent: Int(x.rounded()), isHot: x >= 90) }
        var out: [Vital] = []
        if let x = v["cpu.percent"] { out.append(make("Processor", x)) }
        if let x = v["memory.used_percent"] { out.append(make("Memory", x)) }
        for (k, x) in v.sorted(by: { $0.key < $1.key }) where k.hasPrefix("disk.used_percent.") {
            out.append(make("Disk " + k.dropFirst("disk.used_percent.".count), x))
        }
        return out
    }

    private static func envTag(_ e: String?) -> String? { e == nil || e == "production" ? nil : e }

    private static func worse(_ a: ServiceRow, _ b: ServiceRow) -> Bool {
        a.level.rank != b.level.rank ? a.level.rank > b.level.rank : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}
