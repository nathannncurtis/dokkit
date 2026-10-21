import SwiftUI
import DokkitKit
import DokkitUI

@main
struct DokkitApp: App {
    @State private var model = AppModel.live()

    var body: some Scene {
        WindowGroup {
            UnlockGate(lockAfter: { model.settings.lockAfter.seconds }) {
                RootView(model: model) { onCode in AnyView(QRScannerView(onCode: onCode)) }
            }
            .preferredColorScheme(model.colorScheme)
        }
    }
}

extension AppModel {
    @MainActor static func live() -> AppModel {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Dokkit")
        let store = ServerStore(secrets: KeychainSecrets(), files: DiskFiles(directory: dir))
        #if DEBUG
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [DemoRelay.self] + (c.protocolClasses ?? [])
        c.urlCache = nil
        let client = RelayClient(session: URLSession(configuration: c), timeout: AppModel.relayTimeout)
        #else
        let client = RelayClient(timeout: AppModel.relayTimeout)
        #endif
        return AppModel(refresher: Refresher(store: store, client: client))
    }
}
