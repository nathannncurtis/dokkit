import Foundation

public struct IssueLine: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var serviceID: String?
}

public enum TopBox: Equatable, Sendable {
    case attention(title: String, lines: [IssueLine], urgent: Bool)
    case fine(headline: String, detail: String)
}

public struct Meter: Equatable, Sendable {
    public var label: String
    public var percent: Int
    public var subject: String?
    public var isHot: Bool
    public var fraction: Double

    public var spoken: String {
        let name: String = subject.map { label + " " + $0 } ?? label
        return name + " " + String(percent) + " percent" + (isHot ? ", high" : "")
    }
}

public struct ServiceLine: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var level: Level
}

public struct MachineCard: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var isHardware: Bool
    public var isDown: Bool
    public var hasTrouble: Bool
    public var mark: Level
    public var word: String?
    public var status: String?
    public var meters: [Meter]
    public var countLine: String
    public var notice: String?
    public var trouble: [ServiceLine]
    public var fine: [ServiceLine]
    public var moreFine: [ServiceLine]
    public var quietLine: String?
    public var summary: String
    public var isEmpty: Bool { trouble.isEmpty && fine.isEmpty && moreFine.isEmpty && quietLine == nil }
}

public struct HomeScreen: Equatable, Sendable {
    public var top: TopBox
    public var snoozedLine: String?
    public var machines: [MachineCard]
    public var groups: [MachineCard]
}

public enum Home {
    public static let hotAbove: Double = 85
    public static let fineShown: Int = 8

    public static func make(_ s: Snapshot, now: Date) -> HomeScreen {
        var hardware: [MachineCard] = []
        var groups: [MachineCard] = []
        for m in s.machines ?? [] {
            let card: MachineCard = shape(m, now: now)
            if m.kind == "enrolled" { hardware.append(card) } else { groups.append(card) }
        }
        hardware.sort(by: before)
        groups.sort(by: before)
        let snoozed: Int = s.inbox?.snoozed?.count ?? 0
        return HomeScreen(
            top: topBox(s, now: now), snoozedLine: snoozed > 0 ? "\(snoozed) snoozed" : nil,
            machines: hardware, groups: groups)
    }

    public static func isProduction(_ environment: String?) -> Bool {
        environment == nil || environment == "production"
    }

    static func before(_ a: MachineCard, _ b: MachineCard) -> Bool {
        if a.isDown != b.isDown { return a.isDown }
        if a.hasTrouble != b.hasTrouble { return a.hasTrouble }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    static func topBox(_ s: Snapshot, now: Date) -> TopBox {
        let names: [String: String] = Screens.serviceNames(s)
        let needs: [Issue] = s.inbox?.needsYou ?? []
        let soon: [Issue] = s.inbox?.soon ?? []
        var lines: [IssueLine] = []
        for i in (needs.isEmpty ? soon : needs) { lines.append(line(i, names: names, now: now)) }
        if !lines.isEmpty {
            let title: String = needs.isEmpty ? "\(soon.count) coming up soon" : "\(needs.count) need you"
            return .attention(title: title, lines: lines, urgent: !needs.isEmpty)
        }
        let machines: [Machine] = s.machines ?? []
        let hardware: [Machine] = machines.filter { $0.kind == "enrolled" }
        let up: Int = hardware.filter { $0.down != true }.count
        var running: Int = 0
        for m in machines {
            for svc in m.services ?? [] where isProduction(svc.environment) && Level(svc.state) == .ok { running += 1 }
        }
        let things: String = "\(running) thing\(running == 1 ? "" : "s") running"
        var detail: String = things
        if !hardware.isEmpty { detail = "\(up) of \(hardware.count) machines up · " + things }
        return .fine(headline: "Everything is fine", detail: detail)
    }

    static func line(_ i: Issue, names: [String: String], now: Date) -> IssueLine {
        var parts: [String] = []
        if let n = i.service.flatMap({ names[$0] }) { parts.append(n) }
        if let m = i.machine, !m.isEmpty { parts.append(m) }
        if let since = i.since { parts.append("open " + Age.ago(since, now: now).replacingOccurrences(of: " ago", with: "")) }
        if i.snoozedUntil == nil, i.alert?.status == "held" { parts.append("alert held for the night") }
        return IssueLine(id: i.id, title: i.title ?? "Untitled", detail: parts.joined(separator: " · "), serviceID: i.service)
    }

    static func meters(_ v: [String: Double]) -> [Meter] {
        var out: [Meter] = []
        if let x = v["cpu.percent"] { out.append(meter("CPU", x, subject: nil)) }
        if let x = v["memory.used_percent"] { out.append(meter("Memory", x, subject: nil)) }
        var worst: (name: String, value: Double)?
        for (key, value) in v where key.hasPrefix("disk.used_percent.") {
            let name: String = String(key.dropFirst("disk.used_percent.".count))
            if let w = worst, w.value > value || (w.value == value && w.name < name) { continue }
            worst = (name, value)
        }
        if let w = worst { out.append(meter("Disk", w.value, subject: w.name)) }
        return out
    }

    static func meter(_ label: String, _ value: Double, subject: String?) -> Meter {
        let clamped: Double = min(100, max(0, value))
        return Meter(label: label, percent: Int(value.rounded()), subject: subject, isHot: value > hotAbove, fraction: clamped / 100)
    }

    static func countLine(fine: Int, trouble: Int, quiet: Int) -> String {
        var parts: [String] = []
        if fine > 0 { parts.append("\(fine) fine") }
        if trouble > 0 { parts.append("\(trouble) in trouble") }
        if quiet > 0 { parts.append("\(quiet) no signal") }
        return parts.isEmpty ? "nothing watched" : parts.joined(separator: " · ")
    }

    static func shape(_ m: Machine, now: Date) -> MachineCard {
        var trouble: [ServiceLine] = []
        var fine: [ServiceLine] = []
        var quiet: [ServiceLine] = []
        for svc in m.services ?? [] where isProduction(svc.environment) {
            let level: Level = Level(svc.state)
            let item = ServiceLine(id: svc.id, name: svc.name ?? "Unnamed", level: level)
            switch level {
            case .ok: fine.append(item)
            case .degraded, .down, .other: trouble.append(item)
            case .unknown: quiet.append(item)
            case .unwatched: break
            }
        }
        trouble.sort { a, b in
            a.level.rank != b.level.rank ? a.level.rank > b.level.rank : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        fine.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        quiet.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let hardware: Bool = m.kind == "enrolled"
        let down: Bool = hardware && m.down == true
        let hasTrouble: Bool = !trouble.isEmpty
        var word: String?
        var status: String?
        if hardware {
            word = down ? "Down" : "Up"
            var text: String = word ?? ""
            if let seen = m.lastSeenAt {
                let when: String = Age.ago(seen, now: now)
                text += down ? " · last reported " + when : " · " + when
            }
            status = text
        }
        let mark: Level = down ? .down : (hasTrouble ? .degraded : .ok)
        let meterList: [Meter] = meters(m.vitals ?? [:])
        let counts: String = countLine(fine: fine.count, trouble: trouble.count, quiet: quiet.count)
        let quietLine: String? = quietText(quiet)

        var notice: String?
        if let w = m.plannedDowntime {
            notice = "Planned downtime" + (w.until.map { " until " + shortTime($0) } ?? "")
        } else {
            var next: Date?
            for sc in m.schedules ?? [] {
                guard let t = sc.next ?? sc.at else { continue }
                if next == nil || t < (next ?? t) { next = t }
            }
            if let next { notice = "Planned downtime scheduled, next " + shortTime(next) }
        }

        var spoken: [String] = [m.name ?? "Unnamed"]
        if let status { spoken.append(status) }
        for item in meterList { spoken.append(item.spoken) }
        spoken.append(counts)
        if let notice { spoken.append(notice) }

        return MachineCard(
            id: m.id, name: m.name ?? "Unnamed", isHardware: hardware, isDown: down, hasTrouble: hasTrouble,
            mark: mark, word: word, status: status, meters: meterList, countLine: counts, notice: notice,
            trouble: trouble, fine: Array(fine.prefix(fineShown)), moreFine: Array(fine.dropFirst(fineShown)),
            quietLine: quietLine, summary: spoken.joined(separator: ". "))
    }

    static func quietText(_ quiet: [ServiceLine]) -> String? {
        if quiet.isEmpty { return nil }
        let names: String = quiet.prefix(3).map(\.name).joined(separator: ", ")
        return "\(quiet.count) with no signal yet: " + names + (quiet.count > 3 ? "…" : "")
    }
}
