import SwiftUI
import CoreText

enum MoblyFonts {
    private static var didRegister = false

    static func registerBundledFonts() {
        guard !didRegister else { return }
        didRegister = true
        let names = [
            "Fredoka-Regular", "Fredoka-Medium", "Fredoka-SemiBold", "Fredoka-Bold",
            "Inter-Regular", "Inter-Medium", "Inter-SemiBold"
        ]
        for name in names {
            for ext in ["ttf", "otf"] {
                if let url = Bundle.main.url(forResource: name, withExtension: ext) {
                    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
                }
            }
        }
    }

    static func isBundled(_ name: String) -> Bool {
        UIFont(name: name, size: 12) != nil
    }
}

extension Font {
    /// Map a point size onto the closest system text style.
    ///
    /// `.custom(_:size:)` renders at a fixed size and **ignores the user's
    /// text-size setting entirely** — which is why changing it in iOS Settings
    /// did nothing to this app. `.custom(_:size:relativeTo:)` scales from that
    /// size instead, so every label grows and shrinks with the system. Picking
    /// a nearby style matters because each one has its own scaling curve:
    /// captions grow proportionally more than large titles.
    private static func textStyle(for size: CGFloat) -> Font.TextStyle {
        switch size {
        case ..<12:   return .caption2
        case ..<13:   return .caption
        case ..<14:   return .footnote
        case ..<16:   return .subheadline
        case ..<17:   return .callout
        case ..<20:   return .body
        case ..<23:   return .title3
        case ..<28:   return .title2
        default:      return .title
        }
    }

    static func moblyWordmark(size: CGFloat) -> Font {
        // The wordmark is a logo, not text — it stays a fixed size so the
        // header doesn't reflow at large accessibility settings.
        if MoblyFonts.isBundled("Fredoka-SemiBold") {
            return .custom("Fredoka-SemiBold", fixedSize: size)
        }
        return .system(size: size, weight: .semibold, design: .rounded)
    }

    static func moblyHeading(_ size: CGFloat = 22) -> Font {
        if MoblyFonts.isBundled("Fredoka-SemiBold") {
            return .custom("Fredoka-SemiBold", size: size, relativeTo: textStyle(for: size))
        }
        return .system(textStyle(for: size)).weight(.semibold)
    }

    static func moblyBody(_ size: CGFloat = 16, weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .medium: name = "Inter-Medium"
        case .semibold, .bold: name = "Inter-SemiBold"
        default: name = "Inter-Regular"
        }
        if MoblyFonts.isBundled(name) {
            return .custom(name, size: size, relativeTo: textStyle(for: size))
        }
        return .system(textStyle(for: size)).weight(weight)
    }
}
