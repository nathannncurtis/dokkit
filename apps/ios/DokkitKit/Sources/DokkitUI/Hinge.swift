import SwiftUI

// MARK: - Foldable phones rotate; everything else stays portrait

@MainActor public enum Foldable {
    private static let key = "foldable"

    // Remembered so later launches can rotate from the first frame, before any hinge update arrives.
    public static var isFoldable: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

#if canImport(UIKit)
public struct HingeProbe: View {
    public init() {}

    public var body: some View {
        Probe().frame(width: 0, height: 0).accessibilityHidden(true)
    }
}

private struct Probe: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.isUserInteractionEnabled = false
        #if compiler(>=6.4)
        if #available(iOS 27.1, *) {
            v.addInteraction(UIHingeInteraction { _, update in
                guard update.hinge != nil, !Foldable.isFoldable else { return }
                Foldable.isFoldable = true
                for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                    scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                }
            })
        }
        #endif
        return v
    }

    func updateUIView(_ v: UIView, context: Context) {}
}
#else
public struct HingeProbe: View {
    public init() {}
    public var body: some View { EmptyView() }
}
#endif
