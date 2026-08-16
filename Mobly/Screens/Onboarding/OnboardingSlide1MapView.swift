import SwiftUI
import Combine

struct OnboardingSlide1MapView: View {
    var onSkip: () -> Void
    var onNext: () -> Void

    @State private var appeared = false

    /// Slide-1 signature gradient — brand blue easing into violet.
    static let bg = LinearGradient(colors: [Color(hex: 0x3A4FF0), Color(hex: 0x6D2FE0)],
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
            withAnimation(.spring(response: 0.7, dampingFraction: 0.8).delay(0.1)) {
                appeared = true
            }
        }
    }
}

// MARK: - Fanned listing deck

private struct ListingDeck: View {
    var appeared: Bool

    /// Bundled fallback for the very first launch, before the API has answered.
    /// Once ListingStore populates, we swap to real properties instead.
    private static let fallback: [Listing] = [
        Listing(id: "onb-1", title: "Studio meublé · Akwa", location: "Douala, Cameroun",
                price: "80 000 FCFA", rating: "4.8", imageName: "ListingGreen",
                category: "Studios"),
        Listing(id: "onb-2", title: "Villa · Bonapriso", location: "Douala, Cameroun",
                price: "350 000 FCFA", rating: "4.9", imageName: "ListingPink",
                category: "Villas"),
        Listing(id: "onb-3", title: "Bureau · Bonanjo", location: "Douala, Cameroun",
                price: "150 000 FCFA", rating: "4.6", imageName: "ListingYellow",
                category: "Bureaux"),
    ]

    @ObservedObject private var store = ListingStore.shared

    /// Live listings from the DB, cycled to fill the deck. Falls back to
    /// the bundled samples ONLY when the store returned nothing at all —
    /// otherwise the onboarding cards never contradict what the user will
    /// find inside the app.
    private var cards: [Listing] {
        let live = store.listings
        if live.isEmpty { return Self.fallback }
        // Cycle so a small DB (1 or 2 listings) still fills the 3-card deck
        // without showing hardcoded properties that don't exist.
        var out: [Listing] = []
        for i in 0..<3 { out.append(live[i % live.count]) }
        return out
    }

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
                    .frame(width: w * 0.80)
                    .scaleEffect(0.86).offset(y: -26).opacity(0.55)
                    .zIndex(0)
                OnbShowcaseCard(card: card(1))
                    .frame(width: w * 0.80)
                    .scaleEffect(0.93).offset(y: -13).opacity(0.85)
                    .zIndex(1)

                // Front card — swipes off on change, next scales up underneath.
                OnbShowcaseCard(card: card(0))
                    .frame(width: w * 0.80)
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
            .animation(.spring(response: 0.6, dampingFraction: 0.78), value: appeared)
        }
        .aspectRatio(0.86, contentMode: .fit)
        .onAppear { float = true }
        .onReceive(timer) { _ in
            withAnimation(.easeInOut(duration: 0.5)) { top = (top + 1) % cards.count }
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
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                ListingCover(listing: card)
                    .frame(height: 168).clipped()
                HStack {
                    Label("Vérifié", systemImage: "checkmark.seal.fill")
                        .font(.moblyBody(10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Capsule().fill(Color.moblyPrimary.opacity(0.92)))
                    Spacer()
                    Image(systemName: "heart.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.moblyAccent)
                        .padding(8)
                        .background(Circle().fill(.white))
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                }
                .padding(12)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(card.title)
                        .font(.moblyHeading(15)).foregroundStyle(Color(hex: 0x14152A)).lineLimit(1)
                    Spacer()
                    HStack(spacing: 3) {
                        Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(Color.moblyAccent)
                        Text(card.rating).font(.moblyBody(12, weight: .semibold)).foregroundStyle(Color(hex: 0x14152A))
                    }
                }
                HStack(spacing: 4) {
                    Image(systemName: "mappin.circle.fill").font(.system(size: 11)).foregroundStyle(Color(hex: 0x9A9DAC))
                    Text(card.location).font(.moblyBody(11.5)).foregroundStyle(Color(hex: 0x9A9DAC))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 13)
        }
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.white))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 18)
    }
}
