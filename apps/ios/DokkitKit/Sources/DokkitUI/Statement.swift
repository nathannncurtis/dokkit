import SwiftUI
import DokkitKit

// MARK: - Numbers and fills that animate only the first time they are seen

// Only read and written from views, on the main thread.
final class Seen: @unchecked Sendable {
    var values: [String: Int] = [:]
}

private struct SeenKey: EnvironmentKey {
    static let defaultValue = Seen()
}

extension EnvironmentValues {
    var seen: Seen {
        get { self[SeenKey.self] }
        set { self[SeenKey.self] = newValue }
    }
}

// MARK: - Text

struct BigLine: View {
    let text: String
    var size: CGFloat = 38

    var body: some View {
        Text(text)
            .font(figtree(size, .heavy, relativeTo: .largeTitle))
            .tracking(-0.032 * size)
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A number that counts up once, the first time it is shown.
struct Tick: View {
    let value: Int
    let key: String
    var format: (Int) -> String = { "\($0)" }
    var font: Font
    var color: Color = Theme.ink
    @Environment(\.seen) private var seen
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var shown: Int?

    var body: some View {
        Text(format(shown ?? value))
            .font(font).foregroundStyle(color)
            .contentTransition(.numericText(value: Double(shown ?? value)))
            .onAppear {
                let from = seen.values[key]
                seen.values[key] = value
                guard !reduced, value > 0, from != value else { shown = value; return }
                shown = from ?? 0
                withAnimation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.7)) { shown = value }
            }
            .onChange(of: value) { _, new in
                seen.values[key] = new
                withAnimation(reduced ? nil : .timingCurve(0.33, 1, 0.68, 1, duration: 0.7)) { shown = new }
            }
    }
}

struct Eyebrow: View {
    let text: String
    let tone: Tone
    var icon: String?

    var body: some View {
        HStack(spacing: 6) {
            if let icon { ph(icon).resizable().frame(width: 16, height: 16) }
            Text(text).font(figtree(14, .semibold, relativeTo: .subheadline))
        }
        .foregroundStyle(Theme.tint(tone).ink)
    }
}

struct Label2: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(figtree(13, .semibold, relativeTo: .footnote)).tracking(0.6)
            .foregroundStyle(Theme.mute)
            .padding(.leading, 6).padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

struct QuietLine: View {
    let text: String
    var icon: String?
    var body: some View {
        HStack(spacing: 8) {
            if let icon { ph(icon).resizable().frame(width: 16, height: 16) }
            Text(text).font(figtree(14, .regular, relativeTo: .subheadline))
        }
        .foregroundStyle(Theme.mute)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - The statement card

struct HeroModel {
    var tone: Tone
    var icon: String
    var big: String
    var bigNumber: (value: Int, key: String, one: String, many: String)?
    var eyebrow: String?
    var eyebrowIcon: String?
    var tag: String?
    var lede: String?
    var extra: String?
    var age: String?
}

/// The rounded gradient card at the top of every page, tinted by the page's state, with a slow sheen across it.
struct StatementCard<Content: View>: View {
    let tone: Tone
    var p: CGFloat = 0
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduced

    var body: some View {
        let t = Theme.tint(tone)
        let shape = RoundedRectangle(cornerRadius: 30 - 8 * p, style: .continuous)
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 22).padding(.vertical, 24 - 10 * p)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    LinearGradient(colors: [t.surface, Theme.panel.mix(t.surface, 0.62)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    RadialGradient(colors: [t.solid.opacity(0.22), .clear], center: .topTrailing, startRadius: 0, endRadius: 140)
                    Sheen(color: .white.opacity(scheme == .dark ? 0.07 : 0.5), moving: !reduced)
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.panel.opacity(0.6)))
            .shadow(color: t.solid.opacity(0.18 + 0.1 * p), radius: 15 + 5 * p, y: 10 + 6 * p)
    }
}

// Run by Core Animation: a SwiftUI animation or timeline that never ends leaves a pushed page deaf to touches.
#if canImport(UIKit)
private struct Sheen: UIViewRepresentable {
    let color: Color
    let moving: Bool

    func makeUIView(context: Context) -> SheenView { SheenView() }

    func updateUIView(_ v: SheenView, context: Context) {
        v.band.colors = [UIColor.clear.cgColor, UIColor(color).cgColor, UIColor.clear.cgColor]
        v.moving = moving
    }

    final class SheenView: UIView {
        let band = CAGradientLayer()
        var moving = false { didSet { if moving != oldValue { setNeedsLayout() } } }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            band.locations = [0.38, 0.5, 0.62]
            band.startPoint = CGPoint(x: 0, y: 0)
            band.endPoint = CGPoint(x: 1, y: 1)
            layer.addSublayer(band)
        }

        required init?(coder: NSCoder) { nil }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            band.bounds = CGRect(x: 0, y: 0, width: bounds.width * 1.8, height: bounds.height * 1.8)
            band.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
            guard moving else { band.removeAnimation(forKey: "sheen"); return }
            guard band.animation(forKey: "sheen") == nil else { return }
            let a = CABasicAnimation(keyPath: "transform.translation.x")
            a.fromValue = -90
            a.toValue = 90
            a.duration = 14
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            a.isRemovedOnCompletion = false
            band.add(a, forKey: "sheen")
        }
    }
}
#else
private struct Sheen: View {
    let color: Color
    let moving: Bool
    var body: some View {
        LinearGradient(stops: [.init(color: .clear, location: 0.38), .init(color: color, location: 0.5), .init(color: .clear, location: 0.62)],
                       startPoint: .topLeading, endPoint: .bottomTrailing).scaleEffect(1.8)
    }
}
#endif

struct Hero: View {
    let m: HeroModel
    var p: CGFloat = 0

    var body: some View {
        let t = Theme.tint(m.tone)
        StatementCard(tone: m.tone, p: p) {
            fold {
                HStack(spacing: 12) {
                    ph(m.icon).resizable().frame(width: 22, height: 22).foregroundStyle(t.ink)
                        .frame(width: 44, height: 44).background(Theme.panel.opacity(0.8), in: Circle())
                    if let tag = m.tag { TagView(text: tag, tone: m.tone, onPanel: true) }
                    if let e = m.eyebrow { Eyebrow(text: e, tone: m.tone, icon: m.eyebrowIcon) }
                }
                .padding(.bottom, 14)
            }
            let size = 38 - 14 * p
            if let n = m.bigNumber {
                Tick(value: n.value, key: n.key, format: { "\($0) \($0 == 1 ? n.one : n.many)" },
                     font: figtree(size, .heavy, relativeTo: .largeTitle))
                    .tracking(-0.032 * size)
                    .accessibilityAddTraits(.isHeader)
            } else {
                BigLine(text: m.big, size: size)
            }
            fold {
                VStack(alignment: .leading, spacing: 0) {
                    if let l = m.lede {
                        Text(l).font(figtree(16.5, .regular)).foregroundStyle(Theme.ink2).padding(.top, 10)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let x = m.extra { Text(x).font(figtree(12.5, .medium, relativeTo: .caption)).foregroundStyle(Theme.mute).padding(.top, 8) }
                    if let a = m.age {
                        HStack(spacing: 6) {
                            ph("clock").resizable().frame(width: 14, height: 14)
                            Text(a).font(figtree(12.5, .medium, relativeTo: .caption))
                        }
                        .foregroundStyle(t.ink).padding(.top, 14)
                    }
                }
            }
        }
    }

    // Parts that fold away as the card settles into its pinned size.
    private func fold<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        FoldLayout(factor: 1 - p) { c() }.opacity(Double(max(0, 1 - p * 1.7))).clipped()
    }
}

/// Lays its child out at full size but reports only `factor` of its height, so the rest can be clipped away.
struct FoldLayout: Layout {
    var factor: CGFloat
    var animatableData: CGFloat {
        get { factor }
        set { factor = newValue }
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let s = subviews.first else { return .zero }
        let z = s.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? z.width, height: z.height * max(0, min(1, factor)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let s = subviews.first else { return }
        let z = s.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        s.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: z.height))
    }
}

/// Opens downward from the top edge, as Android's expandVertically does: the part shown grows and the rest stays clipped.
struct Reveal: ViewModifier {
    var shown: CGFloat
    func body(content: Content) -> some View {
        FoldLayout(factor: shown) { content }.clipped().opacity(Double(shown))
    }
}

extension AnyTransition {
    static var reveal: AnyTransition { .modifier(active: Reveal(shown: 0), identity: Reveal(shown: 1)) }
}

// MARK: - The page

private struct OffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// A page: the wash in its tone, a hero card that pins and settles as the page scrolls, big cards under it.
struct StatementPage<Top: View, Content: View>: View {
    let tone: Tone
    @ViewBuilder var top: Top
    var hero: HeroModel?
    var onRefresh: (() async -> Void)?
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var offset: CGFloat = 0
    @State private var heroH: CGFloat = 0

    var body: some View {
        let pinned = hero != nil && !reduced
        let p = pinned ? min(1, max(0, -offset / 240)) : 0
        VStack(spacing: 0) {
            top
            ZStack(alignment: .top) {
                scroll(pinned: pinned)
                if pinned, let hero {
                    Hero(m: hero, p: p).padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 10)
                        .background(GeometryReader { g in Color.clear.onAppear { heroH = g.size.height }.onChange(of: g.size.height) { _, h in if p == 0 { heroH = h } } })
                        // Once pinned, what scrolls under the card is softened instead of cut.
                        .background(alignment: .top) {
                            LinearGradient(colors: [Theme.bg.mix(Theme.tint(tone).surface, 0.4), Theme.bg.mix(Theme.tint(tone).surface, 0.4).opacity(0.92), .clear],
                                           startPoint: .top, endPoint: .bottom)
                                .padding(.bottom, -12)
                                .opacity(Double(p))
                                .allowsHitTesting(false)
                        }
                }
            }
        }
        .background(Wash(tone: tone).ignoresSafeArea())
    }

    @ViewBuilder private func scroll(pinned: Bool) -> some View {
        let s = ScrollView {
            VStack(spacing: 0) {
                GeometryReader { g in Color.clear.preference(key: OffsetKey.self, value: g.frame(in: .named("page")).minY) }.frame(height: 0)
                if pinned {
                    Color.clear.frame(height: heroH)
                } else if let hero {
                    Hero(m: hero).padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 10)
                }
                VStack(spacing: 16) { content }
                    .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 120)
            }
        }
        .coordinateSpace(name: "page")
        .modifier(TrackOffset(offset: $offset))
        if let onRefresh { s.refreshable { await onRefresh() } } else { s }
    }
}

/// Feeds the scroll position to the hero: the scroll view's own geometry on iOS 18, a measured marker before that.
private struct TrackOffset: ViewModifier {
    @Binding var offset: CGFloat
    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, y in offset = -y }
        } else {
            content.onPreferenceChange(OffsetKey.self) { v in Task { @MainActor in offset = v } }
        }
    }
}

struct Wash: View {
    let tone: Tone
    var body: some View {
        let t = Theme.tint(tone)
        ZStack {
            LinearGradient(stops: [.init(color: Theme.bg.mix(t.surface, 0.55), location: 0), .init(color: Theme.bg, location: 0.62)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [t.surface.opacity(0.85), .clear], center: UnitPoint(x: 0.85, y: -0.1), startRadius: 0, endRadius: 520)
        }
    }
}

extension Color {
    /// This colour moved `amount` of the way towards `other`.
    func mix(_ other: Color, _ amount: Double) -> Color {
        #if canImport(UIKit)
        Color(UIColor { tc in
            var a = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), al: CGFloat(0))
            var b = a
            UIColor(self).resolvedColor(with: tc).getRed(&a.r, green: &a.g, blue: &a.b, alpha: &a.al)
            UIColor(other).resolvedColor(with: tc).getRed(&b.r, green: &b.g, blue: &b.b, alpha: &b.al)
            let k = CGFloat(amount)
            return UIColor(red: a.r + (b.r - a.r) * k, green: a.g + (b.g - a.g) * k, blue: a.b + (b.b - a.b) * k, alpha: a.al + (b.al - a.al) * k)
        })
        #else
        self
        #endif
    }
}

// MARK: - Top bar

struct TopBar<Tools: View>: View {
    let title: String
    var server: String?
    var back: (() -> Void)?
    var backIcon = "arrow-left"
    var backLabel = "Back"
    @ViewBuilder var tools: Tools

    var body: some View {
        HStack(spacing: 0) {
            if let back {
                RoundIcon(icon: backIcon, label: backLabel, action: back)
                Spacer().frame(width: 10)
            } else {
                Spacer().frame(width: 12)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(figtree(15, .bold, relativeTo: .subheadline)).foregroundStyle(Theme.ink2).accessibilityAddTraits(.isHeader)
                if let server { Text(server).font(figtree(12, .medium, relativeTo: .caption)).foregroundStyle(Theme.mute).lineLimit(1) }
            }
            Spacer(minLength: 8)
            tools
        }
        .frame(minHeight: 56).padding(.horizontal, 8)
    }
}

struct RoundIcon: View {
    let icon: String
    let label: String
    var spinning = false
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var angle = 0.0
    @State private var busy = false
    @State private var turning = false

    var body: some View {
        Button(action: action) {
            ph(icon).resizable().frame(width: 22, height: 22).foregroundStyle(Theme.ink)
                .rotationEffect(.degrees(angle))
                .frame(width: 44, height: 44)
                .background(Theme.panel.opacity(0.55), in: Circle())
                .overlay(Circle().strokeBorder(Theme.line.opacity(0.7)))
        }
        .buttonStyle(PressStyle(scale: 0.92))
        .padding(.leading, 6)
        .accessibilityLabel(label)
        .onChange(of: spinning) { _, on in
            busy = on
            if on, !turning { spin() }
        }
    }

    // One turn at a time, so it stops at rest once the work is done; a repeating animation would never stop.
    // Checks state, not `spinning`: the completion holds a copy of this view from when the turn began.
    private func spin() {
        guard busy, !reduced else { turning = false; return }
        turning = true
        withAnimation(.linear(duration: 0.8)) { angle += 360 } completion: { spin() }
    }
}

struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.985
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? scale : 1).animation(Theme.ease, value: configuration.isPressed)
    }
}

// MARK: - Cards and small parts

/// Cards rise a little as they come into view, tied to the scroll.
struct Rise: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduced
    func body(content: Content) -> some View {
        if reduced { content } else {
            content.scrollTransition(.interactive) { c, phase in
                let k = phase.value > 0 ? min(1, phase.value) : 0
                return c.offset(y: 22 * k).scaleEffect(1 - 0.015 * k).opacity(1 - 0.45 * k)
            }
        }
    }
}

extension View {
    func rise() -> some View { modifier(Rise()) }
}

struct BigCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel.opacity(0.96), in: shape)
            .overlay(shape.strokeBorder(Theme.line.opacity(0.75)))
            .shadow(color: Theme.ink.opacity(0.07), radius: 14, y: 10)
            .rise()
    }
}

struct CardHead: View {
    let title: String
    var detail: String?
    var body: some View {
        HStack {
            Text(title).font(figtree(18, .bold, relativeTo: .headline)).foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
            Spacer()
            if let detail { Text(detail).font(figtree(12.5, .medium, relativeTo: .caption)).foregroundStyle(Theme.mute) }
        }
        .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 4)
    }
}

struct Figure {
    let value: Int
    let word: String
    let tone: Tone
    let key: String
}

struct Figures: View {
    let items: [Figure]
    var body: some View {
        BigCard {
            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { n, f in
                    if n > 0 { Rectangle().fill(Theme.line.opacity(0.75)).frame(width: 1) }
                    VStack(alignment: .leading, spacing: 2) {
                        Tick(value: f.value, key: f.key, font: figtree(34, .heavy, relativeTo: .largeTitle),
                             color: f.value > 0 && f.tone != .quiet ? Theme.tint(f.tone).ink : Theme.ink)
                        Text(f.word).font(figtree(13.5, .semibold, relativeTo: .footnote)).foregroundStyle(Theme.mute)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 18).padding(.trailing, 10).padding(.vertical, 18)
                    .accessibilityElement(children: .ignore).accessibilityLabel("\(f.value) \(f.word)")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct TagView: View {
    let text: String
    let tone: Tone
    var onPanel = false
    var body: some View {
        Text(text).font(figtree(13, .semibold, relativeTo: .footnote)).foregroundStyle(Theme.tint(tone).ink)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(onPanel ? Theme.panel.opacity(0.8) : Theme.tint(tone).surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct Pip: View {
    let tone: Tone
    var body: some View {
        let t = Theme.tint(tone)
        ZStack {
            if tone == .quiet {
                Circle().strokeBorder(Theme.mute, style: StrokeStyle(lineWidth: 2, dash: [3, 3])).frame(width: 10, height: 10)
            } else {
                Circle().fill(t.surface).frame(width: 16, height: 16)
                Circle().fill(t.solid).frame(width: 10, height: 10)
            }
        }
        .frame(width: 16, height: 16).accessibilityHidden(true)
    }
}

struct ToneCircle: View {
    let tone: Tone
    var icon: String?
    var size: CGFloat = 44
    var onPanel = false
    var body: some View {
        let t = Theme.tint(tone)
        ph(icon ?? Theme.icon(tone)).resizable().frame(width: size * 0.5, height: size * 0.5).foregroundStyle(t.ink)
            .frame(width: size, height: size)
            .background(onPanel ? Theme.panel : t.surface, in: Circle())
            .overlay { if onPanel { Circle().strokeBorder(Theme.line) } }
            .accessibilityHidden(true)
    }
}

struct SoftButton: View {
    let text: String
    var icon: String? = "arrow-right"
    var full = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(text).font(figtree(15, .semibold, relativeTo: .body))
                if let icon { ph(icon).resizable().frame(width: 18, height: 18) }
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 18).padding(.vertical, 11)
            .frame(maxWidth: full ? .infinity : nil, minHeight: 46)
            .background(Theme.brandSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressStyle())
    }
}

struct PrimaryButton: View {
    let text: String
    var icon: String?
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { ph(icon).resizable().frame(width: 20, height: 20) }
                Text(text).font(figtree(16, .semibold, relativeTo: .body))
            }
            .foregroundStyle(Theme.brandInk)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Theme.brand, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Theme.brand.opacity(0.35), radius: 10, y: 6)
            .opacity(enabled ? 1 : 0.5)
        }
        .buttonStyle(PressStyle())
        .disabled(!enabled)
    }
}

struct QuietButton: View {
    let text: String
    var color: Color = Theme.mute
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(text).font(figtree(15, .semibold, relativeTo: .body)).foregroundStyle(color).frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(PressStyle())
    }
}

struct FlagsRow: View {
    let flags: [Flag]
    var onPanel = true
    var body: some View {
        FlowLayout(spacing: 6) { ForEach(flags, id: \.self) { TagView(text: $0.text, tone: $0.tone, onPanel: onPanel) } }
    }
}

/// Wraps its children onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let z = fit(s, w)
            if x > 0, x + z.width > w { y += line + spacing; x = 0; line = 0 }
            x += z.width + spacing; line = max(line, z.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, w), height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let z = fit(s, bounds.width)
            if x > bounds.minX, x + z.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(z))
            x += z.width + spacing; line = max(line, z.height)
        }
    }

    // A child wider than the row gets the row's width, so its text wraps instead of running off.
    private func fit(_ s: LayoutSubview, _ w: CGFloat) -> CGSize {
        let z = s.sizeThatFits(.unspecified)
        return z.width <= w ? z : s.sizeThatFits(ProposedViewSize(width: w, height: nil))
    }
}

struct IssueCardView: View {
    let c: IssueCard
    var onOpen: (() -> Void)?

    var body: some View {
        let t = Theme.tint(c.tone)
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        let card = HStack(alignment: .top, spacing: 16) {
            ToneCircle(tone: c.tone, onPanel: true)
            VStack(alignment: .leading, spacing: 4) {
                Text(c.title).font(figtree(19, .bold, relativeTo: .title3)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                Text(c.sentence).font(figtree(15.5, .regular)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                Text([c.machine.isEmpty ? nil : c.machine, c.shortId.isEmpty ? nil : c.shortId, c.count > 1 ? "\(c.count) times" : nil].compactMap { $0 }.joined(separator: "   "))
                    .font(figtree(12, .medium, relativeTo: .caption)).foregroundStyle(Theme.mute).padding(.top, 4)
                if !c.flags.isEmpty { FlagsRow(flags: c.flags, onPanel: false).padding(.top, 6) }
                if let onOpen, c.serviceID != nil { SoftButton(text: c.nextStep, action: onOpen).padding(.top, 10) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .background(LinearGradient(stops: [.init(color: t.surface, location: 0), .init(color: Theme.panel, location: 0.62)], startPoint: .leading, endPoint: .trailing), in: shape)
        .overlay(shape.strokeBorder(Theme.line.opacity(0.75)))
        .shadow(color: Theme.ink.opacity(0.07), radius: 14, y: 10)
        .rise()
        if let onOpen, c.serviceID != nil {
            Button(action: onOpen) { card }.buttonStyle(PressStyle()).accessibilityHint(c.nextStep)
        } else {
            card
        }
    }
}

struct Banner: View {
    let f: Freshness
    var body: some View {
        let tone: Tone = f.isWarning || f.detail != nil ? .degraded : .quiet
        let t = Theme.tint(tone)
        HStack(alignment: .top, spacing: 12) {
            ph(f.isWarning ? "warning" : "info").resizable().frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(f.text).font(figtree(14, .semibold, relativeTo: .subheadline))
                if let d = f.detail { Text(d).font(figtree(14, .regular, relativeTo: .subheadline)).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(t.ink)
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(t.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel((f.isWarning ? "Warning. " : "") + f.text + ". " + (f.detail ?? ""))
    }
}

struct NoticeCard: View {
    let tone: Tone
    let icon: String
    let title: String
    let text: String
    var body: some View {
        BigCard {
            HStack(alignment: .top, spacing: 16) {
                ToneCircle(tone: tone, icon: icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(figtree(18, .bold, relativeTo: .headline)).foregroundStyle(Theme.ink)
                    Text(text).font(figtree(14, .regular, relativeTo: .subheadline)).foregroundStyle(Theme.mute).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
        }
    }
}

struct AllFine: View {
    let text: String
    var body: some View {
        HStack(spacing: 16) {
            ph("check-circle").resizable().frame(width: 22, height: 22).foregroundStyle(Theme.sage.ink)
                .frame(width: 44, height: 44).background(Theme.panel, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(figtree(15.5, .semibold, relativeTo: .body))
                Text("Nothing to do there. Dokkit keeps watching.").font(figtree(14, .regular, relativeTo: .subheadline)).opacity(0.85)
            }
            .foregroundStyle(Theme.sage.ink)
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(Theme.sage.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .rise()
    }
}

// MARK: - The last day: one capsule per machine, half hours in the same state merged into one stretch

func stateColor(_ c: String) -> Color {
    switch c {
    case "warn": Theme.amber.solid
    case "bad": Theme.rose.solid
    case "off": Theme.line.opacity(0.55)
    case "none": Theme.bg2
    default: Theme.sage.solid
    }
}

struct Strip: View {
    let cells: [String]
    let key: String
    var row = 0
    let label: String
    @Environment(\.seen) private var seen
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var k: CGFloat = 1

    private var runs: [(Int, Int, String)] {
        var out: [(Int, Int, String)] = []
        var start = 0
        for i in 1...max(1, cells.count) where i == cells.count || cells[i] != cells[start] {
            out.append((start, i, cells[start]))
            start = i
        }
        return cells.isEmpty ? [] : out
    }

    var body: some View {
        let runs = runs
        Canvas { ctx, size in
            let unit = size.width / CGFloat(max(1, cells.count))
            let gap: CGFloat = 2
            ctx.clip(to: Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2))
            ctx.clip(to: Path(CGRect(x: 0, y: 0, width: size.width * k, height: size.height)))
            for (n, r) in runs.enumerated() {
                let l = CGFloat(r.0) * unit + (n > 0 ? gap / 2 : 0)
                let rr = CGFloat(r.1) * unit - (n < runs.count - 1 ? gap / 2 : 0)
                ctx.fill(Path(CGRect(x: l, y: 0, width: rr - l, height: size.height)), with: .color(stateColor(r.2)))
            }
        }
        .frame(height: 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), the last day: " + runs.map { r in
            let w = ["warn": "slow", "bad": "down", "off": "not expected", "none": "no data"][r.2] ?? "fine"
            let h = Double(r.1 - r.0) / 2
            return "\(w) for \(h == h.rounded() ? String(Int(h)) : String(h)) h"
        }.joined(separator: ", "))
        .onAppear {
            guard seen.values["strip" + key] == nil, !reduced else { return }
            seen.values["strip" + key] = 1
            k = 0
            withAnimation(Theme.ease.speed(0.65).delay(Double(row) * 0.05)) { k = 1 }
        }
    }
}

struct Legend: View {
    var body: some View {
        FlowLayout(spacing: 14) {
            ForEach([("Fine", "ok"), ("Slow", "warn"), ("Down", "bad"), ("Not expected", "off")], id: \.0) { w, c in
                HStack(spacing: 6) {
                    Capsule().fill(stateColor(c)).frame(width: 16, height: 8)
                    Text(w).font(figtree(13, .regular, relativeTo: .footnote)).foregroundStyle(Theme.mute)
                }
            }
        }
    }
}

struct Axis: View {
    let words: [String]
    var body: some View {
        HStack {
            ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                if i > 0 { Spacer() }
                Text(w).font(figtree(12, .medium, relativeTo: .caption)).foregroundStyle(Theme.mute)
            }
        }
        .padding(.top, 6)
    }
}

// MARK: - Meters and the chart

struct MeterBar: View {
    let fraction: Double
    let color: Color
    let key: String
    @Environment(\.seen) private var seen
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var k: Double = 1

    var body: some View {
        GeometryReader { g in
            Capsule().fill(Theme.bg2)
                .overlay(alignment: .leading) { Capsule().fill(color).frame(width: g.size.width * min(1, max(0, fraction)) * k) }
        }
        .frame(height: 8)
        .onAppear {
            guard seen.values["m" + key] == nil, !reduced else { return }
            seen.values["m" + key] = 1
            k = 0
            withAnimation(Theme.ease.speed(0.55)) { k = 1 }
        }
    }
}

struct MeterView: View {
    let m: Meter
    let key: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(m.label + (m.subject.map { " \($0)" } ?? "")).font(figtree(13, .regular, relativeTo: .footnote)).foregroundStyle(Theme.mute).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(m.percent)%").font(figtree(12.5, .semibold, relativeTo: .caption)).foregroundStyle(m.isHot ? Theme.amber.ink : Theme.ink2)
            }
            MeterBar(fraction: m.fraction, color: m.isHot ? Theme.amber.solid : Theme.sage.solid, key: key)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(m.spoken)
    }
}

struct Bars: View {
    let values: [Double?]
    let key: String
    let label: String
    @Environment(\.seen) private var seen
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var grown = true

    var body: some View {
        let present = values.compactMap { $0 }
        let hi = present.max() ?? 0
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                if let v, hi > 0 {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(i == values.count - 1 ? Theme.brand : Theme.mute.opacity(0.55))
                        .frame(height: max(6, 88 * CGFloat(v / hi)))
                        .scaleEffect(y: grown ? 1 : 0.001, anchor: .bottom)
                        .animation(reduced ? nil : Theme.ease.delay(Double(i) * 0.018), value: grown)
                } else {
                    Color.clear
                }
            }
        }
        .frame(height: 88, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) over the last \(values.count) hours" + (present.last.map { ", latest \(Int($0.rounded()))" } ?? ""))
        .onAppear {
            guard seen.values["c" + key] == nil, !reduced else { return }
            seen.values["c" + key] = 1
            grown = false
            DispatchQueue.main.async { grown = true }
        }
    }
}
