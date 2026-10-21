import SwiftUI
import DokkitKit

/// A row of choices with a glass lens over the chosen one, moving on the measured iOS 27 springs: on a change it
/// lifts (grows 16 pt, turns clear, magnifies what it passes over), leans into the move, drops back once nearly
/// there, squashes on landing by how far it went and wobbles once; the whole row swells briefly. Pressing and
/// dragging lifts it under the finger and letting go picks what is under it. The tab bar and the segmented
/// switches share it.
struct GlassSelector<Item: View>: View {
    let count: Int
    let selected: Int
    let onSelect: (Int) -> Void
    var corner: CGFloat = 26
    var lensCorner: CGFloat = 99
    var inset: CGFloat = 4
    var height: CGFloat = 60
    var fill: Color = Theme.panel
    var lensRest: Color = Theme.brandSoft
    @ViewBuilder let item: (_ index: Int, _ on: Bool, _ grow: CGFloat) -> Item

    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var pos: CGFloat = 0
    @State private var lift: CGFloat = 0
    @State private var lean: CGFloat = 0
    @State private var squash: CGFloat = 0
    @State private var swell: CGFloat = 0
    @State private var dragging = false
    @State private var under = 0
    @State private var ready = false
    @State private var moveTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { g in
            let unit = (g.size.width - 2 * inset) / CGFloat(max(1, count))
            let lensW = unit + 16 * lift
            let lensH = g.size.height - 2 * inset + 16 * lift
            let shape = RoundedRectangle(cornerRadius: min(lensCorner, lensH / 2), style: .continuous)
            let cx = inset + (pos + 0.5) * unit
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: corner, style: .continuous).fill(fill)
                    .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(Theme.line.opacity(0.7)))
                // Under the labels: the lens's resting fill and its shadow, so the labels stay readable.
                shape.fill(lensRest.opacity(1 - Double(lift)))
                    .shadow(color: Theme.ink.opacity(0.12 + 0.12 * Double(lift)), radius: 2 + 10 * lift, y: 1 + 5 * lift)
                    .frame(width: lensW, height: lensH)
                    .scaleEffect(x: 1 + 0.12 * lean - squash, y: 1 - 0.16 * lean + squash * 0.6)
                    .position(x: cx, y: g.size.height / 2)
                HStack(spacing: 0) {
                    ForEach(0..<count, id: \.self) { i in
                        let on = i == under
                        item(i, on, on ? 1 + 0.16 * lift : 1).frame(maxWidth: .infinity)
                    }
                }
                .padding(inset)
                .frame(width: g.size.width, height: g.size.height)
                // Over the labels: the clear glass itself.
                lensGlass(shape)
                    .frame(width: lensW, height: lensH)
                    .scaleEffect(x: 1 + 0.12 * lean - squash, y: 1 - 0.16 * lean + squash * 0.6)
                    .position(x: cx, y: g.size.height / 2)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { v in
                        if !dragging {
                            dragging = true
                            withAnimation(Theme.lift) { lift = 1 }
                        }
                        let p = min(CGFloat(count - 1), max(0, (v.location.x - inset) / unit - 0.5))
                        withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.9)) { pos = p }
                        under = Int(p.rounded())
                    }
                    .onEnded { _ in
                        dragging = false
                        let i = Int(pos.rounded())
                        withAnimation(Theme.travel) { pos = CGFloat(i) }
                        land(distance: unit * 0.5)
                        under = i
                        if i != selected { onSelect(i) }
                    }
            )
            .onAppear {
                pos = CGFloat(max(0, selected))
                under = max(0, selected)
                ready = true
            }
            .onChange(of: selected) { old, new in
                guard ready, new >= 0, !dragging else { return }
                move(to: new, distance: abs(CGFloat(new) - pos) * unit)
            }
        }
        .frame(height: height)
        .scaleEffect(1 + swell * 0.025)
    }

    // Drawn rather than the system's Liquid Glass, which refracts whatever is behind the whole bar and smears the labels.
    private func lensGlass(_ shape: RoundedRectangle) -> some View { drawnGlass(shape) }

    private func drawnGlass(_ shape: RoundedRectangle) -> some View {
        shape.fill(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom))
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.9), .white.opacity(0.12), Theme.ink.opacity(0.1)], startPoint: .top, endPoint: .bottom)))
    }

    private func move(to i: Int, distance: CGFloat) {
        moveTask?.cancel()
        under = i
        if reduced {
            pos = CGFloat(i)
            return
        }
        withAnimation(Theme.travel) { pos = CGFloat(i) }
        guard distance > 1 else { return }
        withAnimation(Theme.lift) { lift = 1 }
        withAnimation(.easeOut(duration: 0.13)) { lean = 1; swell = 1 }
        moveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(130))
            withAnimation(Theme.travel) { lean = 0 }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { swell = 0 }
            // The lens is within a few points of its target about a quarter second in; that is when it lands.
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            land(distance: distance)
        }
    }

    private func land(distance: CGFloat) {
        withAnimation(Theme.lift) { lift = 0 }
        guard !reduced, distance >= 8 else { return }
        squash = 0.04 + 0.11 * min(1, max(0, (distance - 64) / 194))
        withAnimation(Theme.settle) { squash = 0 }
    }
}

/// The floating tab bar: Home, Servers, Settings.
struct FloatingNav: View {
    let tab: Int
    let onTab: (Int) -> Void
    private let tabs = [("Home", "house"), ("Servers", "hard-drives"), ("Settings", "gear")]

    var body: some View {
        GlassSelector(count: 3, selected: tab, onSelect: onTab, corner: 26, lensCorner: 99, inset: 4, height: 68) { i, on, grow in
            Button { onTab(i) } label: {
                VStack(spacing: 2) {
                    ph(tabs[i].1).resizable().frame(width: 22, height: 22).foregroundStyle(on ? Theme.brand : Theme.mute)
                    Text(tabs[i].0).font(figtree(12.5, .semibold, relativeTo: .caption)).foregroundStyle(on ? Theme.ink : Theme.mute)
                }
                .scaleEffect(grow)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .animation(.easeOut(duration: 0.2), value: on)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
        }
        .shadow(color: Theme.ink.opacity(0.12), radius: 18, y: 10)
        .padding(.horizontal, 12).padding(.bottom, 8)
    }
}

/// The Needs you / Coming up switch: the same lens in a rounded-rectangle shape.
struct Segmented: View {
    let items: [(key: String, word: String, count: Int)]
    let selected: String
    let onPick: (String) -> Void

    var body: some View {
        GlassSelector(
            count: items.count, selected: items.firstIndex { $0.key == selected } ?? 0, onSelect: { onPick(items[$0].key) },
            corner: 16, lensCorner: 12, inset: 4, height: 52, fill: Theme.bg2.opacity(0.8), lensRest: Theme.panel
        ) { i, on, grow in
            Button { onPick(items[i].key) } label: {
                HStack(spacing: 4) {
                    Text(items[i].word).font(figtree(14.5, .semibold, relativeTo: .subheadline)).foregroundStyle(on ? Theme.ink : Theme.ink2)
                    Text("\(items[i].count)").font(figtree(12, .medium, relativeTo: .caption)).foregroundStyle(Theme.mute)
                }
                .scaleEffect(grow)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
        }
    }
}
