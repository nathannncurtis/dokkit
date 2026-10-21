import SwiftUI
import DokkitKit

struct ServiceView: View {
    let model: AppModel
    let id: String
    var back: (() -> Void)?

    var body: some View {
        if model.selectedState.snapshot == nil {
            NoSnapshot(model: model, title: "Service", back: back)
        } else {
            TimelineView(.periodic(from: .now, by: 5)) { ctx in content(now: ctx.date) }
        }
    }

    @ViewBuilder private func content(now: Date) -> some View {
        let snap = model.selectedState.snapshot!
        let f = model.freshness(model.selectedState, now: now)
        if let v = Screens.service(snap, id: id, now: now) {
            let tone = Theme.tone(v.level)
            let line = [v.kind, v.version.map { "version \($0)" }, v.environment].compactMap { $0 }.joined(separator: " · ")
            StatementPage(tone: tone, top: { ServerTop(model: model, title: "Service", back: back) },
                          hero: HeroModel(tone: tone, icon: Theme.icon(tone), big: v.name, eyebrow: v.machine, tag: v.level.word, lede: v.note,
                                          extra: line.isEmpty ? nil : line, age: !f.isWarning && f.detail == nil ? f.text : nil),
                          onRefresh: { await model.refresh() }) {
                if f.isWarning || f.detail != nil { Banner(f: f) }
                if let lo = leftOutText(snap) { QuietLine(text: lo, icon: "info") }
                if let machineID = (snap.machines ?? []).first(where: { $0.name == v.machine })?.id, let name = v.machine {
                    SoftButton(text: "Open \(name)", icon: "arrow-right", full: true) { model.open(.machine(machineID)) }
                }
                if v.issue != nil { OpenIssue(snap: snap, v: v, now: now) }
                if !v.checks.isEmpty { checks(v) }
                if !v.job.isEmpty { job(snap, v) }
                if v.chart.contains(where: { $0 != nil }) { chart(v) }
                if !v.logs.isEmpty { logs(v) }
            }
        } else {
            StatementPage(tone: .quiet, top: { ServerTop(model: model, title: "Service", back: back) },
                          hero: HeroModel(tone: .quiet, icon: "info", big: "Not in this snapshot", eyebrow: "Service", lede: "The newest snapshot no longer lists this service.")) {}
        }
    }

    private func checks(_ v: ServiceScreen) -> some View {
        BigCard {
            CardHead(title: "Checks", detail: "\(v.checks.count)")
            ForEach(Array(v.checks.enumerated()), id: \.offset) { n, c in
                if n > 0 { Rectangle().fill(Theme.line.opacity(0.75)).frame(height: 1) }
                let tone = Theme.tone(c.level)
                HStack(alignment: .top, spacing: 14) {
                    ToneCircle(tone: tone, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name).font(figtree(14, .semibold, relativeTo: .subheadline)).foregroundStyle(Theme.ink)
                        Text(c.level.word).font(figtree(13, .semibold, relativeTo: .footnote)).foregroundStyle(tone == .quiet ? Theme.mute : Theme.tint(tone).ink)
                        if let note = c.note { Text(note).font(figtree(13, .regular, relativeTo: .footnote)).foregroundStyle(Theme.mute) }
                        if let t = c.checked { Text("Checked \(t)").font(figtree(12, .medium, relativeTo: .caption)).foregroundStyle(Theme.mute) }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
                .accessibilityElement(children: .combine)
            }
            Spacer().frame(height: 8)
        }
    }

    private func job(_ snap: Snapshot, _ v: ServiceScreen) -> some View {
        let run = (snap.jobs ?? []).first { $0.id == v.id }?.lastRun
        return BigCard {
            CardHead(title: "Job")
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(v.job.enumerated()), id: \.offset) { _, pair in
                    HStack(alignment: .firstTextBaseline, spacing: 18) {
                        Text(pair[0]).font(figtree(14, .regular, relativeTo: .subheadline)).foregroundStyle(Theme.mute).frame(width: 110, alignment: .leading)
                        Text(pair[1]).font(figtree(13, .medium, relativeTo: .footnote)).foregroundStyle(Theme.ink)
                    }
                    .accessibilityElement(children: .combine)
                }
                if run?.result == "running", let d = run?.done, let t = run?.total, t > 0 {
                    MeterBar(fraction: d / t, color: Theme.peach.solid, key: "job-\(v.id)")
                }
            }
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 20)
        }
    }

    private func chart(_ v: ServiceScreen) -> some View {
        let latest = v.chart.compactMap { $0 }.last
        return BigCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Last 24 hours").font(figtree(18, .bold, relativeTo: .headline)).foregroundStyle(Theme.ink)
                    Spacer()
                    if let m = v.metric { Text(m).font(figtree(13, .regular, relativeTo: .footnote)).foregroundStyle(Theme.mute) }
                }
                if let latest {
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        Tick(value: Int(latest.rounded()), key: "chart-\(v.id)", font: figtree(34, .heavy, relativeTo: .largeTitle))
                        Text("now").font(figtree(14, .semibold, relativeTo: .subheadline)).foregroundStyle(Theme.mute)
                    }
                    .padding(.top, 10)
                }
                Bars(values: v.chart, key: "svc-\(v.id)", label: v.metric ?? "Chart").padding(.top, 16)
                Axis(words: ["24 h ago", "Now"])
            }
            .padding(20)
        }
    }

    private func logs(_ v: ServiceScreen) -> some View {
        BigCard {
            CardHead(title: "Last log lines", detail: "\(v.logs.count)")
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(v.logs.enumerated()), id: \.offset) { _, l in
                    let warn = l.level == "warn" || l.level == "warning"
                    Text(l.text)
                        .font(figtree(12.5, .regular, relativeTo: .caption))
                        .foregroundStyle(l.isError ? Theme.rose.ink : warn ? Theme.amber.ink : Theme.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(l.isError ? Theme.rose.surface : warn ? Theme.amber.surface : .clear, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(10)
        }
    }
}

private struct OpenIssue: View {
    let snap: Snapshot
    let v: ServiceScreen
    let now: Date

    var body: some View {
        let row = v.issue!
        let raw = (snap.issues ?? []).first { $0.id == row.id }
            ?? ((snap.inbox?.needsYou ?? []) + (snap.inbox?.soon ?? []) + (snap.inbox?.snoozed ?? [])).first { $0.id == row.id }
        let tone = raw.map { Words.tone($0, now: now) } ?? Theme.tone(row.level)
        let word = raw.map { Words.word($0, now: now) } ?? row.level.word
        let t = Theme.tint(tone)
        BigCard {
            CardHead(title: "Open issue", detail: row.shortId)
            VStack(alignment: .leading, spacing: 4) {
                TagView(text: word, tone: tone, onPanel: true)
                Text(row.title).font(figtree(19, .bold, relativeTo: .title3)).foregroundStyle(Theme.ink).padding(.top, 6)
                if let n = row.note { Text(n).font(figtree(15, .regular)).foregroundStyle(Theme.ink2) }
                Text([row.serviceName, row.machine.isEmpty ? nil : row.machine, row.since, row.count].compactMap { $0 }.joined(separator: " · "))
                    .font(figtree(12, .medium, relativeTo: .caption)).foregroundStyle(Theme.mute).padding(.top, 6)
                let flags = raw.map { Words.flags($0, now: now) } ?? []
                if !flags.isEmpty { FlagsRow(flags: flags).padding(.top, 8) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(t.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(12)
            if !v.history.isEmpty {
                let events = Array(v.history.reversed())
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(events.enumerated()), id: \.offset) { n, e in
                        HStack(alignment: .top, spacing: 14) {
                            ZStack(alignment: .top) {
                                if n < events.count - 1 { Rectangle().fill(Theme.line).frame(width: 2).padding(.top, 18) }
                                Circle().strokeBorder(n == 0 ? t.ink : Theme.mist.ink, lineWidth: 2).frame(width: 14, height: 14).padding(.top, 4)
                            }
                            .frame(width: 14)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.text).font(figtree(15, .regular)).foregroundStyle(Theme.ink)
                                if let w = e.when { Text(w).font(figtree(12, .medium, relativeTo: .caption)).foregroundStyle(Theme.mute) }
                            }
                            .padding(.bottom, n < events.count - 1 ? 16 : 0)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.horizontal, 22).padding(.top, 6).padding(.bottom, 22)
            }
        }
    }
}
