import Foundation
@testable import DokkitKit

struct SnapshotTests {
    let s = Fixtures.snapshot
    let raw = Fixtures.raw
    let now = Fixtures.now

    func decodesWithoutLoss() async throws {
        try await expect(s.server?.name == "northwind.example.com")
        try await expect(s.server?.counter == 1791937925)
        try await expect(s.server?.madeAt == Snapshot.parseDate("2026-10-14T00:32:05Z"))
        let rawServices = raw["services"] as! [[String: Any]]
        let services = try require(s.services)
        try await expect(services.count == rawServices.count)
        for (a, b) in zip(services, rawServices) {
            try await expect(a.id == b["id"] as? String)
            try await expect(a.name == b["name"] as? String)
            try await expect(a.state == b["state"] as? String)
            try await expect(a.kind == b["kind"] as? String)
            try await expect(a.version == b["version"] as? String)
            try await expect(a.checks?.count == (b["checks"] as? [Any])?.count)
        }
        let rawMachines = raw["machines"] as! [[String: Any]]
        try await expect(s.machines?.count == rawMachines.count)
        for (a, b) in zip(s.machines!, rawMachines) {
            try await expect(a.name == b["name"] as? String)
            try await expect(a.services?.count == (b["services"] as? [Any])?.count)
            try await expect(a.schedules?.count == (b["schedules"] as? [Any])?.count)
            try await expect(a.lastSeenAt != nil)
        }
        let rawIssues = raw["issues"] as! [[String: Any]]
        try await expect(s.issues?.count == rawIssues.count)
        for (a, b) in zip(s.issues!, rawIssues) {
            try await expect(a.shortId == b["short_id"] as? String)
            try await expect(a.title == b["title"] as? String)
            try await expect(a.since != nil)
            try await expect(a.history?.count == (b["history"] as? [Any])?.count)
        }
        let box = raw["inbox"] as! [String: Any]
        try await expect(s.inbox?.needsYou?.count == (box["needs_you"] as! [Any]).count)
        try await expect(s.inbox?.soon?.count == (box["soon"] as! [Any]).count)
        try await expect(s.inbox?.snoozed?.count == (box["snoozed"] as! [Any]).count)
        try await expect(s.inbox?.notWatched?.count == (box["not_watched"] as! [Any]).count)
        try await expect(s.inbox?.snoozed?.first?.snoozedUntil != nil)
        try await expect(s.inbox?.fine?.services == 45)
        try await expect(s.jobs?.count == 3)
        try await expect(s.jobs?.first?.lastRun?.result == "running")
        let rawLogs = raw["logs"] as! [String: [Any]]
        for (id, lines) in rawLogs { try await expect(s.logs?[id]?.count == lines.count) }
    }

    func toleratesUnknownFieldsAndValues() async throws {
        let json = #"{"schema":9,"extra":{"a":1},"services":[{"id":"a","name":"X","state":"sleepy","novel":[1],"chart":{"metric":null,"values":[1,null,2.5]}}]}"#
        let snap = try Snapshot.decode(Data(json.utf8))
        try await expect(Level(snap.services?.first?.state) == .other("sleepy"))
        try await expect(Level.other("sleepy").word == "Sleepy")
        try await expect(snap.services?.first?.chart?.values == [1, nil, 2.5])
        try await expect(snap.inbox == nil)
        try await expect(leftOutText(snap) == nil)
        let cut = try Snapshot.decode(Data(#"{"server":{"left_out":["logs"]}}"#.utf8))
        try await expect(leftOutText(cut) == "Log lines were left out of this snapshot to keep it small.")
        let empty = try Snapshot.decode(Data("{}".utf8))
        try await expect(Screens.needsYou(empty, now: now).nothingNeedsYou)
        try await expect(Screens.everything(empty).isEmpty)
    }

    func needsYouScreen() async throws {
        let n = Screens.needsYou(s, now: now)
        try await expect(n.sections.map(\.title) == ["Needs you", "Soon", "Snoozed"])
        try await expect(n.sections[0].rows.count == 3)
        try await expect(n.sections[0].rows.allSatisfy { !$0.shortId.isEmpty && $0.serviceName != nil })
        try await expect(n.sections[2].rows[0].flags.first?.hasPrefix("Snoozed until") == true)
        try await expect(n.notWatched.count == 4)
        try await expect(n.notWatched.first?.name == "defrag")
        try await expect(n.fine == "45 services and 6 machines fine")
        try await expect(!n.nothingNeedsYou)
    }

    func everythingScreen() async throws {
        let rows = Screens.everything(s)
        try await expect(rows.count == 6)
        try await expect(rows.map(\.level.rank) == rows.map(\.level.rank).sorted(by: >))
        let db = rows.first { $0.name == "db-01" }
        try await expect(db?.level == .down)
        try await expect(db?.services.first?.level == .down)
    }

    func serviceScreen() async throws {
        let id = "4bfc9563-d352-4ef6-8486-f8ffc817aeb6"
        let v = try require(Screens.service(s, id: id, now: now))
        try await expect(v.name == "Upload portal")
        try await expect(v.version == "2.4.1")
        try await expect(v.checks.count == 2)
        try await expect(v.issue != nil)
        try await expect(v.history.first?.text == "Opened")
        try await expect(v.logs.count == 20)
        try await expect(v.logs.contains { $0.isError })
        try await expect(Screens.service(s, id: "nope", now: now) == nil)
        let job = try require(Screens.service(s, id: "7012ff32-1231-4688-bcbf-309564fc2ee2", now: now))
        try await expect(job.level == .down)
        try await expect(Screens.service(s, id: "0ae2b839-1e1a-4c8a-8170-524922bd9207", now: now)?.job.isEmpty == false)
    }

    func chartDrawsFromValues() async throws {
        let json = #"{"machines":[{"id":"m","name":"m","services":[{"id":"s","name":"S","state":"ok"}]}],"services":[{"id":"s","name":"S","state":"ok","chart":{"metric":"latency","values":[1,null,3]}}]}"#
        let snap = try Snapshot.decode(Data(json.utf8))
        try await expect(Screens.everything(snap)[0].services[0].chart == [1, nil, 3])
        try await expect(Screens.service(snap, id: "s", now: Fixtures.now)?.chart == [1, nil, 3])
        try await expect(snap.services?.first?.chart?.metric == "latency")
    }

    func realChartsDecode() async throws {
        let rawServices = Fixtures.raw["services"] as! [[String: Any]]
        for (a, b) in zip(Fixtures.snapshot.services ?? [], rawServices) {
            let n = ((b["chart"] as? [String: Any])?["values"] as? [Any])?.count
            try await expect(a.chart?.values?.count == n, a.name ?? "")
        }
        try await expect(Fixtures.snapshot.server?.leftOut != nil || Fixtures.raw["server"] != nil)
    }

    func vitalsAreShown() async throws {
        let json = #"{"machines":[{"id":"m","name":"m","vitals":{"cpu.percent":12.4,"memory.used_percent":93,"disk.used_percent.C:":50}}]}"#
        let rows = Screens.everything(try Snapshot.decode(Data(json.utf8)))
        try await expect(rows[0].vitals == [Vital(label: "Processor", percent: 12, isHot: false), Vital(label: "Memory", percent: 93, isHot: true), Vital(label: "Disk C:", percent: 50, isHot: false)])
    }

    func ageTextAndWarning() async throws {
        let t = Fixtures.now
        func at(_ s: TimeInterval) -> Date { t.addingTimeInterval(-s) }
        try await expect(Age.ago(at(0), now: t) == "just now")
        try await expect(Age.ago(at(-30), now: t) == "just now")
        try await expect(Age.ago(at(12), now: t) == "12 seconds ago")
        try await expect(Age.ago(at(90), now: t) == "1 min ago")
        try await expect(Age.ago(at(7300), now: t) == "2 h ago")
        try await expect(Age.ago(at(3 * 86400), now: t) == "3 d ago")
        try await expect(!Freshness.make(madeAt: at(300), hasSnapshot: true, problem: nil, now: t).isWarning)
        let late = Freshness.make(madeAt: at(301), hasSnapshot: true, problem: nil, now: t)
        try await expect(late.isWarning)
        try await expect(late.detail?.contains("not delivering") == true)
        let ok = Freshness.make(madeAt: at(20), hasSnapshot: true, problem: "The relay could not be reached.", now: t)
        try await expect(!ok.isWarning && ok.detail == "The relay could not be reached.")
        try await expect(Freshness.make(madeAt: nil, hasSnapshot: false, problem: nil, now: t).text == "No snapshot yet")
    }
}
