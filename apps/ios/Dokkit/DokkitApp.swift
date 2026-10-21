import SwiftUI
import DokkitKit
import DokkitUI

@main
struct DokkitApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = AppModel.live()

    var body: some Scene {
        WindowGroup {
            UnlockGate(lockAfter: { model.settings.lockAfter.seconds }) {
                RootView(model: model) { onCode in AnyView(QRScannerView(onCode: onCode)) }
            }
            .background(HingeProbe())
            .preferredColorScheme(model.colorScheme)
            #if DEBUG
            .task {
                // Launched with -dokkitDemo YES, the simulator pairs both demo servers without anyone typing a code.
                guard UserDefaults.standard.bool(forKey: "dokkitDemo") else { return }
                await model.load()
                for code in [DemoRelay.NORTHWIND_CODE, DemoRelay.HARBOR_LAB_CODE] {
                    guard let p = try? Pairing.parse(code), !model.servers.contains(where: { $0.mailbox == p.mailbox }) else { continue }
                    _ = await model.add(code: code)
                }
                if let route = UserDefaults.standard.string(forKey: "dokkitRoute") { model.debugOpen(route) }
            }
            #endif
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Foldable.isFoldable ? .all : .portrait
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
