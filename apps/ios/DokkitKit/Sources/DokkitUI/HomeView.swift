import SwiftUI
import DokkitKit

struct HomeView: View {
    let model: AppModel

    var body: some View {
        ServerScreen(model: model, title: "Home") { snap, now in
            HomeContent(model: model, home: Home.make(snap, now: now))
        }
    }
}

struct HomeContent: View {
    let model: AppModel
    let home: HomeScreen

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TopBoxView(box: home.top)
            if let line = home.snoozedLine {
                Text(line).font(.footnote).foregroundStyle(Theme.mute).padding(.horizontal, 4)
            }
            ForEach(home.machines) { card in
                MachineCardView(model: model, card: card)
            }
            if !home.groups.isEmpty {
                Text("Not on a machine")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.mute)
                    .padding(.horizontal, 4).padding(.top, 8)
                    .accessibilityAddTraits(.isHeader)
                ForEach(home.groups) { card in
                    MachineCardView(model: model, card: card)
                }
            }
        }
    }
}

struct TopBoxView: View {
    let box: TopBox

    var body: some View {
        switch box {
        case .attention(let title, let lines, let urgent):
            attention(title: title, lines: lines, tint: urgent ? Theme.bad : Theme.warn, urgent: urgent)
        case .fine(let headline, let detail):
            fine(headline: headline, detail: detail)
        }
    }

    private func attention(title: String, lines: [IssueLine], tint: Color, urgent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(title, systemImage: urgent ? "exclamationmark.octagon.fill" : "clock.fill")
                .font(.headline).foregroundStyle(tint)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .accessibilityAddTraits(.isHeader)
            ForEach(lines) { line in
                Divider().overlay(tint.opacity(0.3))
                issueRow(line)
            }
        }
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(tint.opacity(0.45)))
    }

    @ViewBuilder private func issueRow(_ line: IssueLine) -> some View {
        let label = HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(line.title).font(.body.weight(.semibold)).foregroundStyle(Theme.ink).multilineTextAlignment(.leading)
                if !line.detail.isEmpty {
                    Text(line.detail).font(.footnote).foregroundStyle(Theme.mute).multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 8)
            if line.serviceID != nil {
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Theme.mute).accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .contentShape(Rectangle())
        if let id = line.serviceID {
            NavigationLink(value: id) { label }.buttonStyle(.plain)
        } else {
            label.accessibilityElement(children: .combine)
        }
    }

    private func fine(headline: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.title).foregroundStyle(Theme.ok).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(.headline).foregroundStyle(Theme.ink)
                Text(detail).font(.footnote).foregroundStyle(Theme.mute)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.ok.opacity(0.14), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.ok.opacity(0.35)))
        .accessibilityElement(children: .combine)
    }
}

struct MachineCardView: View {
    let model: AppModel
    let card: MachineCard

    private var isOpen: Bool { model.openMachines[card.id] ?? false }
    private var showsAll: Bool { model.openMore[card.id] ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { model.openMachines[card.id] = !isOpen } label: { header }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(card.summary)
                .accessibilityValue(isOpen ? "Opened" : "Closed")
                .accessibilityHint(isOpen ? "Closes the list of what is watched" : "Opens the list of what is watched")
                .accessibilityAddTraits(.isButton)
            if isOpen {
                Divider().overlay(Theme.line)
                opened
            }
        }
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.line))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StateMark(level: card.mark, showsWord: false)
                Text(card.name).font(.headline).foregroundStyle(Theme.ink).multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Theme.mute)
                    .rotationEffect(.degrees(isOpen ? 90 : 0)).accessibilityHidden(true)
            }
            if let status = card.status {
                Text(status).font(.subheadline.weight(card.isDown ? .semibold : .regular))
                    .foregroundStyle(card.isDown ? Theme.bad : Theme.mute)
            }
            if !card.meters.isEmpty { MetersRow(meters: card.meters) }
            Text(card.countLine).font(.footnote).foregroundStyle(Theme.mute)
            if let notice = card.notice {
                Text(notice).font(.footnote).foregroundStyle(Theme.mute)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private var opened: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(card.trouble) { item in ServiceRowView(item: item) }
            ForEach(card.fine) { item in ServiceRowView(item: item) }
            if !card.moreFine.isEmpty {
                if showsAll {
                    ForEach(card.moreFine) { item in ServiceRowView(item: item) }
                }
                Button { model.openMore[card.id] = !showsAll } label: {
                    Text(showsAll ? "Show fewer" : "and \(card.moreFine.count) more that are fine")
                        .font(.subheadline).foregroundStyle(Theme.mute)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)
            }
            if let q = card.quietLine {
                Text(q).font(.footnote).foregroundStyle(Theme.mute).padding(.vertical, 8)
            }
            if card.isEmpty {
                Text("Nothing is watched on it.").font(.footnote).foregroundStyle(Theme.mute).padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 4)
    }
}

struct ServiceRowView: View {
    let item: ServiceLine

    var body: some View {
        NavigationLink(value: item.id) {
            HStack(spacing: 8) {
                Text(item.name).font(.subheadline).foregroundStyle(Theme.ink).multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                StateMark(level: item.level)
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Theme.mute).accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct MetersRow: View {
    let meters: [Meter]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(meters, id: \.label) { MeterView(meter: $0) }
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(meters, id: \.label) { MeterView(meter: $0) }
            }
        }
    }
}

struct MeterView: View {
    let meter: Meter

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(meter.label).font(.caption).foregroundStyle(Theme.mute)
                Spacer(minLength: 4)
                Text("\(meter.percent)%")
                    .font(.caption.monospacedDigit().weight(meter.isHot ? .semibold : .regular))
                    .foregroundStyle(meter.isHot ? Theme.warn : Theme.mute)
            }
            Capsule().fill(Theme.chip).frame(height: 5)
                .overlay(alignment: .leading) {
                    GeometryReader { g in
                        Capsule().fill(meter.isHot ? Theme.warn : Theme.mute)
                            .frame(width: g.size.width * CGFloat(meter.fraction))
                    }
                }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(meter.spoken)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline).foregroundStyle(Theme.brandInk)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Theme.brand.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct FirstRunView: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "server.rack")
                    .font(.largeTitle).foregroundStyle(Theme.brandInk)
                    .frame(width: 72, height: 72)
                    .background(Theme.brand, in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityHidden(true)
                Text("Dokkit").font(.largeTitle.bold()).foregroundStyle(Theme.ink)
                VStack(alignment: .leading, spacing: 10) {
                    Text("This is a read-only view of your Dokkit server.")
                    Text("Alerts still reach you the usual way.")
                    Text("Nothing here can change anything.")
                }
                .font(.body).foregroundStyle(Theme.ink)
                Text("The code is in the Dokkit web interface: Settings, Phones, Add a phone.")
                    .font(.subheadline).foregroundStyle(Theme.mute)
                Button("Scan the code") { model.pasteOnly = false; model.addingServer = true }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Paste the code instead") { model.pasteOnly = true; model.addingServer = true }
                    .font(.subheadline).foregroundStyle(Theme.brand)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .padding(24).padding(.top, 32)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Theme.bg.ignoresSafeArea())
    }
}
