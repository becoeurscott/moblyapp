import SwiftUI
import Combine

struct OnboardingSlide1MapView: View {
    var showWordmark: Bool = true
    var onSkip: () -> Void
    var onNext: () -> Void

    @State private var appeared = false

    /// Slide 1 now shares the light ground of slides 2 and 3 — the brand blue
    /// is concentrated in the hero panel below instead of flooding the screen,
    /// so the three slides read as one set rather than a dark cover bolted to
    /// a light product tour.
    static var bg: some View { Color.moblySurface }

    /// The hero panel's fill: the same brand-blue-to-navy ramp slide 3 uses for
    /// its avatar, so the accent is quoted from the set rather than invented.
    static let heroGradient = LinearGradient(
        colors: [Color(hex: 0x4A5CF5), Color.moblyPrimary, Color(hex: 0x071B5C)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    var body: some View {
        // Background gradient is owned by OnboardingView (single full-screen layer).
        VStack(spacing: 0) {
            // Destination of the splash hand-off. Centred in its own layer so
            // it lands on the screen's midline regardless of how wide "Passer"
            // is — laying them out side by side in an HStack would push the
            // wordmark off-centre by half the button's width.
            ZStack {
                Text("mobly")
                    .font(.moblyWordmark(size: 26))
                    .tracking(-0.5)
                    .foregroundStyle(Color.moblyPrimary)
                    // Hidden until RootView's flying wordmark lands here.
                    .opacity(showWordmark ? 1 : 0)

                OnboardingTopBar(skipTint: Color(hex: 0x9A9DAC), onSkip: onSkip)
            }
            // Fixed height: RootView's flying wordmark lands at exactly
            // top + 12 + 18, so this must not depend on content size.
            .frame(height: WordmarkFlight.headerHeight)
            .padding(.top, WordmarkFlight.headerTop)

            // Hero panel. The deck sits inside a rounded blue surface rather
            // than on a full-bleed background: it gives the slide one clear
            // focal point, and the inset edges plus a cast shadow are what make
            // it read as a considered object instead of a coloured screen.
            ZStack {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(Self.heroGradient)
                    // Two shadows: a tight contact shade and a wide soft one.
                    // A single blur reads flat at this size.
                    .shadow(color: Color(hex: 0x0B1E6B).opacity(0.30), radius: 28, y: 18)
                    .shadow(color: Color(hex: 0x14152A).opacity(0.10), radius: 6, y: 2)
                    // A hairline highlight along the top edge — the detail that
                    // separates a premium surface from a plain filled rectangle.
                    .overlay(
                        RoundedRectangle(cornerRadius: 32, style: .continuous)
                            .strokeBorder(
                                LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.04)],
                                               startPoint: .top, endPoint: .bottom),
                                lineWidth: 1
                            )
                    )

                ListingDeck(appeared: appeared)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
            }
            .frame(height: 340)
            .padding(.horizontal, 18)
            .padding(.top, 22)

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 0) {
                PageIndicator(count: 3, current: 0)
                    .padding(.bottom, 22)

                Text("Trouvez l'espace qu'il vous faut")
                    .font(.moblyHeading(25))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Chambres, studios, bureaux, boutiques… parcourez des centaines d'espaces vérifiés partout au Cameroun.")
                    .font(.moblyBody(14))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                    .lineSpacing(3)
                    .padding(.top, 10)
                    .padding(.bottom, 28)

                PillButton(title: "Suivant", style: .primaryBlue, action: onNext)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 40)
        }
        .onAppear {
            withAnimation(Motion.gentle.delay(0.1)) {
                appeared = true
            }
        }
    }
}

// MARK: - Fanned listing deck

private struct ListingDeck: View {
    var appeared: Bool

    /// Always the bundled showcase properties, cycled through the deck.
    private var cards: [Listing] { OnboardingShowcase.listings }

    @State private var top = 0                       // index of the front card
    @State private var float = false
    private let timer = Timer.publish(every: 3.0, on: .main, in: .common).autoconnect()

    private func card(_ offset: Int) -> Listing { cards[(top + offset) % cards.count] }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                // Peek cards — centered (never clipped), just scaled/nudged up.
                OnbShowcaseCard(card: card(2))
                    .frame(width: w * 0.90)
                    .scaleEffect(0.88).offset(y: -22).opacity(0.50)
                    .zIndex(0)
                OnbShowcaseCard(card: card(1))
                    .frame(width: w * 0.90)
                    .scaleEffect(0.94).offset(y: -11).opacity(0.80)
                    .zIndex(1)

                // Front card — swipes off on change, next scales up underneath.
                OnbShowcaseCard(card: card(0))
                    .frame(width: w * 0.90)
                    .offset(y: 8)
                    .id(top)
                    .zIndex(2)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.93).combined(with: .opacity),
                        removal: .modifier(active: SwipeOff(active: true),
                                           identity: SwipeOff(active: false))))

                // Floating category chips — always in front of the deck
                chip("Studios", "bed.double.fill")
                    .position(x: w * 0.20, y: h * 0.12 + (float ? -6 : 6))
                    .opacity(appeared ? 1 : 0).zIndex(10)
                    .animation(.easeInOut(duration: 2.3).repeatForever(autoreverses: true), value: float)
                chip("Bureaux", "briefcase.fill")
                    .position(x: w * 0.80, y: h * 0.40 + (float ? 7 : -5))
                    .opacity(appeared ? 1 : 0).zIndex(10)
                    .animation(.easeInOut(duration: 2.9).repeatForever(autoreverses: true), value: float)
                chip("Villas", "house.fill")
                    .position(x: w * 0.26, y: h * 0.84 + (float ? -5 : 5))
                    .opacity(appeared ? 1 : 0).zIndex(10)
                    .animation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true), value: float)
            }
            .frame(width: w, height: geo.size.height)
            .scaleEffect(appeared ? 1 : 0.9)
            .opacity(appeared ? 1 : 0)
            .animation(Motion.gentle, value: appeared)
        }
        // No aspect ratio: the panel above owns the height now, and the deck
        // fills it. Deriving a height here is what let the panel stretch.
        .onAppear { float = true }
        .onReceive(timer) { _ in
            withAnimation(Motion.gentle) { top = (top + 1) % cards.count }
        }
    }

    private func chip(_ text: String, _ icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold))
            Text(LT(text)).font(.moblyHeading(11.5))
        }
        .foregroundStyle(Color.moblyPrimary)
        .padding(.horizontal, 11).padding(.vertical, 7)
        .background(Capsule().fill(.white))
        .shadow(color: .black.opacity(0.18), radius: 7, y: 4)
    }
}

// Front card leaves by swiping off to the left with a slight tilt + fade.
private struct SwipeOff: ViewModifier {
    var active: Bool
    func body(content: Content) -> some View {
        content
            .offset(x: active ? -460 : 0, y: active ? 30 : 0)
            .rotationEffect(.degrees(active ? -16 : 0))
            .opacity(active ? 0 : 1)
    }
}

// MARK: - Listing card (identical for every card in the deck)

private struct OnbShowcaseCard: View {
    let card: Listing
    var body: some View {
        ListingCover(listing: card)
            .frame(height: 252)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            // A thin light edge lifts the card off the blue panel; without it
            // dark cover photos bleed into the gradient behind them.
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
            )
            .shadow(color: Color(hex: 0x04103F).opacity(0.42), radius: 22, y: 16)
    }
}
