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

extension AnyTransition {
    /// Entering a full-screen route from the splash.
    ///
    /// A plain cross-fade between two opaque full-screen views reads as a cut:
    /// for the whole blend both screens are semi-transparent and the eye sees a
    /// flash rather than a movement. Easing the incoming screen up from 98%
    /// gives the change a direction, which is what makes it feel smooth. The
    /// outgoing splash deliberately gets no scale — a matchedGeometryEffect
    /// carries the wordmark across, and scaling its container would fight the
    /// matched geometry and distort the logo mid-flight.
    static var moblyScreen: AnyTransition {
        // Scales DOWN to 1.0, never up from below it. At 0.98 the arriving
        // screen was smaller than the window for the length of the transition,
        // so a ring of whatever sat underneath showed around its edges — with
        // the blue splash behind the photo-backed Welcome that read as a
        // second background behind the first, which is not what the motion was
        // meant to say. Starting slightly over-sized keeps the incoming screen
        // covering the full window the whole way through, so the only thing
        // that changes is the screen itself.
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 1.02)),
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

/// The splash wordmark flying up into the onboarding header: starts as the
/// splash logo (white, 48pt, centred) and lands as the header logo (blue, 26pt).
struct WordmarkFlight: View {
    static let headerHeight: CGFloat = 36
    static let headerTop: CGFloat = 12
    static let welcomeTop: CGFloat = 24

    enum Destination { case onboarding, welcome }

    var landed: Bool
    var destination: Destination = .onboarding

    /// Separate state for the colour transition so it runs on its own
    /// timing without interfering with position/scale animation.
    @State private var colorLanded = false

    private var landedTop: CGFloat { destination == .onboarding ? Self.headerTop : Self.welcomeTop }
    private var landedColor: Color { destination == .onboarding ? .moblyPrimary : .white }

    var body: some View {
        GeometryReader { geo in
            let splashScale = max(min(geo.size.width / 402, 1.4), 0.85)
            let landingScale = 26 / (48 * splashScale)
            let landingTracking: CGFloat = destination == .welcome ? -0.3 : -0.5
            Text("mobly")
                .font(.moblyWordmark(size: 48 * splashScale))
                .tracking(landed ? landingTracking / landingScale : -0.5)
                .foregroundStyle(colorLanded ? landedColor : .white)
                .scaleEffect(landed ? landingScale : 1)
                .position(x: geo.size.width / 2,
                          y: landed ? landedTop + Self.headerHeight / 2
                                    : geo.size.height / 2 - 26)
        }
        // Share the screens' safe-area coordinate space at both endpoints.
        // Ignoring it here shifts the logo when the overlay takes over or lands.
        .onChange(of: landed) { _, newValue in
            if newValue {
                withAnimation(.easeIn(duration: 0.2).delay(0.25)) {
                    colorLanded = true
                }
            } else {
                colorLanded = false
            }
        }
    }
}
