import DokkitUI
import LocalAuthentication
import SwiftUI

struct UnlockGate<Content: View>: View {
    var lockAfter: () -> TimeInterval = { 0 }
    @ViewBuilder var content: () -> Content
    @Environment(\.scenePhase) private var phase
    @State private var unlocked = false
    @State private var busy = false
    @State private var asked = false
    @State private var message: String?
    @State private var leftAt: Date?

    var body: some View {
        ZStack {
            if unlocked { content() }
            if !unlocked { cover } else if phase != .active { Look.background.ignoresSafeArea() }
        }
        .onChange(of: phase) { _, new in
            if new == .background {
                leftAt = Date()
                if lockAfter() == 0 { unlocked = false; asked = false }
            }
            if new == .active {
                if let leftAt, Date().timeIntervalSince(leftAt) >= lockAfter() { unlocked = false; asked = false }
                Task { await askOnce() }
            }
        }
        .task { await askOnce() }
    }

    private var cover: some View {
        LockCover(message: message) { Task { await unlock() } }
    }

    // The Face ID sheet makes the app inactive and active again, so asking on every activation would ask again after Cancel.
    private func askOnce() async {
        guard !asked else { return }
        asked = true
        await unlock()
    }

    private func unlock() async {
        guard !busy, !unlocked else { return }
        busy = true
        defer { busy = false }
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
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
