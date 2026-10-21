import CoreText
import Foundation
import SwiftUI

public enum Fonts {
    private static let once: Void = {
        guard let url = Bundle.module.url(forResource: "Figtree", withExtension: "ttf") else { return }
        // A second registration in the same process fails harmlessly; the font is already there.
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()

    public static func register() { _ = once }
}

/// Figtree at a size that still follows Dynamic Type, relative to the given text style.
func figtree(_ size: CGFloat, _ weight: Font.Weight, relativeTo style: Font.TextStyle = .body) -> Font {
    Fonts.register()
    return Font.custom("Figtree", size: size, relativeTo: style).weight(weight)
}

/// A Phosphor icon from the bundled catalog, tinted by the foreground style.
func ph(_ name: String) -> Image {
    Image("ph-\(name)", bundle: .module).renderingMode(.template)
}
