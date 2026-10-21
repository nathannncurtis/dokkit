import Foundation
@testable import DokkitKit

struct SettingsTests {
    let now: Date = Fixtures.now

    func defaultsAreTodaysValues() async throws {
        let d = AppSettings()
        try await expect(d.theme == .system)
        try await expect(d.refreshSeconds == 30)
        try await expect(d.lateMinutes == 5)
        try await expect(d.hotPercent == 85)
        try await expect(d.fineShown == 8)
        try await expect(d.relayWaitSeconds == 20)
        try await expect(d.lockAfter == .everyReturn)
        try await expect(d.changed == 0)
    }

    func roundTripsAndClamps() async throws {
        var s = AppSettings()
        s.theme = .dark
        s.refreshSeconds = 60
        try await expect(AppSettings.decode(s.encoded()) == s)
        try await expect(s.changed == 2)
        try await expect(AppSettings.decode(nil) == AppSettings())
        try await expect(AppSettings.decode(Data("not json".utf8)) == AppSettings())
        let wild = AppSettings.decode(Data(#"{"refreshSeconds":1,"hotPercent":400,"theme":"Purple","future":true}"#.utf8))
        try await expect(wild.refreshSeconds == 10)
        try await expect(wild.hotPercent == 100)
        try await expect(wild.theme == .system)
    }

    func lateSettingMovesTheWarning() async throws {
        let made = now.addingTimeInterval(-400)
        try await expect(Freshness.make(madeAt: made, hasSnapshot: true, problem: nil, now: now).isWarning)
        try await expect(!Freshness.make(madeAt: made, hasSnapshot: true, problem: nil, now: now, late: 600).isWarning)
    }

    private func issue(_ extra: String) throws -> Issue {
        let since = now.addingTimeInterval(-7200).ISO8601Format()
        let json = #"{"issues":[{"id":"i","short_id":"DOK-1","title":"T","service":"s","machine":"db-01","since":"\#(since)"\#(extra)}]}"#
        return try require(try Snapshot.decode(Data(json.utf8)).issues?.first)
    }

    func sentencesAndNextSteps() async throws {
        let names = ["s": "nightly-purge"]
        try await expect(Words.sentence(try issue(#","state":"down""#), names: names, now: now) == "Something is wrong with nightly-purge on db-01 since 2 h ago.")
        try await expect(Words.sentence(try issue(#","state":"degraded""#), names: names, now: now) == "Working, but not as it should: nightly-purge on db-01, since 2 h ago.")
        try await expect(Words.sentence(try issue(#","state":"degraded","soon":true"#), names: names, now: now) == "Nothing is broken. Plan for it when it suits you.")
        try await expect(Words.nextStep(try issue(#","kind":"job""#)) == "See the last run")
        try await expect(Words.nextStep(try issue(#","kind":"threshold""#)) == "Look at the disk")
        try await expect(Words.nextStep(try issue(#","kind":"expiry""#)) == "See the certificate")
        try await expect(Words.nextStep(try issue(#","kind":"http""#)) == "Look into it")
        try await expect(Words.tone(try issue(#","state":"down""#), now: now) == .down)
        let flags = Words.flags(try issue(#","state":"degraded","acknowledged_at":"\#(now.ISO8601Format())","alert":{"status":"held"}"#), now: now).map(\.text)
        try await expect(flags == ["Seen", "Alert held for the night"], "\(flags)")
    }

    func homeLedeAndCards() async throws {
        let h = Home.make(Fixtures.snapshot, now: now)
        try await expect(h.needs.count == (Fixtures.snapshot.inbox?.needsYou?.count ?? 0))
        try await expect(!h.lede.isEmpty)
        try await expect(h.needs.allSatisfy { !$0.sentence.isEmpty && !$0.nextStep.isEmpty })
    }
}
