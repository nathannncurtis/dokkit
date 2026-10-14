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
        TabView {
            NavigationStack {
                NeedsYouView(model: model).navigationDestination(for: String.self) { ServiceView(model: model, id: $0) }
            }
            .tabItem { Label("Needs you", systemImage: "exclamationmark.circle") }
            NavigationStack {
                EverythingView(model: model).navigationDestination(for: String.self) { ServiceView(model: model, id: $0) }
            }
            .tabItem { Label("Everything", systemImage: "square.stack.3d.up") }
            NavigationStack { ServersView(model: model, scanner: scanner) }
                .tabItem { Label("Servers", systemImage: "server.rack") }
        }
        .tint(Theme.brand)
        .task(id: phase == .active) {
            guard phase == .active else { return }
            await model.load()
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
}
