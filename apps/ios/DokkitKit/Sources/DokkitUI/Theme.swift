import SwiftUI
import DokkitKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension Color {
    init(light: UInt32, dark: UInt32) {
        #if canImport(UIKit)
        self.init(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
        #else
        self.init(NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light) })
        #endif
    }
}

#if canImport(UIKit)
extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}
#else
extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}
#endif

public enum Look {
    public static let background = Theme.bg
    public static let ink = Theme.ink
    public static let brand = Theme.brand
}

struct Tint {
    let surface: Color
    let ink: Color
    let solid: Color
}

/// Calm in Ember, docs/design.md, Colour; the phone apps use orange only.
enum Theme {
    static let bg = Color(light: 0xf8f3ee, dark: 0x1e1917)
    static let bg2 = Color(light: 0xefe6dd, dark: 0x171311)
    static let panel = Color(light: 0xfffcf9, dark: 0x27201d)
    static let line = Color(light: 0xe2d4c9, dark: 0x40342f)
    static let ink = Color(light: 0x241a15, dark: 0xf7f1ec)
    static let ink2 = Color(light: 0x4d3d33, dark: 0xdccdc2)
    static let mute = Color(light: 0x6b5a4f, dark: 0xb9a99e)
    static let brand = Color(light: 0xf28a3a, dark: 0xff9a4d)
    static let brandInk = Color(light: 0x2a1203, dark: 0x2a1203)
    static let brandSoft = Color(light: 0xfbe4d2, dark: 0x3d2b1e)
    static let focus = Color(light: 0xa8460a, dark: 0xffb074)

    static let rose = Tint(surface: Color(light: 0xfbe7e4, dark: 0x3a2421), ink: Color(light: 0xb42d25, dark: 0xffa39c), solid: Color(light: 0xe0675e, dark: 0xff7b72))
    static let amber = Tint(surface: Color(light: 0xfbf0d6, dark: 0x382e1c), ink: Color(light: 0x855b00, dark: 0xf5c542), solid: Color(light: 0xe3a51c, dark: 0xf5c542))
    static let peach = Tint(surface: Color(light: 0xf6ead9, dark: 0x362a20), ink: Color(light: 0x85561a, dark: 0xe7b77d), solid: Color(light: 0xd9a066, dark: 0xe7b77d))
    static let sage = Tint(surface: Color(light: 0xe5f1e6, dark: 0x1f2d23), ink: Color(light: 0x1d7537, dark: 0x7bd88f), solid: Color(light: 0x8fcf9e, dark: 0x7bd88f))
    static let mist = Tint(surface: Color(light: 0xf0e5dc, dark: 0x332a26), ink: Color(light: 0x6b5a4f, dark: 0xdccdc2), solid: Color(light: 0x6b5a4f, dark: 0xb9a99e))
    static let brandTint = Tint(surface: brandSoft, ink: Color(light: 0xa95c22, dark: 0xffb074), solid: brand)

    static func tint(_ t: Tone) -> Tint {
        switch t {
        case .down: rose
        case .degraded: amber
        case .soon: peach
        case .ok: sage
        case .quiet: mist
        case .brand: brandTint
        }
    }

    static func tone(_ l: Level) -> Tone { Words.tone(l) }

    static func icon(_ t: Tone) -> String {
        switch t {
        case .down: "warning-octagon"
        case .degraded: "hourglass-medium"
        case .soon: "calendar"
        case .ok: "check-circle"
        case .quiet: "circle-dashed"
        case .brand: "info"
        }
    }

    // The measured iOS 27 tab lens springs; everything that slides uses the travel one.
    static let travel = Animation.spring(duration: 0.4, bounce: 0.15)
    static let lift = Animation.spring(duration: 0.25, bounce: 0)
    static let settle = Animation.spring(response: 0.34, dampingFraction: 0.42)
    static let ease = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.45)
}

/// Two panes, split where the iPhone Duo folds, once the window is wide enough for two phone-width pages side by side.
func twoPanes(_ size: CGSize) -> Bool { size.width >= 900 && size.width > size.height }
