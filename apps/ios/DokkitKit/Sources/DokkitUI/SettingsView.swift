import SwiftUI
import DokkitKit

private struct Setting {
    let title: String
    let sub: String
    let defaultText: String
    let same: (AppSettings, AppSettings) -> Bool
    let copy: (AppSettings, AppSettings) -> AppSettings
    let control: (Binding<AppSettings>) -> AnyView
}

private func number(_ title: String, _ sub: String, _ before: String, _ after: String, _ range: ClosedRange<Int>, step: Int, _ kp: WritableKeyPath<AppSettings, Int>) -> Setting {
    let d = AppSettings()[keyPath: kp]
    return Setting(
        title: title, sub: sub, defaultText: "\(before) \(d) \(after)".replacingOccurrences(of: " %", with: "%"),
        same: { $0[keyPath: kp] == $1[keyPath: kp] },
        copy: { var a = $0; a[keyPath: kp] = $1[keyPath: kp]; return a },
        control: { b in AnyView(Stepper2(value: Binding(get: { b.wrappedValue[keyPath: kp] }, set: { b.wrappedValue[keyPath: kp] = $0 }), range: range, step: step, before: before, after: after, title: title)) })
}

private func choice<T: Equatable & Sendable>(_ title: String, _ sub: String, _ options: [T], word: @escaping @Sendable (T) -> String, _ kp: WritableKeyPath<AppSettings, T>) -> Setting {
    Setting(
        title: title, sub: sub, defaultText: word(AppSettings()[keyPath: kp]),
        same: { $0[keyPath: kp] == $1[keyPath: kp] },
        copy: { var a = $0; a[keyPath: kp] = $1[keyPath: kp]; return a },
        control: { b in AnyView(Choices(options: options, value: Binding(get: { b.wrappedValue[keyPath: kp] }, set: { b.wrappedValue[keyPath: kp] = $0 }), word: word)) })
}

private struct Group {
    let title: String
    let sub: String
    let icon: String
    let rows: [Setting]
}

@MainActor private let groups: [Group] = [
    Group(title: "Look", sub: "Light or dark.", icon: "palette", rows: [
        choice("Theme", "Light or dark. Follows the phone until you pick one.", ThemeChoice.allCases, word: { $0.word }, \.theme),
    ]),
    Group(title: "Snapshots", sub: "How often the app looks, and when it warns.", icon: "arrows-clockwise", rows: [
        number("Look for a new snapshot", "While the app is in front. It also looks when opened and when you pull down.", "Every", "seconds", AppSettings.Limits.refresh, step: 5, \.refreshSeconds),
        number("Snapshot is late", "Past this age the snapshot gets a warning.", "After", "minutes", AppSettings.Limits.late, step: 1, \.lateMinutes),
        number("Relay timeout", "How long to wait for the relay before saying it could not be reached.", "Wait", "seconds", AppSettings.Limits.relayWait, step: 5, \.relayWaitSeconds),
    ]),
    Group(title: "What the screens show", sub: "Meters and long lists.", icon: "squares-four", rows: [
        number("Busy meters", "A processor, memory or disk meter turns amber above this.", "Above", "%", AppSettings.Limits.hot, step: 5, \.hotPercent),
        number("Fine services listed", "On a machine, the rest fold under \"and more that are fine\".", "Show", "then fold", AppSettings.Limits.fineShown, step: 1, \.fineShown),
    ]),
    Group(title: "Unlock", sub: "When the app asks again.", icon: "lock-simple", rows: [
        choice("Ask to unlock", "Face ID or the passcode before anything shows.", LockAfter.allCases, word: { $0.word }, \.lockAfter),
    ]),
]

struct SettingsView: View {
    let model: AppModel
    @State private var draft = AppSettings()
    @State private var open: Set<Int> = [0]

    var body: some View {
        let n = model.settings.changed
        let hero = HeroModel(tone: .brand, icon: "sliders-horizontal", big: n == 0 ? "All on defaults" : "",
                             bigNumber: n == 0 ? nil : (n, "set-n", "changed", "changed"), eyebrow: "Settings",
                             lede: "Each starts at the value the app has always used, and shows it with a Reset next to it.")
        StatementPage(tone: .brand, top: { TopBar(title: "Settings") { EmptyView() } }, hero: hero) {
            ForEach(Array(groups.enumerated()), id: \.offset) { gi, g in
                let isOpen = open.contains(gi)
                BigCard {
                    Button { withAnimation(Theme.ease) { if isOpen { open.remove(gi) } else { open.insert(gi) } } } label: {
                        HStack(spacing: 12) {
                            ph(g.icon).resizable().frame(width: 18, height: 18).foregroundStyle(Theme.ink)
                                .frame(width: 34, height: 34).background(Theme.brandSoft, in: Circle())
                            VStack(alignment: .leading, spacing: 0) {
                                Text(g.title).font(figtree(17, .bold, relativeTo: .headline)).foregroundStyle(Theme.ink)
                                Text(g.sub).font(figtree(14, .regular, relativeTo: .subheadline)).foregroundStyle(Theme.mute)
                            }
                            Spacer()
                            ph("caret-down").resizable().frame(width: 20, height: 20).foregroundStyle(Theme.mute).rotationEffect(.degrees(isOpen ? 180 : 0))
                        }
                        .padding(.horizontal, 20).padding(.vertical, 16).frame(minHeight: 64).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
                    if isOpen {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(g.rows.enumerated()), id: \.offset) { i, r in
                                if i > 0 { Rectangle().fill(Theme.line).frame(height: 1) }
                                row(r)
                            }
                            Rectangle().fill(Theme.line).frame(height: 1)
                            let dirty = g.rows.contains { !$0.same(draft, model.settings) }
                            HStack {
                                Text(dirty ? "Not saved yet." : "Applies on this phone only.").font(figtree(13, .regular, relativeTo: .footnote))
                                    .foregroundStyle(dirty ? Theme.amber.ink : Theme.mute)
                                Spacer(minLength: 12)
                                PrimaryButton(text: "Save", icon: "check", enabled: dirty) {
                                    model.settings = g.rows.reduce(model.settings) { $1.copy($0, draft) }.clamped()
                                }
                                .frame(width: 120)
                            }
                            .padding(.top, 12)
                        }
                        .padding(.horizontal, 20).padding(.bottom, 18)
                        .transition(.reveal)
                    }
                }
            }
            BigCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("About").font(figtree(17, .bold, relativeTo: .headline)).foregroundStyle(Theme.ink)
                    Text("Dokkit for iPhone. Read-only: it cannot change anything on a server and sends no notifications. It fetches when opened, when you pull down, and on the schedule above while in front.")
                        .font(figtree(14, .regular, relativeTo: .subheadline)).foregroundStyle(Theme.mute)
                }
                .padding(20)
            }
        }
        .onAppear { draft = model.settings }
        .onChange(of: model.settings) { _, s in draft = s }
    }

    private func row(_ r: Setting) -> some View {
        let changed = !r.same(draft, AppSettings())
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(r.title).font(figtree(15.5, .bold, relativeTo: .subheadline)).foregroundStyle(Theme.ink)
                if changed {
                    Text("changed").font(figtree(11, .semibold, relativeTo: .caption2)).foregroundStyle(Theme.brand)
                        .padding(.horizontal, 7).padding(.vertical, 2).background(Theme.brandSoft, in: Capsule())
                }
            }
            Text(r.sub).font(figtree(13.5, .regular, relativeTo: .footnote)).foregroundStyle(Theme.mute).fixedSize(horizontal: false, vertical: true)
            r.control($draft)
            HStack(spacing: 4) {
                Text("Default: \(r.defaultText)").font(figtree(12.5, .regular, relativeTo: .caption)).foregroundStyle(Theme.mute)
                if changed {
                    Button { draft = r.copy(draft, AppSettings()) } label: {
                        Text("Reset").font(figtree(13, .semibold, relativeTo: .footnote)).foregroundStyle(Theme.brand).frame(minHeight: 44).padding(.horizontal, 8)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Reset \(r.title)")
                }
            }
        }
        .padding(.vertical, 14)
    }
}

private struct Stepper2: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let before: String
    let after: String
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Text(before).font(figtree(15, .regular)).foregroundStyle(Theme.ink2)
            HStack(spacing: 0) {
                stepButton("−", "Less \(title)", value > range.lowerBound) { value = max(range.lowerBound, value - step) }
                Text("\(value)").font(figtree(16, .semibold)).foregroundStyle(Theme.ink).frame(minWidth: 44).contentTransition(.numericText(value: Double(value)))
                stepButton("+", "More \(title)", value < range.upperBound) { value = min(range.upperBound, value + step) }
            }
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
            Text(after).font(figtree(15, .regular)).foregroundStyle(Theme.ink2)
        }
        .animation(.snappy, value: value)
    }

    private func stepButton(_ s: String, _ label: String, _ enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(s).font(figtree(20, .semibold)).foregroundStyle(enabled ? Theme.ink : Theme.line).frame(width: 44, height: 44)
        }
        .buttonStyle(.plain).disabled(!enabled).accessibilityLabel(label)
    }
}

private struct Choices<T: Equatable>: View {
    let options: [T]
    @Binding var value: T
    let word: (T) -> String

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                let sel = o == value
                Button { value = o } label: {
                    Text(word(o)).font(figtree(14, .semibold, relativeTo: .subheadline)).foregroundStyle(sel ? Theme.brandInk : Theme.ink2)
                        .padding(.horizontal, 16).frame(minHeight: 44)
                        .background(sel ? Theme.brand : Theme.bg, in: Capsule())
                        .overlay(Capsule().strokeBorder(sel ? Theme.brand : Theme.line))
                }
                .buttonStyle(PressStyle())
                .accessibilityAddTraits(sel ? .isSelected : [])
            }
        }
    }
}

/// A page that is one card in the middle of the screen: first run and the lock.
struct CenterCard<Content: View>: View {
    let tone: Tone
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            StatementCard(tone: tone) { content }
                .padding(.horizontal, 14).padding(.vertical, 24)
                .frame(maxWidth: .infinity, minHeight: 0)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center)
        .background(Wash(tone: tone).ignoresSafeArea())
    }
}

public struct LockCover: View {
    let message: String?
    let unlock: () -> Void

    public init(message: String?, unlock: @escaping () -> Void) {
        self.message = message
        self.unlock = unlock
        Fonts.register()
    }

    public var body: some View {
        let tone: Tone = message != nil ? .degraded : .brand
        CenterCard(tone: tone) {
            HStack(spacing: 12) {
                ph("lock-simple").resizable().frame(width: 22, height: 22).foregroundStyle(Theme.tint(tone).ink)
                    .frame(width: 44, height: 44).background(Theme.panel.opacity(0.8), in: Circle())
                Eyebrow(text: "Dokkit", tone: tone)
            }
            .padding(.bottom, 16)
            BigLine(text: "Dokkit is locked")
            Text(message ?? "Unlock with Face ID or the passcode.").font(figtree(16.5, .regular)).foregroundStyle(Theme.ink2).padding(.top, 10)
            PrimaryButton(text: "Unlock", icon: "fingerprint", action: unlock).padding(.top, 20)
        }
    }
}

struct FirstRunView: View {
    let model: AppModel
    var body: some View {
        CenterCard(tone: .brand) {
            Image("dokkit-mark", bundle: .module).renderingMode(.template).resizable().frame(width: 52, height: 52).foregroundStyle(Theme.brandInk)
                .frame(width: 64, height: 64).background(Theme.brand, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .accessibilityHidden(true)
                .padding(.bottom, 18)
            BigLine(text: "Dokkit")
            Text("A read-only view of your Dokkit server. Alerts still reach you the usual way. Nothing here can change anything.")
                .font(figtree(16.5, .regular)).foregroundStyle(Theme.ink2).padding(.top, 10)
            Text("The code is in the Dokkit web interface: Settings, Phones, Add a phone.")
                .font(figtree(14.5, .regular, relativeTo: .subheadline)).foregroundStyle(Theme.mute).padding(.top, 12)
            PrimaryButton(text: "Scan the code", icon: "qr-code") { model.firstPath.append(.add(paste: false)) }.padding(.top, 18)
            QuietButton(text: "Paste the code instead") { model.firstPath.append(.add(paste: true)) }.padding(.top, 6)
        }
    }
}
