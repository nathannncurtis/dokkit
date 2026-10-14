import SwiftUI
import DokkitKit
import DokkitUI

@main
struct DokkitApp: App {
    @State private var model = AppModel.live()

    var body: some Scene {
        WindowGroup {
            UnlockGate {
                RootView(model: model) { onCode in AnyView(QRScannerView(onCode: onCode)) }
            }
        }
    }
}

extension AppModel {
    @MainActor static func live() -> AppModel {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Dokkit")
        let store = ServerStore(secrets: KeychainSecrets(), files: DiskFiles(directory: dir))
        return AppModel(refresher: Refresher(store: store))
    }
}
