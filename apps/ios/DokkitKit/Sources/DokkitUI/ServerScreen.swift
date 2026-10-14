import SwiftUI
import DokkitKit

struct ServerScreen<Content: View>: View {
    let model: AppModel
    let title: String
    var showsPicker = true
    @ViewBuilder var content: (Snapshot, Date) -> Content

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            let state = model.selectedState
            ScrollView {
                VStack(spacing: 16) {
                    if model.servers.isEmpty {
                        Notice(
                            title: "No server paired",
                            text: "In the Dokkit web interface open Settings, Phones, Add a phone. It shows a QR code once. Then choose Servers here and scan it.",
                            systemImage: "qrcode.viewfinder")
                    } else {
                        AgeBanner(freshness: Freshness.make(madeAt: state.madeAt, hasSnapshot: state.snapshot != nil, problem: state.problem, now: ctx.date))
                        if let snap = state.snapshot {
                            content(snap, ctx.date)
                        } else {
                            Notice(
                                title: "No snapshot yet",
                                text: "This phone is paired. The server uploads a snapshot about once a minute while a phone is paired; pull down to look again.",
                                systemImage: "hourglass")
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.bg)
            .refreshable { await model.refresh() }
        }
        .navigationTitle(model.selected?.name ?? title)
        .toolbar {
            if showsPicker, model.servers.count > 1 {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        ForEach(model.servers) { s in
                            Button { model.selectedID = s.id } label: {
                                if s.id == model.selected?.id { Label(s.name, systemImage: "checkmark") } else { Text(s.name) }
                            }
                        }
                    } label: {
                        Label("Switch server", systemImage: "server.rack").frame(minWidth: 44, minHeight: 44)
                    }
                }
            }
        }
    }
}
