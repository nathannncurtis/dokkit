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

enum Theme {
    static let bg = Color(light: 0xfafafa, dark: 0x0f0f11)
    static let panel = Color(light: 0xffffff, dark: 0x17171a)
    static let raise = Color(light: 0xf6f6f7, dark: 0x222226)
    static let line = Color(light: 0xe6e6ea, dark: 0x2a2a2f)
    static let ink = Color(light: 0x18181b, dark: 0xf4f4f5)
    static let mute = Color(light: 0x6b6b76, dark: 0xa1a1aa)
    static let chip = Color(light: 0xf0f0f3, dark: 0x29292e)
    static let brand = Color(light: 0x6d4aff, dark: 0xa899ff)
    static let ok = Color(light: 0x147a3a, dark: 0x4ade80)
    static let warn = Color(light: 0xa14a08, dark: 0xfbbf24)
    static let bad = Color(light: 0xc81e1e, dark: 0xf87171)

    static func color(_ l: Level) -> Color {
        switch l {
        case .ok: ok
        case .degraded: warn
        case .down: bad
        case .unknown, .unwatched, .other: mute
        }
    }
}
