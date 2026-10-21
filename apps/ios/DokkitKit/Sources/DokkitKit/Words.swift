import Foundation

public enum Tone: Sendable, Equatable { case down, degraded, soon, ok, quiet, brand }

public struct Flag: Equatable, Sendable, Hashable {
    public var text: String
    public var tone: Tone
}

public struct IssueCard: Identifiable, Equatable, Sendable {
    public var id: String
    public var shortId: String
    public var title: String
    public var sentence: String
    public var tone: Tone
    public var word: String
    public var machine: String
    public var count: Int
    public var flags: [Flag]
    public var nextStep: String
    public var serviceID: String?
}

/// Calm in Ember wording: each issue in one sentence with one next step.
public enum Words {
    public static func tone(_ level: Level) -> Tone {
        switch level {
        case .ok: .ok
        case .degraded: .degraded
        case .down: .down
        case .unknown, .unwatched, .other: .quiet
        }
    }

    static func snoozed(_ i: Issue, _ now: Date) -> Bool { (i.snoozedUntil ?? .distantPast) > now }

    public static func tone(_ i: Issue, now: Date) -> Tone {
        if snoozed(i, now) { return .quiet }
        if i.soon == true { return .soon }
        return tone(Level(i.state))
    }

    public static func word(_ i: Issue, now: Date) -> String {
        if snoozed(i, now) { return "Snoozed" }
        if i.soon == true { return "Coming up" }
        return Level(i.state).word
    }

    public static func sentence(_ i: Issue, names: [String: String], now: Date) -> String {
        let svc = i.service.flatMap { names[$0] } ?? "it"
        let at = i.machine.flatMap { $0.isEmpty ? nil : " on \($0)" } ?? ""
        let since = i.since.map { Age.ago($0, now: now) }
        if let until = i.snoozedUntil, until > now {
            return "Snoozed until \(until.formatted(date: .omitted, time: .shortened)). It comes back then if it is still wrong."
        }
        if i.soon == true { return "Nothing is broken. Plan for it when it suits you." }
        if Level(i.state) == .down { return "Something is wrong with \(svc)\(at)" + (since.map { " since \($0)." } ?? ".") }
        return "Working, but not as it should: \(svc)\(at)" + (since.map { ", since \($0)." } ?? ".")
    }

    // The phone cannot change anything, so the one next step always opens something on the phone.
    public static func nextStep(_ i: Issue) -> String {
        switch i.kind {
        case "job": "See the last run"
        case "threshold", "forecast": "Look at the disk"
        case "expiry": "See the certificate"
        default: "Look into it"
        }
    }

    public static func flags(_ i: Issue, now: Date) -> [Flag] {
        var out: [Flag] = []
        if let until = i.snoozedUntil, until > now { out.append(Flag(text: "Snoozed until \(shortTime(until))", tone: .quiet)) }
        if i.acknowledgedAt != nil { out.append(Flag(text: "Seen", tone: .ok)) }
        if i.alert?.status == "held" {
            out.append(Flag(text: "Alert held for the night" + (i.alert?.until.map { " until " + shortTime($0) } ?? ""), tone: .soon))
        }
        return out
    }

    public static func card(_ i: Issue, names: [String: String], now: Date) -> IssueCard {
        IssueCard(
            id: i.id, shortId: i.shortId ?? "", title: i.title ?? "Untitled", sentence: sentence(i, names: names, now: now),
            tone: tone(i, now: now), word: word(i, now: now), machine: i.machine ?? "", count: i.count ?? 1,
            flags: flags(i, now: now), nextStep: nextStep(i), serviceID: i.service)
    }

    public static func greeting(_ now: Date) -> String {
        let h = Calendar.current.component(.hour, from: now)
        return h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
    }

    public static func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
}
