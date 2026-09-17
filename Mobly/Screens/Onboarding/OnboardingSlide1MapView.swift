import SwiftUI
import Combine

struct OnboardingSlide1MapView: View {
    var onSkip: () -> Void
    var onNext: () -> Void

    @State private var appeared = false

    /// Slide-1 signature gradient — brand blue easing into dark blue.
    static let bg = LinearGradient(colors: [Color(hex: 0x3A4FF0), Color(hex: 0x071B5C)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)

    var body: some View {
        // Background gradient is owned by OnboardingView (single full-screen layer).
        VStack(spacing: 0) {
            OnboardingTopBar(skipTint: Color.white.opacity(0.7), onSkip: onSkip)
                .padding(.top, 12)

            ListingDeck(appeared: appeared)
                .padding(.horizontal, 22)
                .padding(.top, 18)

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 0) {
                PageIndicator(count: 3, current: 0,
                              activeColor: .white,
                              inactiveColor: Color.white.opacity(0.30))
                    .padding(.bottom, 22)

                Text("Trouvez l'espace qu'il vous faut")
                    .font(.moblyHeading(25))
                    .foregroundStyle(.white)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Chambres, studios, bureaux, boutiques… parcourez des centaines d'espaces vérifiés partout au Cameroun.")
                    .font(.moblyBody(14))
                    .foregroundStyle(Color.white.opacity(0.8))
                    .lineSpacing(3)
                    .padding(.top, 10)
                    .padding(.bottom, 28)

                PillButton(title: "Suivant", style: .onBlue, action: onNext)
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
            ZStack {
                // Peek cards — centered (never clipped), just scaled/nudged up.
                OnbShowcaseCard(card: card(2))
                    .frame(width: w * 0.92)
                    .scaleEffect(0.86).offset(y: -26).opacity(0.55)
                    .zIndex(0)
                OnbShowcaseCard(card: card(1))
                    .frame(width: w * 0.92)
                    .scaleEffect(0.93).offset(y: -13).opacity(0.85)
                    .zIndex(1)

                // Front card — swipes off on change, next scales up underneath.
                OnbShowcaseCard(card: card(0))
                    .frame(width: w * 0.92)
                    .id(top)
                    .zIndex(2)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.93).combined(with: .opacity),
                        removal: .modifier(active: SwipeOff(active: true),
                                           identity: SwipeOff(active: false))))

                // Floating category chips — always in front of the deck
                chip("Studios", "bed.double.fill")
                    .position(x: w * 0.13, y: w * 0.10 + (float ? -7 : 7))
                    .opacity(appeared ? 1 : 0).zIndex(10)
                    .animation(.easeInOut(duration: 2.3).repeatForever(autoreverses: true), value: float)
                chip("Bureaux", "briefcase.fill")
                    .position(x: w * 0.87, y: w * 0.26 + (float ? 8 : -6))
                    .opacity(appeared ? 1 : 0).zIndex(10)
                    .animation(.easeInOut(duration: 2.9).repeatForever(autoreverses: true), value: float)
                chip("Villas", "house.fill")
                    .position(x: w * 0.85, y: w * 0.90 + (float ? -6 : 6))
                    .opacity(appeared ? 1 : 0).zIndex(10)
                    .animation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true), value: float)
            }
            .frame(width: w, height: geo.size.height)
            .scaleEffect(appeared ? 1 : 0.9)
            .opacity(appeared ? 1 : 0)
            .animation(Motion.gentle, value: appeared)
        }
        .aspectRatio(0.86, contentMode: .fit)
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
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 18)
    }
}
