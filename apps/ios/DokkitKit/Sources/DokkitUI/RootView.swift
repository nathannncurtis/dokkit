import SwiftUI
import DokkitKit

public typealias ScannerBuilder = @MainActor (@escaping @MainActor (String) -> Void) -> AnyView

private struct MorphKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

private struct OnTopKey: EnvironmentKey {
    static let defaultValue = true
}

/// Where a page sits: the only pane, or the left or right one when unfolded.
enum Pane: String { case main, left, right }

private struct PaneKey: EnvironmentKey {
    static let defaultValue = Pane.main
}

extension EnvironmentValues {
    /// Whether this page is the top of its stack, so only that page's switch button is the picker's morph source.
    var onTop: Bool {
        get { self[OnTopKey.self] }
        set { self[OnTopKey.self] = newValue }
    }

    /// The pane this page is in, so the picker grows out of the button that was pressed.
    var pane: Pane {
        get { self[PaneKey.self] }
        set { self[PaneKey.self] = newValue }
    }

    /// The namespace the card-into-page and picker morphs share.
    var morph: Namespace.ID? {
        get { self[MorphKey.self] }
        set { self[MorphKey.self] = newValue }
    }
}

public struct RootView: View {
    let model: AppModel
    let scanner: ScannerBuilder
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Namespace private var ns
    @State private var seen = Seen()
    @State private var lastTab = 0

    public init(model: AppModel, scanner: @escaping ScannerBuilder) {
        self.model = model
        self.scanner = scanner
        Fonts.register()
    }

    public var body: some View {
        content
            .tint(Theme.brand)
            .environment(\.seen, seen)
            .environment(\.morph, ns)
            .task(id: TaskKey(active: phase == .active, every: model.settings.refreshSeconds)) {
                guard phase == .active else { return }
                await model.load()
                while !Task.isCancelled {
                    await model.refresh()
                    try? await Task.sleep(for: .seconds(model.settings.refreshSeconds))
                }
            }
    }

    // Adding a server is its own page, as on Android, so the tab bar steps aside.
    private var adding: Bool {
        let path = model.tab == 1 ? model.serversPath : model.homePath
        if case .add = path.last { return true }
        return false
    }

    private struct TaskKey: Equatable {
        let active: Bool
        let every: Int
    }

    @ViewBuilder private var content: some View {
        if !model.loaded {
            Theme.bg.ignoresSafeArea()
        } else {
            GeometryReader { g in
                let two = split(g)
                let wide = two != nil
                Group {
                if model.servers.isEmpty || debugFirstRun {
                    firstRun(two)
                } else {
                    ZStack(alignment: .bottom) {
                        // Between tabs the pages slide like the issue cards, on the tab lens's spring.
                        ZStack {
                            ForEach([model.tab], id: \.self) { t in
                                Group {
                                    if let two { panes(t, two) } else { tabStack(t) }
                                }
                                .transition(reduced ? .identity : .asymmetric(
                                    insertion: .move(edge: t >= lastTab ? .trailing : .leading),
                                    removal: .move(edge: t >= lastTab ? .leading : .trailing)))
                            }
                        }
                        if wide || !adding {
                            FloatingNav(tab: model.tab) { i in
                                guard i != model.tab else { return }
                                lastTab = model.tab
                                withAnimation(reduced ? nil : Theme.travel) { model.tab = i }
                            }
                            // On anything wider than a phone it stays phone width, centred; unfolded, across the crease.
                            .frame(maxWidth: g.size.width > 600 ? 440 : .infinity)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        if model.picking { pickerScrim }
                    }
                    .overlay(alignment: .top) { if model.picking { picker(two, top: max(64, corners(g).band + 8)) } }
                }
                }
                .environment(\.corners, corners(g))
            }
            // The system's side margins are for the camera and status corner; pages keep clear of that corner themselves.
            .ignoresSafeArea(.container, edges: .horizontal)
            .coordinateSpace(.named("screen"))
        }
    }

    private var debugFirstRun: Bool {
        #if DEBUG
        model.debugFirstRun
        #else
        false
        #endif
    }

    // MARK: Unfolded: two panes split at the crease, the tab's own page on the left and what it opened on the right.

    @ViewBuilder private func panes(_ t: Int, _ two: Split) -> some View {
        // One app across the book: one bar and one background over both pages.
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                TopBar(title: ["Home", "Servers", "Settings"][t], server: t == 0 ? model.selected?.name : nil) { EmptyView() }
                    .frame(width: two.left + two.gap / 2)
                rightBar(t).environment(\.pane, .right)
            }
            TwoPages(split: two) {
                left(t).environment(\.pane, .left)
            } right: {
                right(t).environment(\.pane, .right)
            }
        }
        .environment(\.sharedChrome, true)
        .environment(\.onRight, t == 0 ? shownService : nil)
        .background(Wash(tone: t == 0 ? homeTone : .brand).ignoresSafeArea())
    }

    @ViewBuilder private func rightBar(_ t: Int) -> some View {
        let path: ReferenceWritableKeyPath<AppModel, [Page]> = t == 1 ? \.serversPath : \.homePath
        let page = t == 2 ? nil : model[keyPath: path].last
        let back: (() -> Void)? = page == nil ? nil : { _ = model[keyPath: path].popLast() }
        // The right page's own card says what it is; this side of the bar only goes back and acts.
        switch t {
        case 0: ServerTop(model: model, title: "", back: back, showsServer: false)
        case 1:
            if case .add = page {
                TopBar(title: "", back: back, backIcon: "x", backLabel: "Cancel") { EmptyView() }
            } else {
                TopBar(title: "", back: back) { EmptyView() }
            }
        default: TopBar(title: "") { EmptyView() }
        }
    }

    private var shownService: String? {
        switch model.homePath.last {
        case .service(let id, _): id
        case nil: lead
        default: nil
        }
    }

    private var homeTone: Tone {
        guard let snap = model.selectedState.snapshot else { return .quiet }
        let h = Home.make(snap, now: .now, hot: Double(model.settings.hotPercent), shown: model.settings.fineShown)
        if case .fine = h.top { return .ok }
        return h.needs.isEmpty ? .soon : h.needs.contains { $0.tone == .down } ? .down : .degraded
    }

    @ViewBuilder private func left(_ t: Int) -> some View {
        switch t {
        case 1: ServersView(model: model)
        case 2: SettingsIndexView(model: model)
        default: HomeView(model: model, part: lead == nil ? .top : .full)
        }
    }

    // With something needing you, Home leads with it; otherwise the rest of Home fills this side.
    private var lead: String? {
        guard let snap = model.selectedState.snapshot else { return nil }
        let h = Home.make(snap, now: .now, hot: Double(model.settings.hotPercent), shown: model.settings.fineShown)
        return h.needs.first { $0.serviceID != nil }?.serviceID
    }

    @ViewBuilder private func right(_ t: Int) -> some View {
        let path: ReferenceWritableKeyPath<AppModel, [Page]> = t == 1 ? \.serversPath : \.homePath
        let key = model[keyPath: path].last.map { "\($0)" } ?? "tab-\(t)"
        ZStack {
            ForEach([key], id: \.self) { _ in
                Group {
                    if let page = model[keyPath: path].last, t != 2 {
                        destination(page, path: path)
                    } else {
                        rest(t)
                    }
                }
                .transition(reduced ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(x: 48)), removal: .opacity))
            }
        }
        .animation(reduced ? nil : Theme.travel, value: key)
    }

    @ViewBuilder private func rest(_ t: Int) -> some View {
        switch t {
        case 1: ServerDetailView(model: model)
        case 2: SettingsGroupView(model: model)
        default:
            if model.selectedState.snapshot == nil {
                Placeholder(icon: "hourglass-medium", title: "Nothing to show yet", text: "The first snapshot fills this side.")
            } else if let lead {
                ServiceView(model: model, id: lead, back: nil).hideBar()
            } else {
                HomeView(model: model, part: .rest)
            }
        }
    }

    @ViewBuilder private func firstRun(_ two: Split?) -> some View {
        if let two, let page = model.firstPath.last {
            TwoPages(split: two) {
                FirstRunView(model: model)
            } right: {
                destination(page, path: \.firstPath)
            }
        } else if two != nil {
            FirstRunView(model: model)
        } else {
            NavigationStack(path: Binding(get: { model.firstPath }, set: { model.firstPath = $0 })) {
                FirstRunView(model: model).navigationDestination(for: Page.self) { destination($0, path: \.firstPath) }
            }
        }
    }

    @ViewBuilder private func tabStack(_ t: Int) -> some View {
        switch t {
        case 1:
            NavigationStack(path: Binding(get: { model.serversPath }, set: { model.serversPath = $0 })) {
                ServersView(model: model).hideBar().environment(\.onTop, model.serversPath.isEmpty).navigationDestination(for: Page.self) { destination($0, path: \.serversPath) }
            }
        case 2:
            NavigationStack { SettingsView(model: model).hideBar() }
        default:
            NavigationStack(path: Binding(get: { model.homePath }, set: { model.homePath = $0 })) {
                HomeView(model: model).hideBar().environment(\.onTop, model.homePath.isEmpty).navigationDestination(for: Page.self) { destination($0, path: \.homePath) }
            }
        }
    }

    @ViewBuilder private func destination(_ page: Page, path: ReferenceWritableKeyPath<AppModel, [Page]>) -> some View {
        let back = { _ = model[keyPath: path].popLast() }
        let top = model[keyPath: path].last == page
        switch page {
        case .service(let id, let from):
            let view = ServiceView(model: model, id: id, back: back).hideBar().environment(\.onTop, top)
            #if os(iOS)
            if #available(iOS 18.0, *), let from, !reduced {
                view.navigationTransition(.zoom(sourceID: "issue-\(from)", in: ns))
            } else {
                view
            }
            #else
            view
            #endif
        case .machine(let id):
            MachineView(model: model, id: id, back: back).hideBar().environment(\.onTop, top)
        case .add(let paste):
            AddServerView(model: model, paste: paste, scanner: scanner, done: back).hideBar()
        }
    }

    // MARK: The server picker grows out of its button into a window near the top, with a soft halo around it.

    private var pickerScrim: some View {
        Color.black.opacity(0.001).ignoresSafeArea()
            .onTapGesture { withAnimation(Theme.travel) { model.picking = false } }
    }

    private func picker(_ two: Split?, top: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Show a server").font(figtree(18, .bold, relativeTo: .headline)).foregroundStyle(Theme.ink).padding(.leading, 10).padding(.bottom, 8)
            ForEach(model.servers) { s in
                let on = s.id == model.selected?.id
                Button {
                    model.selectedID = s.id
                    withAnimation(Theme.travel) { model.picking = false }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name).font(figtree(16, .bold)).foregroundStyle(Theme.ink)
                            Text(URL(string: s.relay)?.host ?? s.relay).font(figtree(12, .medium, relativeTo: .caption)).foregroundStyle(Theme.mute)
                        }
                        Spacer()
                        if on { ph("check").resizable().frame(width: 20, height: 20).foregroundStyle(Theme.brand).accessibilityLabel("Showing") }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12).frame(minHeight: 60)
                    .background(on ? Theme.brandSoft : Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
            }
        }
        .padding(.horizontal, 12).padding(.top, 18).padding(.bottom, 12)
        .transition(.opacity.animation(.easeOut(duration: 0.2).delay(0.12)))
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Theme.line.opacity(0.7)))
                .matchedGeometryEffect(id: "picker-\(model.pickFrom)", in: ns)
                .shadow(color: .black.opacity(0.28), radius: 36, y: 8)
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        )
        .padding(.horizontal, 12)
        .frame(width: two.map { model.pickFrom == .right ? $0.right : $0.left })
        .frame(maxWidth: .infinity, alignment: model.pickFrom == .right ? .trailing : .leading)
        .padding(.top, top)
    }
}

extension AppModel {
    /// The theme chosen in Settings; nil follows the system. The app applies it above the lock screen too.
    public var colorScheme: ColorScheme? {
        switch settings.theme {
        case .light: .light
        case .dark: .dark
        default: nil
        }
    }
}

extension View {
    // Each pushed page is its own hosting view and takes the system's side margins again; the corners are handled per page.
    @ViewBuilder func hideBar() -> some View {
        #if os(iOS)
        toolbar(.hidden, for: .navigationBar).ignoresSafeArea(.container, edges: .horizontal)
        #else
        self
        #endif
    }
}
