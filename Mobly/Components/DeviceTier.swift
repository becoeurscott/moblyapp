import SwiftUI
import UIKit

/// Whether to swap live blur / Liquid Glass for flat equivalents.
///
/// A13 and older (iPhone 11 / 11 Pro / SE 2nd gen and earlier) can't keep
/// 60 fps while recompositing a masked material band, a Gaussian-blurred glow
/// and `.glassEffect` under a scrolling feed — the tab bar alone made every
/// screen stutter on an iPhone 11. Newer chips keep the glass.
///
/// Also on whenever the user turned on Réduire la transparence, which is
/// Apple's own signal to drop blur.
enum DeviceTier {
    static let reducedEffects: Bool = {
        if let forced = ProcessInfo.processInfo.environment["MOBLY_REDUCED_EFFECTS"] {
            return forced == "1"
        }
        if UIAccessibility.isReduceTransparencyEnabled { return true }
        return isOlderThanA14(modelIdentifier)
    }()

    /// "iPhone12,1" on device; the simulated model in the Simulator.
    private static var modelIdentifier: String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    /// iPhone major numbers ≤ 12 are A13 or older (iPhone12,x = the 11 family
    /// and SE 2). iPads aren't graded: their GPUs carry the effects fine.
    private static func isOlderThanA14(_ id: String) -> Bool {
        guard id.hasPrefix("iPhone"),
              let major = Int(id.dropFirst("iPhone".count).prefix(while: \.isNumber))
        else { return false }
        return major <= 12
    }
}

extension AnyShapeStyle {
    /// `material` normally; a flat, near-opaque colour on reduced-effects
    /// devices. For chrome that floats over scrolling content, where a live
    /// material is recomposited every frame.
    static func frosted(_ material: Material,
                        fallback: Color = Color.white.opacity(0.97)) -> AnyShapeStyle {
        DeviceTier.reducedEffects ? AnyShapeStyle(fallback) : AnyShapeStyle(material)
    }
}
