import SwiftUI

/// One motion scale for the whole app.
///
/// Before this existed every screen invented its own curve — 15 different
/// `easeInOut(duration:)` values across 40 files — so two things that moved
/// for the same reason moved differently. Everything interactive now picks a
/// token from here; only ambient loops (shimmer, pulses) keep bespoke timing,
/// because those are decoration, not feedback.
///
/// Springs rather than eases: an ease that stops dead reads as mechanical,
/// while a lightly damped spring settles the way a physical control does.
enum Motion {
    /// Immediate feedback the finger is still touching — chips, toggles, stars.
    static let instant = Animation.snappy(duration: 0.18, extraBounce: 0.02)
    /// Small state flips: selection, filter chips, badge counts.
    static let quick = Animation.snappy(duration: 0.26, extraBounce: 0.04)
    /// The default. Anything appearing, hiding, expanding or reflowing.
    static let standard = Animation.smooth(duration: 0.32)
    /// Larger surfaces: panels, overlays, section reveals.
    static let panel = Animation.spring(response: 0.42, dampingFraction: 0.86)
    /// Long, calm reveals — first paint of a screen, hero fades.
    static let gentle = Animation.smooth(duration: 0.5)
    /// Something the user should notice: a heart filling, a success check.
    static let pop = Animation.bouncy(duration: 0.36, extraBounce: 0.18)
    /// Data arriving on its own, with nobody waiting on it. Deliberately the
    /// softest curve in the set: a silent background refresh must read as the
    /// screen settling, never as a reload.
    static let content = Animation.smooth(duration: 0.4)

    /// Staggered entrance for row `i` — each item trails the one above it by a
    /// hair so a list assembles instead of snapping in as a block.
    static func stagger(_ i: Int, step: Double = 0.04, cap: Double = 0.32) -> Animation {
        standard.delay(min(Double(i) * step, cap))
    }
}

extension AnyTransition {
    /// Fade + a few points of rise. The house transition for content that
    /// appears in place (cards, banners, empty states). Removal is a plain
    /// fade — content leaving should not draw the eye on its way out.
    static var moblyAppear: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 8)),
            removal: .opacity
        )
    }
}

extension View {
    /// Animate `value` changes with a Motion token.
    func motion<V: Equatable>(_ animation: Animation = Motion.standard, value: V) -> some View {
        self.animation(animation, value: value)
    }
}

/// A press effect that any tappable card can adopt: scales down while held and
/// springs back on release, so touch targets acknowledge the finger before the
/// navigation happens.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(Motion.instant, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
    static func pressable(scale: CGFloat) -> PressableStyle { PressableStyle(scale: scale) }
}
