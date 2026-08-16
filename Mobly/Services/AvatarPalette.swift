import SwiftUI

/// Per-user identity colour.
///
/// Each user owns an `avatarColor` (nullable `#RRGGBB` on the server). When
/// set, everything that renders that user — chat rows, chat header, profile
/// identity card, testimonials, notifications — pulls from the same value so
/// their identity is recognisable across the app. When the field is `null`
/// (new accounts, older rows) we fall back to a deterministic pick from this
/// palette based on the user id.
enum AvatarPalette {
    /// Preset choices offered in the picker.
    /// Order matters — the picker renders them in this order.
    static let presets: [String] = [
        "#3A4FF0", // brand blue
        "#FF6B35", // brand orange
        "#1F8A5B", // green
        "#8B5CF6", // purple
        "#D9A21B", // gold
        "#2E7BE4", // sky blue
        "#EC4899", // pink
        "#E5484D", // red
        "#0EA5E9", // cyan
        "#14152A", // midnight
    ]

    /// Deterministic fallback when the user hasn't picked one. Uses the id's
    /// stable hash so the same user always gets the same colour.
    static func fallback(for id: String) -> String {
        let h = id.reduce(0) { ($0 &* 31) &+ Int($1.asciiValue ?? 0) }
        return presets[abs(h) % presets.count]
    }

    /// Resolve to a Color: user's own if present, otherwise the fallback.
    static func color(for id: String, stored: String?) -> Color {
        Color(hex: hex(for: id, stored: stored))
    }

    /// Same as `color(for:stored:)` but returns the raw hex UInt (0xRRGGBB) —
    /// several existing call sites take `UInt32` directly.
    static func hexValue(for id: String, stored: String?) -> UInt32 {
        let s = hex(for: id, stored: stored)
        // Drop leading '#' if present, then parse as hex.
        let clean = s.hasPrefix("#") ? String(s.dropFirst()) : s
        return UInt32(clean, radix: 16) ?? 0x3A4FF0
    }

    /// The raw hex string used for a given user.
    static func hex(for id: String, stored: String?) -> String {
        if let stored, stored.range(of: #"^#?[0-9A-Fa-f]{6}$"#, options: .regularExpression) != nil {
            return stored.hasPrefix("#") ? stored : "#\(stored)"
        }
        return fallback(for: id)
    }

    /// Darker cousin — used as the second stop of a two-tone gradient.
    static func darker(_ hex: String) -> Color {
        Color(hex: shift(hex, factor: 0.72))
    }

    /// A pair of colours for a gradient: base → 28% darker.
    static func gradient(for id: String, stored: String?) -> [Color] {
        let base = hex(for: id, stored: stored)
        return [Color(hex: base), darker(base)]
    }

    // MARK: - Helpers

    /// Multiply RGB by `factor` (<1 = darker, >1 = lighter). Clamps to bytes.
    private static func shift(_ hex: String, factor: Double) -> UInt32 {
        let clean = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard let raw = UInt32(clean, radix: 16) else { return 0x3A4FF0 }
        let r = Double((raw >> 16) & 0xFF) * factor
        let g = Double((raw >> 8) & 0xFF) * factor
        let b = Double(raw & 0xFF) * factor
        let ri = UInt32(max(0, min(255, r)))
        let gi = UInt32(max(0, min(255, g)))
        let bi = UInt32(max(0, min(255, b)))
        return (ri << 16) | (gi << 8) | bi
    }
}

extension Color {
    /// Convenience for hex strings that include or omit the leading '#'.
    init(hex string: String) {
        let clean = string.hasPrefix("#") ? String(string.dropFirst()) : string
        let raw = UInt32(clean, radix: 16) ?? 0x3A4FF0
        self.init(hex: raw)
    }
}
