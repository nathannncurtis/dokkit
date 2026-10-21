import SwiftUI
import DokkitKit

private func cardTone(_ c: MachineCard) -> Tone { c.planned ? .quiet : c.isDown ? .down : c.hasTrouble ? .degraded : .ok }

/// The top bar of the pages that show a server: its name, the server picker and refresh.
struct ServerTop: View {
    let model: AppModel
    let title: String
    var back: (() -> Void)?
    @Environment(\.morph) private var ns
    @Environment(\.onTop) private var onTop

    var body: some View {
        TopBar(title: title, server: model.selected?.name, back: back) {
            if model.servers.count > 1 {
                if let ns, !model.picking, onTop {
                    RoundIcon(icon: "swap", label: "Switch server") { withAnimation(Theme.travel) { model.picking = true } }
                        .matchedGeometryEffect(id: "picker", in: ns)
                } else if !model.picking {
                    RoundIcon(icon: "swap", label: "Switch server") { model.picking = true }
                } else {
                    Color.clear.frame(width: 50, height: 44)
                }
            }
            RoundIcon(icon: "arrows-clockwise", label: "Refresh", spinning: model.refreshing) { Task { await model.refresh() } }
        }
    }
}

/// The hero and body every server page shows when there is no snapshot to show.
struct NoSnapshot: View {
    let model: AppModel
    let title: String
    var back: (() -> Void)?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { ctx in
            let f = model.freshness(model.selectedState, now: ctx.date)
            let paired = !model.servers.isEmpty
            StatementPage(tone: .quiet, top: { ServerTop(model: model, title: title, back: back) },
                          hero: HeroModel(tone: .quiet, icon: paired ? "hourglass-medium" : "device-mobile", big: paired ? "No snapshot yet" : "No server paired",
                                          eyebrow: Words.greeting(ctx.date),
                                          lede: paired ? "This phone is paired. The server uploads a snapshot about once a minute while a phone is paired; pull down to look again."
                                              : "In the Dokkit web interface open Settings, Phones, Add a phone. It shows a QR code once. Then choose Servers here and scan it."),
                          onRefresh: { await model.refresh() }) {
                if f.detail != nil { Banner(f: f) }
            }
        }
    }
}

struct HomeView: View {
    let model: AppModel
    @State private var issueTab = "needs"
    @Environment(\.morph) private var ns

    var body: some View {
        if model.selectedState.snapshot == nil {
            NoSnapshot(model: model, title: "Home")
        } else {
            TimelineView(.periodic(from: .now, by: 5)) { ctx in content(now: ctx.date) }
        }
    }

    @ViewBuilder private func content(now: Date) -> some View {
        let snap = model.selectedState.snapshot!
        let f = model.freshness(model.selectedState, now: now)
        let h = Home.make(snap, now: now, hot: Double(model.settings.hotPercent), shown: model.settings.fineShown)
        let fine: Bool = { if case .fine = h.top { return true }; return false }()
        let tone: Tone = fine ? .ok : !h.needs.isEmpty ? (h.needs.contains { $0.tone == .down } ? .down : .degraded) : .soon
        let hero: HeroModel = {
            var m = HeroModel(tone: tone, icon: Theme.icon(tone), big: "", eyebrow: Words.greeting(now), eyebrowIcon: "hand-waving",
                              age: !f.isWarning && f.detail == nil ? f.text : nil)
            if case .fine(let headline, let detail) = h.top {
                m.big = headline
                m.lede = detail
            } else if !h.needs.isEmpty {
                m.bigNumber = (h.needs.count, "hero-needs", "thing needs you", "things need you")
                m.lede = h.lede
            } else {
                m.bigNumber = (h.soon.count, "hero-soon", "thing is coming up", "things are coming up")
                m.lede = h.lede
            }
            return m
        }()
        StatementPage(tone: tone, top: { ServerTop(model: model, title: "Home") }, hero: hero, onRefresh: { await model.refresh() }) {
            if f.isWarning || f.detail != nil { Banner(f: f) }
            if let lo = leftOutText(snap) { QuietLine(text: lo, icon: "info") }
            Figures(items: [
                Figure(value: h.needs.count, word: "need you", tone: tone == .down ? .down : .degraded, key: "fig-needs"),
                Figure(value: h.soon.count, word: "coming up", tone: .soon, key: "fig-soon"),
                Figure(value: h.fineServices, word: "fine", tone: .ok, key: "fig-fine"),
            ])
            if !fine {
                let showing = h.needs.isEmpty ? "soon" : h.soon.isEmpty ? "needs" : issueTab
                if !h.needs.isEmpty, !h.soon.isEmpty {
                    Segmented(items: [("needs", "Needs you", h.needs.count), ("soon", "Coming up", h.soon.count)], selected: showing) { k in
                        withAnimation(Theme.travel) { issueTab = k }
                    }
                } else {
                    Label2(text: showing == "needs" ? "Needs you" : "Coming up")
                }
                // The cards slide with the switch, on the same spring as its lens: forward pushes them left.
                ZStack {
                    ForEach([showing], id: \.self) { key in
                        VStack(spacing: 16) {
                            ForEach(key == "needs" ? h.needs : h.soon) { c in issueCard(c) }
                        }
                        .transition(.asymmetric(insertion: .move(edge: key == "soon" ? .trailing : .leading),
                                                removal: .move(edge: key == "soon" ? .leading : .trailing)))
                    }
                }
                if let s = h.snoozedLine { QuietLine(text: s, icon: "moon") }
                if let line = h.fineLine { AllFine(text: line) }
            } else if let s = h.snoozedLine {
                QuietLine(text: s, icon: "moon")
            }
            let days = h.machines.filter { $0.lastDay != nil }
            if !days.isEmpty {
                BigCard {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("The last day").font(figtree(18, .bold, relativeTo: .headline)).foregroundStyle(Theme.ink)
                        Text("The last 24 hours. Now is on the right.").font(figtree(14, .regular, relativeTo: .subheadline)).foregroundStyle(Theme.mute).padding(.bottom, 16)
                        ForEach(Array(days.enumerated()), id: \.element.id) { n, c in
                            Button { model.open(.machine(c.id)) } label: {
                                HStack {
                                    Text(c.name).font(figtree(12.5, .medium, relativeTo: .caption)).foregroundStyle(Theme.ink2)
                                    Spacer()
                                    ph("caret-right").resizable().frame(width: 14, height: 14).foregroundStyle(Theme.mute)
                                }
                                .padding(.top, n == 0 ? 0 : 8).padding(.bottom, 4).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).accessibilityLabel("Open \(c.name)")
                            Strip(cells: c.lastDay ?? [], key: "home-\(c.id)", row: n, label: c.name)
                        }
                        Legend().padding(.top, 16)
                    }
                    .padding(20)
                }
            }
            if !h.machines.isEmpty {
                Label2(text: "Machines")
                MachineList(model: model, cards: h.machines)
            }
            if !h.groups.isEmpty {
                Label2(text: "Not on a machine")
                MachineList(model: model, cards: h.groups)
            }
        }
    }

    @ViewBuilder private func issueCard(_ c: IssueCard) -> some View {
        let open: () -> Void = { if let s = c.serviceID { model.open(.service(s, from: c.id)) } }
        if #available(iOS 18.0, macOS 15.0, *), let ns {
            IssueCardView(c: c, onOpen: open).matchedTransitionSource(id: "issue-\(c.id)", in: ns)
        } else {
            IssueCardView(c: c, onOpen: open)
        }
    }
}

struct MachineList: View {
    let model: AppModel
    let cards: [MachineCard]
    var body: some View {
        BigCard {
            ForEach(Array(cards.enumerated()), id: \.element.id) { i, c in
                if i > 0 { Rectangle().fill(Theme.line.opacity(0.75)).frame(height: 1) }
                MachineRow(model: model, c: c)
            }
        }
    }
}

struct MachineRow: View {
    let model: AppModel
    let c: MachineCard
    private var open: Bool { model.openMachines[c.id] ?? false }

    var body: some View {
        VStack(spacing: 0) {
            Button { withAnimation(Theme.ease) { model.openMachines[c.id] = !open } } label: {
                HStack(spacing: 14) {
                    if c.isHardware { Pip(tone: cardTone(c)) } else { ph("cloud").resizable().frame(width: 17, height: 17).foregroundStyle(Theme.mute) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name).font(figtree(16, .medium)).foregroundStyle(Theme.ink)
                        if let s = c.status { Text(s).font(figtree(13, .regular, relativeTo: .footnote)).foregroundStyle(c.isDown ? Theme.rose.ink : Theme.mute) }
                        Text(c.countLine).font(figtree(13, .regular, relativeTo: .footnote)).foregroundStyle(Theme.mute)
                    }
                    Spacer()
                    ph("caret-down").resizable().frame(width: 20, height: 20).foregroundStyle(Theme.mute).rotationEffect(.degrees(open ? 180 : 0))
                }
                .padding(.horizontal, 20).padding(.vertical, 14).frame(minHeight: 68).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(c.summary)
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            .accessibilityAddTraits(.isButton)
            if open {
                VStack(alignment: .leading, spacing: 14) {
                    if !c.meters.isEmpty {
                        HStack(spacing: 12) { ForEach(Array(c.meters.enumerated()), id: \.offset) { n, m in MeterView(m: m, key: "\(c.id)-\(n)") } }
                    }
                    if let n = c.notice { NoticeLine(text: n) }
                    Services(model: model, c: c)
                    if c.isHardware { SoftButton(text: "Open \(c.name)", full: true) { model.open(.machine(c.id)) } }
                }
                .padding(.horizontal, 20).padding(.bottom, 20).padding(.top, 2)
                .transition(.reveal)
            }
        }
        .background(open ? Theme.bg.opacity(0.5) : .clear)
        .clipped()
    }
}

struct NoticeLine: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            ph("moon").resizable().frame(width: 16, height: 16)
            Text(text).font(figtree(13.5, .regular, relativeTo: .footnote))
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.mist.ink)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.mist.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct Services: View {
    let model: AppModel
    let c: MachineCard
    private var more: Bool { model.openMore[c.id] ?? false }

    var body: some View {
        VStack(spacing: 4) {
            if c.isEmpty { QuietLine(text: "Nothing is watched on it.") }
            ForEach(c.trouble) { SvcRow(model: model, r: $0) }
            ForEach(c.fine) { SvcRow(model: model, r: $0) }
            if more { ForEach(c.moreFine) { SvcRow(model: model, r: $0) } }
            if !c.moreFine.isEmpty {
                Button { withAnimation(Theme.ease) { model.openMore[c.id] = !more } } label: {
                    Text(more ? "Show fewer" : "and \(c.moreFine.count) more that are fine")
                        .font(figtree(14, .semibold, relativeTo: .subheadline)).foregroundStyle(Theme.brand)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.horizontal, 12).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if let q = c.quietLine { QuietLine(text: q, icon: "circle-dashed") }
        }
    }
}

struct SvcRow: View {
    let model: AppModel
    let r: ServiceLine
    var body: some View {
        let tone = Theme.tone(r.level)
        Button { model.open(.service(r.id, from: nil)) } label: {
            HStack(spacing: 12) {
                Pip(tone: tone)
                Text(r.name).font(figtree(13.5, .medium, relativeTo: .subheadline)).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer()
                if tone == .ok { Text(r.level.word).font(figtree(12, .regular, relativeTo: .caption)).foregroundStyle(Theme.mute) } else { TagView(text: r.level.word, tone: tone) }
            }
            .padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 46)
            .background(Theme.panel.mix(Theme.bg, 0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityHint("Opens the service")
    }
}

// MARK: - A machine

struct MachineView: View {
    let model: AppModel
    let id: String
    var back: () -> Void

    var body: some View {
        if model.selectedState.snapshot == nil {
            NoSnapshot(model: model, title: "Machine", back: back)
        } else {
            TimelineView(.periodic(from: .now, by: 5)) { ctx in content(now: ctx.date) }
        }
    }

    @ViewBuilder private func content(now: Date) -> some View {
        let snap = model.selectedState.snapshot!
        let f = model.freshness(model.selectedState, now: now)
        if let c = Home.machine(snap, id: id, now: now, hot: Double(model.settings.hotPercent), shown: model.settings.fineShown) {
            let tone = cardTone(c)
            let names = Screens.publicNames(snap)
            let mine = ((snap.inbox?.needsYou ?? []) + (snap.inbox?.soon ?? []) + (snap.inbox?.snoozed ?? [])).filter { $0.machine == c.name }.map { Words.card($0, names: names, now: now) }
            let lede = c.planned ? "\(c.notice ?? "Planned downtime"). That is expected, so Dokkit does not worry about it."
                : c.isDown ? "It has stopped reporting."
                : !mine.isEmpty ? Words.plural(mine.count, "thing needs", "things need") + " a look here." : "All good. \(c.countLine)."
            StatementPage(tone: tone, top: { ServerTop(model: model, title: "Machine", back: back) },
                          hero: HeroModel(tone: tone, icon: c.planned ? "moon" : Theme.icon(tone), big: c.name, eyebrow: c.os, tag: c.word, lede: lede, extra: c.status,
                                          age: !f.isWarning && f.detail == nil ? f.text : nil),
                          onRefresh: { await model.refresh() }) {
                if f.isWarning || f.detail != nil { Banner(f: f) }
                if !c.meters.isEmpty {
                    BigCard {
                        HStack(spacing: 0) {
                            ForEach(Array(c.meters.enumerated()), id: \.offset) { n, m in
                                if n > 0 { Rectangle().fill(Theme.line.opacity(0.75)).frame(width: 1) }
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(m.label + (m.subject.map { " \($0)" } ?? "")).font(figtree(13, .semibold, relativeTo: .footnote)).foregroundStyle(Theme.mute).lineLimit(1)
                                    Tick(value: m.percent, key: "v-\(id)-\(n)", format: { "\($0)%" }, font: figtree(30, .heavy, relativeTo: .title), color: m.isHot ? Theme.amber.ink : Theme.ink)
                                    MeterBar(fraction: m.fraction, color: m.isHot ? Theme.amber.solid : Theme.sage.solid, key: "mp-\(id)-\(n)")
                                }
                                .padding(.leading, 18).padding(.trailing, 12).padding(.vertical, 18)
                                .accessibilityElement(children: .ignore).accessibilityLabel(m.spoken)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                } else if c.isHardware {
                    QuietLine(text: c.isDown ? "Not reporting, so no readings." : "No readings in this snapshot.")
                }
                if let day = c.lastDay {
                    BigCard {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("The last day").font(figtree(18, .bold, relativeTo: .headline)).foregroundStyle(Theme.ink)
                            Text("The last 24 hours.").font(figtree(14, .regular, relativeTo: .subheadline)).foregroundStyle(Theme.mute).padding(.bottom, 16)
                            Strip(cells: day, key: "machine-\(id)", label: c.name)
                            Axis(words: ["24 h ago", "12 h ago", "Now"])
                            Legend().padding(.top, 12)
                        }
                        .padding(20)
                    }
                }
                if !mine.isEmpty {
                    Label2(text: "Needs a look")
                    ForEach(mine) { i in IssueCardView(c: i) { if let s = i.serviceID { model.open(.service(s, from: i.id)) } } }
                }
                Label2(text: "Services")
                BigCard { Services(model: model, c: c).padding(10) }
            }
        } else {
            StatementPage(tone: .quiet, top: { ServerTop(model: model, title: "Machine", back: back) },
                          hero: HeroModel(tone: .quiet, icon: "info", big: "Not in this snapshot", eyebrow: "Machine", lede: "The newest snapshot no longer lists this machine.")) {}
        }
    }
}

extension Screens {
    static func publicNames(_ s: Snapshot) -> [String: String] {
        var out: [String: String] = [:]
        for m in s.machines ?? [] { for svc in m.services ?? [] { out[svc.id] = svc.name } }
        for svc in s.services ?? [] { out[svc.id] = svc.name }
        return out
    }
}
