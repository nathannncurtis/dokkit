import DokkitUI
import LocalAuthentication
import SwiftUI

struct UnlockGate<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @Environment(\.scenePhase) private var phase
    @State private var unlocked = false
    @State private var busy = false
    @State private var asked = false
    @State private var message: String?

    var body: some View {
        ZStack {
            if unlocked { content() }
            if !unlocked { cover } else if phase != .active { Look.background.ignoresSafeArea() }
        }
        .onChange(of: phase) { _, new in
            if new == .background { unlocked = false; asked = false }
            if new == .active { Task { await askOnce() } }
        }
        .task { await askOnce() }
    }

    private var cover: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill").font(.largeTitle).accessibilityHidden(true)
            Text("Dokkit is locked").font(.headline)
            if let message { Text(message).font(.subheadline).multilineTextAlignment(.center) }
            Button("Unlock") { Task { await unlock() } }
                .buttonStyle(.borderedProminent).tint(Look.brand).frame(minHeight: 44)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(Look.ink)
        .background(Look.background)
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
