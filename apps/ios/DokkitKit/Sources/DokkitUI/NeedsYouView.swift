import SwiftUI
import DokkitKit

struct NeedsYouView: View {
    let model: AppModel

    var body: some View {
        ServerScreen(model: model, title: "Needs you") { snap, now in
            let screen = Screens.needsYou(snap, now: now)
            if screen.nothingNeedsYou {
                Notice(title: "Everything is fine", text: screen.fine.map { "\($0.prefix(1).uppercased() + $0.dropFirst())." } ?? "Nothing needs you.", systemImage: "checkmark.circle")
            }
            ForEach(screen.sections) { section in
                Card(title: section.title, detail: "\(section.rows.count)") {
                    ForEach(Array(section.rows.enumerated()), id: \.element.id) { i, row in
                        if i > 0 { RowDivider() }
                        IssueRowView(row: row)
                    }
                }
            }
            if !screen.notWatched.isEmpty {
                Card(title: "Not watched", detail: "\(screen.notWatched.count)") {
                    ForEach(Array(screen.notWatched.enumerated()), id: \.element.id) { i, row in
                        if i > 0 { RowDivider() }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name).font(.body.weight(.medium))
                            Text([row.machine, row.kind, row.saw].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.footnote).foregroundStyle(Theme.mute)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 8)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if !screen.nothingNeedsYou, let fine = screen.fine {
                Text(fine.prefix(1).uppercased() + fine.dropFirst() + ".").font(.footnote).foregroundStyle(Theme.mute)
            }
        }
    }
}

struct IssueRowView: View {
    let row: IssueRow
    var linked = true

    var body: some View {
        let inner = VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                StateMark(level: row.level)
                Spacer()
                Text(row.shortId).font(.caption.monospaced()).foregroundStyle(Theme.mute)
            }
            Text(row.title).font(.body.weight(.semibold)).foregroundStyle(Theme.ink).multilineTextAlignment(.leading)
            if let note = row.note { Text(note).font(.subheadline).foregroundStyle(Theme.mute).multilineTextAlignment(.leading) }
            let meta = [row.serviceName, row.machine.isEmpty ? nil : row.machine, row.since, row.count].compactMap { $0 }
            if !meta.isEmpty { Text(meta.joined(separator: " · ")).font(.footnote).foregroundStyle(Theme.mute) }
            if !row.flags.isEmpty {
                HStack { ForEach(row.flags, id: \.self) { Tag(text: $0) } }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .contentShape(Rectangle())

        if linked, let id = row.serviceID {
            NavigationLink(value: id) { inner }.buttonStyle(.plain)
        } else {
            inner
        }
    }
}
