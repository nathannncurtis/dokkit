import SwiftUI
import DokkitKit

struct ServersView: View {
    let model: AppModel
    let scanner: ScannerBuilder

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            ScrollView {
                VStack(spacing: 16) {
                    if model.servers.isEmpty {
                        Notice(
                            title: "No server paired",
                            text: "In the Dokkit web interface open Settings, Phones, Add a phone. It shows a QR code once. Choose Add a server below and scan it.",
                            systemImage: "qrcode.viewfinder")
                    } else {
                        Card(title: "Paired servers", detail: "\(model.servers.count)") {
                            ForEach(Array(model.servers.enumerated()), id: \.element.id) { i, s in
                                if i > 0 { RowDivider() }
                                row(s, now: ctx.date)
                            }
                        }
                    }
                    Button { model.pasteOnly = false; model.addingServer = true } label: {
                        Label("Add a server", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                .padding(16)
            }
            .background(Theme.bg)
            .refreshable { await model.refresh() }
        }
        .navigationTitle("Servers")
        .confirmationDialog(
            "Remove \(model.removing?.name ?? "this server") from this phone?", isPresented: Binding(get: { model.removing != nil }, set: { if !$0 { model.removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let s = model.removing { Task { await model.remove(s.id) } }
                model.removing = nil
            }
        } message: {
            Text("Its key, its token and its saved snapshot are deleted from this phone. Nothing changes on the server.")
        }
    }

    private func row(_ s: PairedServer, now: Date) -> some View {
        let st = model.states[s.id] ?? ServerState()
        let fresh = Freshness.make(madeAt: st.madeAt, hasSnapshot: st.snapshot != nil, problem: st.problem, now: now)
        let current = s.id == model.selected?.id
        return HStack(spacing: 8) {
            Button { model.selectedID = s.id } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(s.name).font(.body.weight(.semibold)).foregroundStyle(Theme.ink)
                        if current { Tag(text: "Showing") }
                    }
                    Text(URL(string: s.relay)?.host ?? s.relay).font(.footnote).foregroundStyle(Theme.mute)
                    Text(fresh.text).font(.footnote).foregroundStyle(fresh.isWarning ? Theme.warn : Theme.mute)
                    if let d = fresh.detail { Text(d).font(.footnote).foregroundStyle(Theme.warn) }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows this server")
            Button { model.removing = s } label: {
                Image(systemName: "trash").frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain).foregroundStyle(Theme.bad)
            .accessibilityLabel("Remove \(s.name)")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }
}

struct AddServerSheet: View {
    let model: AppModel
    let scanner: ScannerBuilder
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Scan the QR code in the Dokkit web interface under Settings, Phones, Add a phone. It is shown once.")
                        .font(.subheadline).foregroundStyle(Theme.mute)
                    if !model.pasteOnly {
                        scanner { code in Task { await submit(code) } }
                            .frame(height: 300).clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    if let error = model.addError {
                        Label(error, systemImage: "exclamationmark.triangle.fill").font(.subheadline).foregroundStyle(Theme.warn)
                    }
                    Text(model.pasteOnly ? "Paste the code" : "Or paste the code").font(.footnote.weight(.semibold))
                    TextField("dokkit-phone:1:...", text: Binding(get: { model.pasted }, set: { model.pasted = $0 }), axis: .vertical)
                        .font(.system(.footnote, design: .monospaced))
                        .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                        .frame(minHeight: 44)
                    Button("Add") { Task { await submit(model.pasted) } }
                        .buttonStyle(.bordered).frame(minHeight: 44).disabled(model.pasted.isEmpty || model.addWorking)
                }
                .padding(16)
            }
            .background(Theme.bg)
            .navigationTitle("Add a server")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.frame(minHeight: 44) } }
        }
        .tint(Theme.brand)
    }

    private func submit(_ code: String) async {
        guard !model.addWorking else { return }
        model.addWorking = true
        defer { model.addWorking = false }
        model.addError = await model.add(code: code)
        if model.addError == nil { model.pasted = ""; dismiss() }
    }
}
