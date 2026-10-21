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
        choice("Ask to unlock", "The phone's own unlock, before anything shows.", LockAfter.allCases, word: { $0.word }, \.lockAfter),
    ]),
]

@MainActor private func settingsHero(_ model: AppModel) -> HeroModel {
    let n = model.settings.changed
    return HeroModel(tone: .brand, icon: "sliders-horizontal", big: n == 0 ? "All on defaults" : "",
                     bigNumber: n == 0 ? nil : (n, "set-n", "changed", "changed"), eyebrow: "Settings",
                     lede: "Each starts at the value the app has always used, and shows it with a Reset next to it.")
}

struct SettingsView: View {
    let model: AppModel
    @State private var draft = AppSettings()
    @State private var open: Set<Int> = [0]

    var body: some View {
        StatementPage(tone: .brand, top: { TopBar(title: "Settings") { EmptyView() } }, hero: settingsHero(model)) {
            ForEach(Array(groups.enumerated()), id: \.offset) { gi, g in
                let isOpen = open.contains(gi)
                BigCard {
                    Button { withAnimation(Theme.ease) { if isOpen { open.remove(gi) } else { open.insert(gi) } } } label: {
                        GroupHead(g: g, caret: "caret-down", turned: isOpen)
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
                    if isOpen {
                        GroupRows(model: model, g: g, draft: $draft)
                            .transition(.reveal)
                    }
                }
            }
            AboutCard()
        }
        .onAppear { draft = model.settings }
        .onChange(of: model.settings) { _, s in draft = s }
    }
}

/// The left pane of Settings when unfolded: the groups as a list that picks what the right pane shows.
struct SettingsIndexView: View {
    let model: AppModel

    var body: some View {
        let picked = groups.indices.contains(model.settingsGroup) ? model.settingsGroup : 0
        StatementPage(tone: .brand, top: { TopBar(title: "Settings") { EmptyView() } }, hero: settingsHero(model)) {
            BigCard {
                ForEach(Array(groups.enumerated()), id: \.offset) { gi, g in
                    if gi > 0 { Rectangle().fill(Theme.line).frame(height: 1) }
                    let sel = gi == picked
                    Button { withAnimation(Theme.travel) { model.settingsGroup = gi } } label: {
                        GroupHead(g: g, caret: "caret-right").background(sel ? Theme.brandSoft : .clear)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(sel ? .isSelected : [])
                }
            }
            AboutCard()
        }
    }
}

/// The right pane of Settings when unfolded: one group's rows and its Save.
struct SettingsGroupView: View {
    let model: AppModel
    @State private var draft = AppSettings()

    var body: some View {
        let g = groups[groups.indices.contains(model.settingsGroup) ? model.settingsGroup : 0]
        let hero = HeroModel(tone: .brand, icon: g.icon, big: g.title, eyebrow: "Settings", lede: g.sub)
        StatementPage(tone: .brand, top: { TopBar(title: g.title) { EmptyView() } }, hero: hero) {
            BigCard {
                GroupRows(model: model, g: g, draft: $draft).padding(.top, 6)
            }
        }
        .onAppear { draft = model.settings }
        .onChange(of: model.settings) { _, s in draft = s }
    }
}

private struct GroupHead: View {
    let g: Group
    let caret: String
    var turned = false
    var body: some View {
        HStack(spacing: 12) {
            ph(g.icon).resizable().frame(width: 18, height: 18).foregroundStyle(Theme.ink)
                .frame(width: 34, height: 34).background(Theme.brandSoft, in: Circle())
            VStack(alignment: .leading, spacing: 0) {
                Text(g.title).font(figtree(17, .bold, relativeTo: .headline)).foregroundStyle(Theme.ink)
                Text(g.sub).font(figtree(14, .regular, relativeTo: .subheadline)).foregroundStyle(Theme.mute)
            }
            Spacer()
            ph(caret).resizable().frame(width: 20, height: 20).foregroundStyle(Theme.mute).rotationEffect(.degrees(turned ? 180 : 0))
        }
        .padding(.horizontal, 20).padding(.vertical, 16).frame(minHeight: 64).contentShape(Rectangle())
    }
}

private struct GroupRows: View {
    let model: AppModel
    let g: Group
    @Binding var draft: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(g.rows.enumerated()), id: \.offset) { i, r in
                if i > 0 { Rectangle().fill(Theme.line).frame(height: 1) }
                SettingRow(r: r, draft: $draft)
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
    }
}

private struct SettingRow: View {
    let r: Setting
    @Binding var draft: AppSettings

    var body: some View {
        let changed = !r.same(draft, AppSettings())
        VStack(alignment: .leading, spacing: 8) {
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

private struct AboutCard: View {
    var body: some View {
        BigCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("About").font(figtree(17, .bold, relativeTo: .headline)).foregroundStyle(Theme.ink)
                Text("Dokkit for iPhone. Read-only: it cannot change anything on a server and sends no notifications. It fetches when opened, when you pull down, and on the schedule above while in front.")
                    .font(figtree(14, .regular, relativeTo: .subheadline)).foregroundStyle(Theme.mute)
            }
            .padding(20)
        }
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
/// A page that is one statement card from top to bottom: what it is at the top, what to do at the bottom, in reach.
private struct CardScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var cardScale: CGFloat {
        get { self[CardScaleKey.self] }
        set { self[CardScaleKey.self] = newValue }
    }
}

/// Body text on a full-page card, scaled with it.
struct CardText: View {
    let text: String
    var size: CGFloat = 16.5
    var color = Theme.ink2
    @Environment(\.cardScale) private var scale
    var body: some View { Text(text).font(figtree(size * scale, .regular)).foregroundStyle(color) }
}

/// The Dokkit mark on its orange tile, with a lock badge when the app is locked.
struct MarkTile: View {
    var lockTone: Tone?
    @Environment(\.cardScale) private var scale
    var body: some View {
        Image("dokkit-mark", bundle: .module).renderingMode(.template).resizable().frame(width: 52 * scale, height: 52 * scale).foregroundStyle(Theme.brandInk)
            .frame(width: 64 * scale, height: 64 * scale).background(Theme.brand, in: RoundedRectangle(cornerRadius: 18 * scale, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if let lockTone {
                    ph("lock-simple").resizable().frame(width: 15 * scale, height: 15 * scale).foregroundStyle(Theme.tint(lockTone).ink)
                        .frame(width: 28 * scale, height: 28 * scale).background(Theme.panel, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.line.opacity(0.7)))
                        .offset(x: 8, y: 8)
                }
            }
            .accessibilityHidden(true)
    }
}

private struct SpreadKey: EnvironmentKey {
    static let defaultValue: Split? = nil
}

extension EnvironmentValues {
    /// Set when a full-page card is laid across both pages of an open foldable.
    var spread: Split? {
        get { self[SpreadKey.self] }
        set { self[SpreadKey.self] = newValue }
    }
}

/// A page that is one statement card from top to bottom: what it is at the top, what to do at the bottom, in reach.
/// Across an open foldable it becomes one spread instead: what it is on the left page, what to do on the right.
struct CenterCard<Head: View, Foot: View>: View {
    let tone: Tone
    @ViewBuilder var head: Head
    @ViewBuilder var foot: Foot
    @Environment(\.spread) private var spread

    var body: some View {
        if let spread {
            TwoPages(split: spread) {
                VStack(alignment: .leading, spacing: 0) { head }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .modifier(ClearsCorners(below: true))
                    .padding(28)
            } right: {
                VStack(alignment: .leading, spacing: 0) { foot }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(28)
            }
            .environment(\.cardScale, 1.3)
            .background(Wash(tone: tone).ignoresSafeArea())
        } else {
            GeometryReader { g in
                ScrollView {
                    StatementCard(tone: tone) {
                        VStack(alignment: .leading, spacing: 0) {
                            VStack(alignment: .leading, spacing: 0) { head }.frame(maxWidth: .infinity, alignment: .leading).modifier(ClearsCorners(below: true))
                            Spacer(minLength: 28)
                            foot
                        }
                        .frame(minHeight: max(0, g.size.height - 24 - 48), alignment: .top)
                    }
                    .padding(12)
                }
                .scrollBounceBehavior(.basedOnSize)
                // A tall page gets larger type, so the card reads as a poster rather than a note in an empty frame.
                .environment(\.cardScale, g.size.height > 800 ? 1.3 : 1)
            }
            .background(Wash(tone: tone).ignoresSafeArea())
        }
    }
}

/// Lays a full-page card across both pages when the screen is open.
private struct BesideQuiet<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        GeometryReader { geo in
            content
                .environment(\.spread, split(geo))
                .environment(\.corners, corners(geo))
        }
        .ignoresSafeArea(.container, edges: .horizontal)
        .coordinateSpace(.named("screen"))
    }
}

struct QuietSide: View {
    var body: some View {
        VStack(spacing: 16) {
            Image("dokkit-mark", bundle: .module).renderingMode(.template).resizable().frame(width: 56, height: 56).foregroundStyle(Theme.brand)
                .accessibilityHidden(true)
            Text("Read-only. Nothing here can change anything on a server.")
                .font(figtree(15, .regular, relativeTo: .subheadline)).foregroundStyle(Theme.mute).multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Wash(tone: .brand).ignoresSafeArea())
    }
}

public enum UnlockMethod: Sendable {
    case touchID, faceID, opticID, passcode

    var word: String {
        switch self {
        case .touchID: "Touch ID"
        case .faceID: "Face ID"
        case .opticID: "Optic ID"
        case .passcode: "your passcode"
        }
    }

    var icon: String {
        switch self {
        case .touchID: "fingerprint"
        case .faceID, .opticID: "scan-smiley"
        case .passcode: "lock-simple"
        }
    }

    var line: String {
        self == .passcode ? "Unlock with your passcode." : "Unlock with \(word) or your passcode."
    }
}

public struct LockCover: View {
    let message: String?
    let method: UnlockMethod
    let unlock: () -> Void

    public init(message: String?, method: UnlockMethod = .passcode, unlock: @escaping () -> Void) {
        self.message = message
        self.method = method
        self.unlock = unlock
        Fonts.register()
    }

    public var body: some View {
        let tone: Tone = message != nil ? .degraded : .brand
        BesideQuiet {
            CenterCard(tone: tone) {
                MarkTile(lockTone: tone).padding(.bottom, 22)
                BigLine(text: "Dokkit is locked", size: 44)
            } foot: {
                CardText(text: message ?? method.line)
                PrimaryButton(text: "Unlock", icon: method.icon, action: unlock).padding(.top, 16)
            }
        }
    }
}

struct FirstRunView: View {
    let model: AppModel
    var body: some View {
        BesideQuiet {
            CenterCard(tone: .brand) {
                MarkTile().padding(.bottom, 20)
                BigLine(text: "Dokkit", size: 44)
                CardText(text: "A read-only view of your Dokkit server. Alerts still reach you the usual way. Nothing here can change anything.").padding(.top, 10)
            } foot: {
                CardText(text: "The code is in the Dokkit web interface: Settings, Phones, Add a phone.", size: 14.5, color: Theme.mute)
                PrimaryButton(text: "Scan the code", icon: "qr-code") { model.firstPath.append(.add(paste: false)) }.padding(.top, 16)
                QuietButton(text: "Paste the code instead") { model.firstPath.append(.add(paste: true)) }.padding(.top, 6)
            }
        }
    }
}

/// The title of a settings group, for the bar over the right page when unfolded.
@MainActor func settingsGroupTitle(_ i: Int) -> String { groups[groups.indices.contains(i) ? i : 0].title }
