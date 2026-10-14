import SwiftUI
import DokkitKit

public typealias ScannerBuilder = @MainActor (@escaping @MainActor (String) -> Void) -> AnyView

public struct RootView: View {
    let model: AppModel
    let scanner: ScannerBuilder
    @Environment(\.scenePhase) private var phase

    public init(model: AppModel, scanner: @escaping ScannerBuilder) {
        self.model = model
        self.scanner = scanner
    }

    public var body: some View {
        content
            .tint(Theme.brand)
            .sheet(isPresented: Binding(get: { model.addingServer }, set: { model.addingServer = $0 })) {
                AddServerSheet(model: model, scanner: scanner)
            }
            .task(id: phase == .active) {
                guard phase == .active else { return }
                await model.load()
                while !Task.isCancelled {
                    await model.refresh()
                    try? await Task.sleep(for: .seconds(30))
                }
            }
    }

    @ViewBuilder private var content: some View {
        if !model.loaded {
            Theme.bg.ignoresSafeArea()
        } else if model.servers.isEmpty {
            FirstRunView(model: model)
        } else {
            TabView {
                NavigationStack {
                    HomeView(model: model).navigationDestination(for: String.self) { ServiceView(model: model, id: $0) }
                }
                .tabItem { Label("Home", systemImage: "house") }
                NavigationStack { ServersView(model: model, scanner: scanner) }
                    .tabItem { Label("Servers", systemImage: "server.rack") }
            }
        }
    }
}
