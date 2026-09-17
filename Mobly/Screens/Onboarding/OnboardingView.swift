import SwiftUI

struct OnboardingView: View {
    var onFinished: () -> Void = {}

    @State private var index: Int = {
        if let raw = ProcessInfo.processInfo.environment["ONBOARDING_START"],
           let i = Int(raw), (0..<3).contains(i) {
            return i
        }
        return 0
    }()
    private let slideCount = 3

    var body: some View {
        ZStack {
            // Background changes per slide with a soft crossfade
            Group {
                switch index {
                case 0: OnboardingSlide1MapView.bg
                case 1: Color.moblySurface
                default: Color.white
                }
            }
            .ignoresSafeArea()
            .animation(Motion.gentle, value: index)

            TabView(selection: $index) {
                OnboardingSlide1MapView(
                    onSkip: onFinished,
                    onNext: { advance() }
                )
                .tag(0)

                OnboardingSlide3ChatView(
                    onSkip: onFinished,
                    onBack: { retreat() },
                    onNext: { advance() }
                )
                .tag(1)

                OnboardingSlide2ListingView(
                    onSkip: onFinished,
                    onBack: { retreat() },
                    onStart: onFinished
                )
                .tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(Motion.gentle, value: index)
        }
    }

    private func advance() {
        let next = min(index + 1, slideCount - 1)
        withAnimation(Motion.gentle) { index = next }
    }

    private func retreat() {
        let prev = max(index - 1, 0)
        withAnimation(Motion.gentle) { index = prev }
    }
}

// Shared bits used by every slide
struct OnboardingTopBar: View {
    var skipTint: Color
    var onSkip: () -> Void
    var body: some View {
        HStack {
            Spacer()
            Button(action: onSkip) {
                Text("Passer")
                    .font(.moblyBody(13.5, weight: .semibold))
                    .foregroundStyle(skipTint)
            }
        }
        .padding(.horizontal, 22)
    }
}

#Preview {
    OnboardingView()
}

// MARK: - Showcase properties

/// The properties the onboarding slides show. Bundled on purpose: live
/// listings put whatever owners uploaded (screenshots, QR codes, blurry
/// phone photos) in front of a brand-new user.
enum OnboardingShowcase {
    static let listings: [Listing] = [
        item(1, "Appartement · Bonapriso", "Douala", "250 000 FCFA", "4.9", "Appartements", "Meublé · 2 ch"),
        item(2, "Studio moderne · Akwa", "Douala", "120 000 FCFA", "4.8", "Studios", "Meublé · 1 ch"),
        item(3, "Bureau privé · Bonanjo", "Douala", "180 000 FCFA", "4.7", "Bureaux", "Bureau équipé"),
        item(4, "Bureau · Bastos", "Yaoundé", "150 000 FCFA", "4.6", "Bureaux", "Prêt à l'emploi"),
        item(5, "Salle de réunion · Bonanjo", "Douala", "25 000 FCFA", "4.8", "Coworking", "8 places · Écran"),
        item(6, "Cabinet · Bonapriso", "Douala", "200 000 FCFA", "4.9", "Bureaux", "Réception · 2 pièces"),
        item(7, "Espace coworking · Deido", "Douala", "5 000 FCFA", "4.5", "Coworking", "Wifi · Café"),
        item(8, "Boutique · Akwa", "Douala", "300 000 FCFA", "4.7", "Boutiques", "Vitrine · Éclairage"),
    ]

    private static func item(_ n: Int, _ title: String, _ city: String, _ price: String,
                             _ rating: String, _ category: String, _ subtitle: String) -> Listing {
        var l = Listing(id: "onb-\(n)", title: title, location: "\(city), Cameroun",
                        price: price, rating: rating, imageName: "Onboarding\(n)",
                        category: category)
        l.subtitle = subtitle
        return l
    }
}
