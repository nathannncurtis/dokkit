import SwiftUI
import DokkitKit

struct ServiceView: View {
    let model: AppModel
    let id: String

    var body: some View {
        ServerScreen(model: model, title: "Service", showsPicker: false) { snap, now in
            if let v = Screens.service(snap, id: id, now: now) {
                ServiceBody(v: v)
            } else {
                Notice(title: "Not in this snapshot", text: "The newest snapshot no longer lists this service.", systemImage: "questionmark.circle")
            }
        }
    }
}

private struct ServiceBody: View {
    let v: ServiceScreen

    var body: some View {
        Card(title: v.name, detail: v.machine) {
            VStack(alignment: .leading, spacing: 8) {
                StateMark(level: v.level)
                if let n = v.note { Text(n).font(.subheadline).foregroundStyle(Theme.mute) }
                let version: String? = v.version.map { "version \($0)" }
                let candidates: [String?] = [v.kind, version, v.environment]
                let meta: [String] = candidates.compactMap { $0 }
                if !meta.isEmpty { Text(meta.joined(separator: " · ")).font(.footnote).foregroundStyle(Theme.mute) }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
        if let issue = v.issue {
            Card(title: "Open issue", detail: issue.shortId) {
                IssueRowView(row: issue, linked: false)
                ForEach(Array(v.history.enumerated()), id: \.offset) { _, h in
                    RowDivider()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(h.text).font(.subheadline)
                        if let w = h.when { Text(w).font(.footnote).foregroundStyle(Theme.mute) }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        if !v.checks.isEmpty {
            Card(title: "Checks", detail: "\(v.checks.count)") {
                ForEach(Array(v.checks.enumerated()), id: \.offset) { i, c in
                    if i > 0 { RowDivider() }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(c.name).font(.body.weight(.medium))
                        StateMark(level: c.level)
                        if let n = c.note { Text(n).font(.footnote).foregroundStyle(Theme.mute) }
                        if let t = c.checked { Text("Checked \(t)").font(.footnote).foregroundStyle(Theme.mute) }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        if !v.job.isEmpty {
            Card(title: "Job") {
                ForEach(Array(v.job.enumerated()), id: \.offset) { i, pair in
                    if i > 0 { RowDivider() }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pair[0]).font(.footnote).foregroundStyle(Theme.mute)
                        Text(pair[1]).font(.subheadline)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        if v.chart.contains(where: { $0 != nil }) {
            Card(title: "Last 24 hours") { Spark(values: v.chart).frame(height: 56).padding(16) }
        }
        if !v.logs.isEmpty {
            Card(title: "Last log lines", detail: "\(v.logs.count)") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(v.logs.enumerated()), id: \.offset) { _, line in
                        Text(line.text)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(line.isError ? Theme.bad : Theme.ink)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
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
            let candidates: [String?] = [row.serviceName, row.machine, row.since, row.count]
            let meta: [String] = candidates.compactMap { $0 }.filter { !$0.isEmpty }
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
