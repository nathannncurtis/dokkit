import SwiftUI
import DokkitKit

struct EverythingView: View {
    let model: AppModel

    var body: some View {
        ServerScreen(model: model, title: "Everything") { snap, _ in
            let machines = Screens.everything(snap)
            if machines.isEmpty {
                Notice(title: "No machines", text: "This snapshot lists no machines.", systemImage: "desktopcomputer")
            }
            ForEach(machines) { m in
                Card {
                    DisclosureGroup(isExpanded: Binding(get: { model.openMachines[m.id] ?? (m.level.rank > 0) }, set: { model.openMachines[m.id] = $0 })) {
                        ForEach(m.services) { svc in
                            RowDivider()
                            NavigationLink(value: svc.id) { ServiceLine(row: svc) }.buttonStyle(.plain)
                        }
                        if m.services.isEmpty {
                            Text("No services").font(.footnote).foregroundStyle(Theme.mute).padding(16)
                        }
                    } label: {
                        MachineHeader(row: m)
                    }
                    .tint(Theme.mute)
                    .padding(.horizontal, 16)
                }
            }
        }
    }
}

struct MachineHeader: View {
    let row: MachineRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.name).font(.body.weight(.semibold)).foregroundStyle(Theme.ink)
                if let os = row.os { Text(os).font(.footnote).foregroundStyle(Theme.mute) }
            }
            StateMark(level: row.level)
            if let n = row.notice { Tag(text: n, warn: row.level == .down) }
            ForEach(row.vitals, id: \.label) { v in
                Text("\(v.label) \(v.percent)%").font(.caption.monospaced()).foregroundStyle(v.isHot ? Theme.warn : Theme.mute)
            }
            if let w = row.nextWindow { Text(w).font(.footnote).foregroundStyle(Theme.mute) }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

struct ServiceLine: View {
    let row: ServiceRow

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name).font(.body).foregroundStyle(Theme.ink).multilineTextAlignment(.leading)
                StateMark(level: row.level)
                let kind: String? = row.kind == "service" ? nil : row.kind
                let candidates: [String?] = [kind, row.version, row.environment]
                let meta: [String] = candidates.compactMap { $0 }
                if !meta.isEmpty { Text(meta.joined(separator: " · ")).font(.footnote).foregroundStyle(Theme.mute) }
                if let n = row.note, row.level.rank > 0 { Text(n).font(.footnote).foregroundStyle(Theme.mute).multilineTextAlignment(.leading) }
            }
            Spacer(minLength: 8)
            if row.chart.contains(where: { $0 != nil }) { Spark(values: row.chart).frame(width: 64) }
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Theme.mute).accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
