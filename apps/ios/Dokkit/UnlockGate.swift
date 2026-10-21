import DokkitUI
import LocalAuthentication
import SwiftUI

private let foldGrace: TimeInterval = 1

struct UnlockGate<Content: View>: View {
    var lockAfter: () -> TimeInterval = { 0 }
    @ViewBuilder var content: () -> Content
    @Environment(\.scenePhase) private var phase
    @State private var unlocked = false
    @State private var busy = false
    @State private var asked = false
    @State private var message: String?
    @State private var method: UnlockMethod = .passcode
    @State private var leftAt: Date?

    var body: some View {
        ZStack {
            if unlocked { content() }
            if !unlocked { cover } else if phase != .active { Look.background.ignoresSafeArea() }
        }
        .onChange(of: phase) { _, new in
            if new == .background { leftAt = Date() }
            if new == .active {
                // Folding or unfolding the phone passes through the background for a moment; that is not leaving the app.
                if let leftAt, Date().timeIntervalSince(leftAt) >= max(lockAfter(), foldGrace) { unlocked = false; asked = false }
                leftAt = nil
                Task { await askOnce() }
            }
        }
        .task { await askOnce() }
    }

    private var cover: some View {
        LockCover(message: message, method: method) { Task { await unlock() } }
    }

    // The Face ID sheet makes the app inactive and active again, so asking on every activation would ask again after Cancel.
    private func askOnce() async {
        guard !asked else { return }
        asked = true
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "dokkitShowLock") {
            let ctx = LAContext()
            _ = ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
            method = Self.method(ctx)
            return
        }
        #endif
        await unlock()
    }

    // biometryType is only filled in after canEvaluatePolicy.
    private static func method(_ ctx: LAContext) -> UnlockMethod {
        switch ctx.biometryType {
        case .touchID: .touchID
        case .faceID: .faceID
        case .opticID: .opticID
        default: .passcode
        }
    }

    private func unlock() async {
        guard !busy, !unlocked else { return }
        busy = true
        defer { busy = false }
        let ctx = LAContext()
        var err: NSError?
        let can = ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err)
        method = Self.method(ctx)
        guard can else {
            message = "Set a passcode on this phone to use Dokkit."
            return
        }
        do {
            unlocked = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Open Dokkit")
            message = nil
        } catch {
            message = "Dokkit stayed locked."
        }
    }
}
