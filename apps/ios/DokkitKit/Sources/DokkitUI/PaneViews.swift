import SwiftUI
import DokkitKit

/// The right pane of the Servers tab when unfolded: the server being shown, read-only.
struct ServerDetailView: View {
    let model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { ctx in
            if let s = model.selected {
                content(s, now: ctx.date)
            } else {
                Placeholder(icon: "hard-drives", title: "No server yet", text: "Add one on the left.")
            }
        }
    }

    @ViewBuilder private func content(_ s: PairedServer, now: Date) -> some View {
        let st = model.selectedState
        let f = model.freshness(st, now: now)
        StatementPage(tone: .brand, top: { TopBar(title: s.name) { EmptyView() } },
                      hero: HeroModel(tone: .brand, icon: "hard-drives", big: s.name, eyebrow: "Showing",
                                      lede: "Read-only. Nothing here can change the server.",
                                      age: !f.isWarning && f.detail == nil ? f.text : nil),
                      onRefresh: { await model.refresh() }) {
            if f.isWarning || f.detail != nil { Banner(f: f) }
            if let snap = st.snapshot {
                let h = Home.make(snap, now: now, hot: Double(model.settings.hotPercent), shown: model.settings.fineShown)
                let down = h.needs.contains { $0.tone == .down }
                Figures(items: [
                    Figure(value: h.needs.count, word: "need you", tone: down ? .down : .degraded, key: "sd-n-\(s.id)"),
                    Figure(value: h.soon.count, word: "coming up", tone: .soon, key: "sd-s-\(s.id)"),
                    Figure(value: h.fineServices, word: "fine", tone: .ok, key: "sd-f-\(s.id)"),
                ])
            }
            BigCard {
                fact("Relay", URL(string: s.relay)?.host ?? s.relay)
                Rectangle().fill(Theme.line.opacity(0.75)).frame(height: 1)
                fact("Paired", s.addedAt.formatted(date: .abbreviated, time: .shortened))
                Rectangle().fill(Theme.line.opacity(0.75)).frame(height: 1)
                fact("Snapshot", f.text)
            }
            PrimaryButton(text: "Show it on Home", icon: "house") { withAnimation(Theme.travel) { model.tab = 0 } }
            Button { model.removing = s } label: {
                HStack(spacing: 8) {
                    ph("trash").resizable().frame(width: 18, height: 18)
                    Text("Remove from this phone").font(figtree(15, .semibold, relativeTo: .body))
                }
                .foregroundStyle(Theme.rose.ink)
                .padding(.horizontal, 18).padding(.vertical, 11)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("Remove \(s.name) from this phone")
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(figtree(14, .semibold, relativeTo: .subheadline)).foregroundStyle(Theme.mute)
            Spacer(minLength: 8)
            Text(value).font(figtree(15, .medium, relativeTo: .body)).foregroundStyle(Theme.ink).multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 20).padding(.vertical, 14).frame(minHeight: 52)
        .accessibilityElement(children: .combine)
    }
}

/// A quiet right pane for when there is nothing to show beside the list.
struct Placeholder: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        VStack(spacing: 12) {
            ToneCircle(tone: .quiet, icon: icon, size: 44)
            Text(title).font(figtree(19, .bold, relativeTo: .title3)).foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
            Text(text).font(figtree(15, .regular, relativeTo: .body)).foregroundStyle(Theme.mute)
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: 320)
        .background(Theme.panel, in: shape)
        .overlay(shape.strokeBorder(Theme.line))
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Wash(tone: .quiet).ignoresSafeArea())
    }
}
