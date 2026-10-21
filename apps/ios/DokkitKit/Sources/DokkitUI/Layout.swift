import SwiftUI

/// Where a two-page screen splits: the left page, the fold between them, the right page.
struct Split: Equatable {
    var left: CGFloat
    var gap: CGFloat
    var right: CGFloat
}

/// Two pages once the window is wide enough for two phone-width pages; split at the fold when the system reports one.
/// The proxy must span the whole width of the screen, horizontal safe area included.
@MainActor func split(_ g: GeometryProxy) -> Split? {
    guard twoPanes(g.size) else { return nil }
    #if compiler(>=6.4)
    if #available(iOS 27.1, macOS 27.1, *), let d = g.reservedRegions(kind: .division).first(where: \.isActive) {
        return Split(left: d.frame.minX, gap: d.frame.width, right: g.size.width - d.frame.maxX)
    }
    #endif
    let gap: CGFloat = 24
    return Split(left: (g.size.width - gap) / 2, gap: gap, right: (g.size.width - gap) / 2)
}

/// What the camera and status take along the top edge, in the proxy's space. The system reserves a margin down the
/// whole side for it; pages keep clear of just these corners instead.
@MainActor func corners(_ g: GeometryProxy) -> [CGRect] {
    #if compiler(>=6.4)
    if #available(iOS 27.1, macOS 27.1, *) {
        return g.reservedRegions(kind: .occlusion).filter { $0.isActive && $0.frame.minY <= 1 }.map(\.frame)
    }
    #endif
    return []
}

/// Lays two pages side by side with their backgrounds meeting in the middle of the fold, content kept off it.
struct TwoPages<Left: View, Right: View>: View {
    let split: Split
    @ViewBuilder var left: Left
    @ViewBuilder var right: Right

    var body: some View {
        HStack(spacing: 0) {
            left.safeAreaPadding(.trailing, split.gap / 2).frame(width: split.left + split.gap / 2)
            right.safeAreaPadding(.leading, split.gap / 2).frame(width: split.right + split.gap / 2)
        }
    }
}

private struct CornersKey: EnvironmentKey {
    static let defaultValue: [CGRect] = []
}

extension EnvironmentValues {
    /// The camera and status corners, in the "screen" coordinate space.
    var corners: [CGRect] {
        get { self[CornersKey.self] }
        set { self[CornersKey.self] = newValue }
    }
}

extension [CGRect] {
    /// How far down from the top the corners reach.
    var band: CGFloat { map(\.maxY).max() ?? 0 }

    /// How much a bar spanning `frame` gives up at each end so nothing in it sits under a corner.
    func clearance(for frame: CGRect) -> (leading: CGFloat, trailing: CGFloat) {
        reduce((0, 0)) { r, c in
            guard c.minX < frame.maxX, c.maxX > frame.minX, c.minY < frame.maxY, c.maxY > frame.minY else { return r }
            return c.midX > frame.midX ? (r.0, Swift.max(r.1, frame.maxX - c.minX)) : (Swift.max(r.0, c.maxX - frame.minX), r.1)
        }
    }
}

/// Gives up the ends of a view that would sit under a camera or status corner. With `below`, a corner at the leading
/// end starts the view under it instead, so a block of left-aligned lines stays aligned with what follows.
struct ClearsCorners: ViewModifier {
    var below = false
    @Environment(\.corners) private var corners
    @State private var frame = CGRect.zero

    func body(content: Content) -> some View {
        let clear = corners.clearance(for: frame)
        let lead = corners.filter { $0.minX < frame.maxX && $0.maxX > frame.minX && $0.maxY > frame.minY && $0.midX < frame.midX }
        let drop = below ? Swift.max(0, (lead.map(\.maxY).max() ?? frame.minY) - frame.minY) : 0
        content
            .padding(.leading, below ? 0 : clear.leading).padding(.trailing, clear.trailing)
            .padding(.top, drop)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("screen")) } action: { frame = $0 }
    }
}

private struct SharedChromeKey: EnvironmentKey {
    static let defaultValue = false
}

private struct OnRightKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// Unfolded, one bar and one background run across both pages, so a page leaves out its own.
    var sharedChrome: Bool {
        get { self[SharedChromeKey.self] }
        set { self[SharedChromeKey.self] = newValue }
    }

    /// The service open on the right page, so its card on the left can show it is the one.
    var onRight: String? {
        get { self[OnRightKey.self] }
        set { self[OnRightKey.self] = newValue }
    }
}
