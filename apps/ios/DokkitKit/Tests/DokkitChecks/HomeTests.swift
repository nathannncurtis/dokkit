import Foundation
@testable import DokkitKit

struct HomeTests {
    let now: Date = Fixtures.now

    func home(_ json: String) throws -> HomeScreen {
        Home.make(try Snapshot.decode(Data(json.utf8)), now: now)
    }

    func machine(_ name: String, kind: String = "enrolled", down: Bool = false, vitals: String = "{}", services: String = "[]", extra: String = "") -> String {
        let id: String = "m-" + name
        return #"{"id":"\#(id)","name":"\#(name)","kind":"\#(kind)","down":\#(down),"last_seen_at":"2026-10-13T23:58:00Z","vitals":\#(vitals),"services":\#(services)\#(extra)}"#
    }

    func service(_ name: String, _ state: String, env: String = "production") -> String {
        #"{"id":"s-\#(name)","name":"\#(name)","state":"\#(state)","environment":"\#(env)"}"#
    }

    func services(_ n: Int, _ state: String, prefix: String) -> String {
        (0..<n).map { service(prefix + String(format: "%02d", $0), state) }.joined(separator: ",")
    }

    func snapshot(_ machines: [String], inbox: String = "{}") -> String {
        #"{"schema":1,"inbox":\#(inbox),"machines":[\#(machines.joined(separator: ","))]}"#
    }

    func fixtureHome() async throws {
        let h = Home.make(Fixtures.snapshot, now: now)
        guard case .attention(let title, let lines, let urgent) = h.top else {
            try await expect(false, "fixture has issues")
            return
        }
        try await expect(title == "3 need you")
        try await expect(urgent)
        try await expect(lines.count == 3)
        try await expect(lines.allSatisfy { !$0.title.isEmpty && $0.serviceID != nil })
        try await expect(h.snoozedLine == "1 snoozed")
        try await expect(h.machines.count == 6 && h.groups.isEmpty)

        let raw = Fixtures.raw["machines"] as! [[String: Any]]
        for card in h.machines {
            let m = raw.first { ($0["name"] as? String) == card.name }!
            let svcs = m["services"] as! [[String: Any]]
            let prod = svcs.filter { ($0["environment"] as? String) == "production" }
            let ok = prod.filter { ($0["state"] as? String) == "ok" }.count
            let bad = prod.filter { ["down", "degraded"].contains($0["state"] as? String ?? "") }.count
            try await expect(card.fine.count + card.moreFine.count == ok, card.name)
            try await expect(card.trouble.count == bad, card.name)
            try await expect(card.status?.hasPrefix("Up") == true, card.name)
        }
        let flags: [Bool] = h.machines.map(\.hasTrouble)
        try await expect(flags == flags.sorted { $0 && !$1 }, "trouble first")
        let build = try require(h.machines.first { $0.name == "build" })
        try await expect(build.trouble.isEmpty, "dev environment is left off")
    }

    func fineBox() async throws {
        let h = try home(snapshot([
            machine("a", services: "[" + services(3, "ok", prefix: "a") + "," + service("u", "unknown") + "," + service("w", "unwatched") + "," + service("d", "ok", env: "dev") + "]"),
            machine("b", down: true, services: "[" + service("b1", "ok") + "]"),
            machine("g", kind: "group", services: "[" + service("g1", "ok") + "]"),
        ]))
        try await expect(h.top == .fine(headline: "Everything is fine", detail: "1 of 2 machines up · 5 things running"))
        try await expect(h.snoozedLine == nil)
        let one = try home(snapshot([machine("a", services: "[" + service("x", "ok") + "]")]))
        try await expect(one.top == .fine(headline: "Everything is fine", detail: "1 of 1 machines up · 1 thing running"))
    }

    func attentionBox() async throws {
        let soon = #"{"soon":[{"id":"i1","title":"Certificate expires","service":"s-x","machine":"a","state":"degraded","since":"2026-10-13T20:00:00Z"}],"snoozed":[{"id":"i2"},{"id":"i3"}]}"#
        let h = try home(snapshot([machine("a", services: "[" + service("x", "ok") + "]")], inbox: soon))
        guard case .attention(let title, let lines, let urgent) = h.top else {
            try await expect(false, "soon issues are shown")
            return
        }
        try await expect(title == "1 coming up soon" && !urgent)
        try await expect(lines[0].detail == "x · a · open 4 h")
        try await expect(lines[0].serviceID == "s-x")
        try await expect(h.snoozedLine == "2 snoozed")
    }

    func meters() async throws {
        let v = #"{"cpu.percent":12.4,"memory.used_percent":93,"disk.used_percent.C":50,"disk.used_percent.data":85,"disk.used_percent.D":85.5}"#
        let h = try home(snapshot([machine("a", vitals: v), machine("b"), machine("c", vitals: #"{"disk.used_percent.data":85}"#)]))
        let a = try require(h.machines.first { $0.name == "a" })
        try await expect(a.meters.map(\.label) == ["CPU", "Memory", "Disk"])
        try await expect(a.meters.map(\.percent) == [12, 93, 86])
        try await expect(a.meters.map(\.isHot) == [false, true, true])
        try await expect(a.meters[2].subject == "D")
        try await expect(a.meters[2].spoken == "Disk D 86 percent, high")
        try await expect(a.summary.contains("Memory 93 percent, high"))
        let b = try require(h.machines.first { $0.name == "b" })
        try await expect(b.meters.isEmpty)
        let c = try require(h.machines.first { $0.name == "c" })
        try await expect(c.meters.count == 1 && !c.meters[0].isHot, "85 exactly is not past 85")
        try await expect(Home.meter("x", 150, subject: nil).fraction == 1)
    }

    func openedList() async throws {
        let list: String = "[" + service("down1", "down") + "," + service("deg1", "degraded") + "," + services(10, "ok", prefix: "f") + "," + services(4, "unknown", prefix: "q") + "]"
        let h = try home(snapshot([machine("a", services: list)]))
        let c = h.machines[0]
        try await expect(c.trouble.map(\.name) == ["down1", "deg1"], "down before degraded")
        try await expect(c.fine.count == 8 && c.moreFine.count == 2)
        try await expect(c.quietLine == "4 with no signal yet: q00, q01, q02…")
        try await expect(c.countLine == "10 fine · 2 in trouble · 4 no signal")
        try await expect(!c.isEmpty)
        let three: String = "[" + services(3, "unknown", prefix: "q") + "]"
        let t = try home(snapshot([machine("a", services: three)])).machines[0]
        try await expect(t.quietLine == "3 with no signal yet: q00, q01, q02")
        let ten: String = "[" + services(8, "ok", prefix: "f") + "]"
        let e = try home(snapshot([machine("a", services: ten)])).machines[0]
        try await expect(e.moreFine.isEmpty, "eight fine shows no more row")
    }

    func groupsAndKinds() async throws {
        let h = try home(snapshot([
            machine("hw", services: "[" + service("x", "ok") + "]"),
            machine("Apps", kind: "group", vitals: #"{"cpu.percent":50}"#, services: "[" + service("y", "degraded") + "]"),
            machine("seen1", kind: "seen"),
        ]))
        try await expect(h.machines.map(\.name) == ["hw"])
        try await expect(h.groups.map(\.name) == ["Apps", "seen1"])
        let apps = h.groups[0]
        try await expect(apps.status == nil && apps.word == nil && !apps.isHardware)
        try await expect(apps.hasTrouble && apps.mark == .degraded)
        try await expect(apps.countLine == "1 in trouble")
    }

    func countLines() async throws {
        try await expect(Home.countLine(fine: 12, trouble: 1, quiet: 3) == "12 fine · 1 in trouble · 3 no signal")
        try await expect(Home.countLine(fine: 0, trouble: 2, quiet: 0) == "2 in trouble")
        try await expect(Home.countLine(fine: 0, trouble: 0, quiet: 0) == "nothing watched")
        let h = try home(snapshot([machine("a", services: "[" + service("w", "unwatched") + "]")]))
        try await expect(h.machines[0].countLine == "nothing watched" && h.machines[0].isEmpty)
    }

    func hiddenThings() async throws {
        let list: String = "[" + service("w", "unwatched") + "," + service("p", "ok") + "," + service("d", "down", env: "dev") + "," + service("st", "ok", env: "staging") + "]"
        let inbox = #"{"not_watched":[{"id":"n","name":"defrag"}],"other_environments":[{"environment":"dev","issues":[{"id":"o","title":"Web preview is down"}]}]}"#
        let h = try home(snapshot([machine("a", services: list)], inbox: inbox))
        let c = h.machines[0]
        let all: [ServiceLine] = c.trouble + c.fine + c.moreFine
        try await expect(all.map(\.name) == ["p"])
        try await expect(!c.hasTrouble && c.quietLine == nil)
        try await expect(h.top == .fine(headline: "Everything is fine", detail: "1 of 1 machines up · 1 thing running"))
        let withOther = try require(Fixtures.snapshot.inbox?.otherEnvironments?.first)
        try await expect(withOther.environment != nil)
        guard case .attention(_, let lines, _) = Home.make(Fixtures.snapshot, now: now).top else { return }
        try await expect(!lines.contains { $0.title.contains("Web preview") }, "other environments are not in the box")
        try await expect(Level("unwatched") == .unwatched)
    }

    func sorting() async throws {
        let h = try home(snapshot([
            machine("x", services: "[" + service("a", "ok") + "]"),
            machine("Y", down: true, services: "[" + service("a", "ok") + "]"),
            machine("z", services: "[" + service("a", "degraded") + "]"),
            machine("A", services: "[" + service("a", "ok") + "]"),
            machine("b", down: true, services: "[" + service("a", "down") + "]"),
        ]))
        try await expect(h.machines.map(\.name) == ["b", "Y", "z", "A", "x"])
    }

    func downtimeAndStatus() async throws {
        let planned = #","planned_downtime":{"until":"2026-10-14T01:00:00Z","reason":"patching"}"#
        let sched = #","schedules":[{"id":"1","reason":"updates","next":"2026-10-19T01:00:00Z"},{"id":"2","next":"2026-10-16T01:00:00Z"}]"#
        let h = try home(snapshot([
            machine("p", extra: planned), machine("s", extra: sched), machine("d", down: true), machine("u"),
        ]))
        let p = try require(h.machines.first { $0.name == "p" })
        try await expect(p.notice?.hasPrefix("Planned downtime until") == true)
        let s = try require(h.machines.first { $0.name == "s" })
        try await expect(s.notice?.hasPrefix("Planned downtime scheduled, next") == true)
        try await expect(h.machines.first { $0.name == "u" }?.notice == nil)
        let d = try require(h.machines.first { $0.name == "d" })
        try await expect(d.status == "Down · last reported 2 min ago" && d.mark == .down && d.word == "Down")
        let u = try require(h.machines.first { $0.name == "u" })
        try await expect(u.status == "Up · 2 min ago" && u.mark == .ok)
        try await expect(u.summary.hasPrefix("u. Up · 2 min ago"))
    }
}
