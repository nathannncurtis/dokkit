import SwiftUI
import DokkitKit

public typealias ScannerBuilder = @MainActor (@escaping @MainActor (String) -> Void) -> AnyView

private struct MorphKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

private struct OnTopKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether this page is the top of its stack, so only that page's switch button is the picker's morph source.
    var onTop: Bool {
        get { self[OnTopKey.self] }
        set { self[OnTopKey.self] = newValue }
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
        } else if model.servers.isEmpty {
            NavigationStack(path: Binding(get: { model.firstPath }, set: { model.firstPath = $0 })) {
                FirstRunView(model: model).navigationDestination(for: Page.self) { destination($0, path: \.firstPath) }
            }
        } else {
            ZStack(alignment: .bottom) {
                // Between tabs the pages slide like the issue cards, on the tab lens's spring.
                ZStack {
                    ForEach([model.tab], id: \.self) { t in
                        tabStack(t)
                            .transition(reduced ? .identity : .asymmetric(
                                insertion: .move(edge: t >= lastTab ? .trailing : .leading),
                                removal: .move(edge: t >= lastTab ? .leading : .trailing)))
                    }
                }
                if !adding {
                    FloatingNav(tab: model.tab) { i in
                        guard i != model.tab else { return }
                        lastTab = model.tab
                        withAnimation(reduced ? nil : Theme.travel) { model.tab = i }
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if model.picking { pickerScrim }
            }
            .overlay(alignment: .top) { if model.picking { picker } }
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

    private var picker: some View {
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
                .matchedGeometryEffect(id: "picker", in: ns)
                .shadow(color: .black.opacity(0.28), radius: 36, y: 8)
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        )
        .padding(.horizontal, 12)
        .padding(.top, 64)
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
    @ViewBuilder func hideBar() -> some View {
        #if os(iOS)
        toolbar(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }
}
