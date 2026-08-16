import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }

    static let moblyPrimary        = Color(hex: 0x3A4FF0)
    static let moblyAccent         = Color(hex: 0xFF6B35)
    static let moblyTextPrimary    = Color(hex: 0x1A1A2E)
    static let moblyTextSecondary  = Color(hex: 0x666666)
    static let moblySurface        = Color(hex: 0xFAFAF7)
    static let moblySurfaceTint    = Color(hex: 0xEEF0FE)
    static let moblyDivider        = Color(hex: 0xE5E7EB)
}
