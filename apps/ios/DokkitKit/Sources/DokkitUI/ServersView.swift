import SwiftUI
import DokkitKit

struct ServersView: View {
    let model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { ctx in
            let list = model.servers
            let cur = model.selected
            let hero = list.isEmpty
                ? HeroModel(tone: .quiet, icon: "device-mobile", big: "No server paired", eyebrow: "Servers",
                            lede: "In the Dokkit web interface open Settings, Phones, Add a phone. It shows a QR code once. Choose Add a server below and scan it.")
                : HeroModel(tone: .brand, icon: "hard-drives", big: "", bigNumber: (list.count, "srv-n", "server paired", "servers paired"), eyebrow: "Servers",
                            lede: "Showing \(cur?.name ?? ""). Remove one and its key, token and saved snapshot leave this phone.",
                            age: model.freshness(model.selectedState, now: ctx.date).text)
            StatementPage(tone: list.isEmpty ? .quiet : .brand, top: { TopBar(title: "Servers") { EmptyView() } }, hero: hero, onRefresh: { await model.refresh() }) {
                if !list.isEmpty {
                    BigCard {
                        CardHead(title: "Paired servers", detail: "\(list.count)")
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, s in
                            if i > 0 { Rectangle().fill(Theme.line.opacity(0.75)).frame(height: 1) }
                            row(s, current: s.id == cur?.id, now: ctx.date)
                        }
                        Spacer().frame(height: 8)
                    }
                }
                PrimaryButton(text: "Add a server", icon: "plus") { model.serversPath.append(.add(paste: false)) }
            }
        }
        .confirmationDialog(
            "Remove \(model.removing?.name ?? "this server") from this phone?",
            isPresented: Binding(get: { model.removing != nil }, set: { if !$0 { model.removing = nil } }), titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let s = model.removing { Task { await model.remove(s.id) } }
                model.removing = nil
            }
        } message: {
            Text("Its key, its token and its saved snapshot are deleted from this phone. Nothing changes on the server.")
        }
    }

    private func row(_ s: PairedServer, current: Bool, now: Date) -> some View {
        let f = model.freshness(model.states[s.id] ?? ServerState(), now: now)
        return HStack(spacing: 4) {
            Button { withAnimation(Theme.ease) { model.selectedID = s.id } } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(s.name).font(figtree(16, .bold)).foregroundStyle(Theme.ink)
                        if current { TagView(text: "Showing", tone: .brand) }
                    }
                    Text(URL(string: s.relay)?.host ?? s.relay).font(figtree(12.5, .medium, relativeTo: .caption)).foregroundStyle(Theme.mute)
                    Text(f.text).font(figtree(13, .regular, relativeTo: .footnote)).foregroundStyle(f.isWarning ? Theme.amber.ink : Theme.mute)
                    if let d = f.detail { Text(d).font(figtree(13, .regular, relativeTo: .footnote)).foregroundStyle(Theme.amber.ink) }
                }
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                .padding(.horizontal, 20).padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows this server")
            Button { model.removing = s } label: {
                ph("trash").resizable().frame(width: 22, height: 22).foregroundStyle(Theme.rose.ink).frame(width: 44, height: 44)
            }
            .buttonStyle(PressStyle(scale: 0.9))
            .accessibilityLabel("Remove \(s.name)")
            .padding(.trailing, 8)
        }
    }
}

struct AddServerView: View {
    let model: AppModel
    let paste: Bool
    let scanner: ScannerBuilder
    var done: () -> Void

    var body: some View {
        let hero = HeroModel(tone: .brand, icon: paste ? "clipboard-text" : "qr-code", big: paste ? "Paste the code" : "Scan the code", eyebrow: "Add a server",
                             lede: paste ? "Paste the code from the Dokkit web interface, under Settings, Phones, Add a phone."
                                 : "Scan the QR code in the Dokkit web interface under Settings, Phones, Add a phone. It is shown once.")
        StatementPage(tone: .brand, top: { TopBar(title: "Add a server", back: done, backIcon: "x", backLabel: "Cancel") { EmptyView() } }, hero: hero) {
            if !paste {
                scanner { code in Task { await submit(code) } }
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            if let e = model.addError {
                HStack(alignment: .top, spacing: 12) {
                    ph("warning").resizable().frame(width: 20, height: 20).accessibilityLabel("Warning")
                    Text(e).font(figtree(14, .regular, relativeTo: .subheadline))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.amber.ink)
                .padding(.horizontal, 16).padding(.vertical, 14)
                .background(Theme.amber.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            Text(paste ? "Paste the code" : "Or paste the code").font(figtree(15, .bold, relativeTo: .subheadline)).foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 6)
            TextField("dokkit-phone:1:...", text: Binding(get: { model.pasted }, set: { model.pasted = $0 }), axis: .vertical)
                .font(figtree(13.5, .medium, relativeTo: .footnote))
                .plainCode()
                .lineLimit(3...8)
                .padding(14)
                .frame(minHeight: 84, alignment: .topLeading)
                .background(Theme.panel.opacity(0.85), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line))
            PrimaryButton(text: "Add", enabled: !model.pasted.isEmpty && !model.addWorking) { Task { await submit(model.pasted) } }
        }
    }

    private func submit(_ code: String) async {
        guard !model.addWorking else { return }
        model.addWorking = true
        defer { model.addWorking = false }
        model.addError = await model.add(code: code)
        if model.addError == nil {
            model.pasted = ""
            done()
        }
    }
}

extension View {
    /// A pasted code is taken as typed: no capitals, no corrections.
    @ViewBuilder func plainCode() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        autocorrectionDisabled()
        #endif
    }
}
