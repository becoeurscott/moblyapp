import SwiftUI

struct WelcomeView: View {
    var onSignUp: () -> Void = {}
    var onSignIn: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var heroZoom: CGFloat = 1.08
    @State private var chipsIn = false
    @State private var cardIn = false

    var body: some View {
        GeometryReader { geo in
            // geo.size / geo.safeAreaInsets here are the normal, safe-area-aware
            // values — needed to correctly place the wordmark below the notch
            // and the card above the home indicator. The hero image below
            // bleeds past them on its own via .ignoresSafeArea() with NO
            // competing explicit frame, which is what lets it reach true
            // edge-to-edge without dragging the rest of the layout with it.
            let w = geo.size.width
            let h = geo.size.height

            ZStack(alignment: .bottom) {
                // ---- Top: wordmark + trust chip ----
                VStack(spacing: 12) {
                    Text("mobly")
                        .font(.moblyWordmark(size: 26))
                        .tracking(-0.3)
                        .foregroundStyle(.white)

                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Espaces vérifiés partout au Cameroun")
                            .font(.moblyBody(11, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        Capsule().fill(.ultraThinMaterial)
                            .environment(\.colorScheme, .dark)
                    )
                    .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
                    .opacity(chipsIn ? 1 : 0)
                    .offset(y: chipsIn ? 0 : -8)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, geo.safeAreaInsets.top + 8)

                // NOTE: GlassListingChip's HStack contains a Spacer(), which
                // greedily expands to fill whatever width the ZStack proposes
                // (the full screen) BEFORE .padding(.horizontal) is applied —
                // the padding then pushes it wider than the screen, so its
                // rounded corners land off-screen and it reads as a flat,
                // edge-to-edge band. Giving it an explicit width up front
                // (screen width minus the intended 24pt side margins) fixes
                // the proposal so Spacer() has a sane bound to expand within.
                GlassListingChip()
                    .frame(width: w - 48)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, h * 0.30)
                    .opacity(chipsIn ? 1 : 0)
                    .offset(y: chipsIn ? 0 : 14)

                // ---- Floating rounded card (reference cue) ----
                WelcomeCard(onSignUp: onSignUp, onSignIn: onSignIn)
                    .padding(.horizontal, 14)
                    .padding(.bottom, -8)
                    .opacity(cardIn ? 1 : 0)
                    .offset(y: cardIn ? 0 : 40)
            }
            .frame(width: w, height: h)
            .background(
                // Hero image + scrim live in .background(), fully decoupled
                // from the foreground content's own sizing — this is what
                // lets the photo bleed true edge-to-edge via ignoresSafeArea()
                // without stretching the card/buttons above it.
                ZStack {
                    Image("WelcomeHero")
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(heroZoom)
                        .clipped()

                    LinearGradient(
                        stops: [
                            .init(color: Color(hex: 0x080A20).opacity(0.50), location: 0.0),
                            .init(color: Color(hex: 0x080A20).opacity(0.05), location: 0.22),
                            .init(color: Color(hex: 0x080A20).opacity(0.10), location: 0.60),
                            .init(color: Color(hex: 0x080A20).opacity(0.12), location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .ignoresSafeArea()
            )
        }
        .onAppear(perform: runEntrance)
    }

    private func runEntrance() {
        if reduceMotion {
            heroZoom = 1.0; chipsIn = true; cardIn = true
            return
        }
        withAnimation(.easeOut(duration: 6).repeatForever(autoreverses: true)) {
            heroZoom = 1.16
        }
        withAnimation(.spring(response: 0.7, dampingFraction: 0.85).delay(0.15)) {
            chipsIn = true
        }
        withAnimation(.spring(response: 0.7, dampingFraction: 0.82).delay(0.3)) {
            cardIn = true
        }
    }
}

// MARK: - Floating card

private struct WelcomeCard: View {
    var onSignUp: () -> Void
    var onSignIn: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("Trouvez votre espace,\noù que vous soyez")
                .font(.moblyHeading(23))
                .foregroundStyle(Color(hex: 0x14152A))
                .multilineTextAlignment(.center)
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)

            Text("Chambres, bureaux, boutiques et plus — près de vous.")
                .font(.moblyBody(13))
                .foregroundStyle(Color(hex: 0x9A9DAC))
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.horizontal, 8)
                .padding(.top, 8)

            VStack(spacing: 10) {
                PillButton(title: "Créer un compte", style: .primaryBlue,
                           trailingIcon: nil, height: 52, action: onSignUp)
                PillButton(title: "J'ai déjà un compte", style: .outline,
                           trailingIcon: nil, height: 52, action: onSignIn)
            }
            .padding(.top, 18)
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 18)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.white)
        )
        .shadow(color: .black.opacity(0.22), radius: 28, x: 0, y: 14)
    }
}

// MARK: - Glass listing chip

private struct GlassListingChip: View {
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.22))
                Image(systemName: "house.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 2) {
                Text("Studio Akwa")
                    .font(.moblyHeading(14))
                    .foregroundStyle(.white)
                Text("Douala · 350m")
                    .font(.moblyBody(11))
                    .foregroundStyle(Color.white.opacity(0.7))
            }
            Spacer()
            Text("80k")
                .font(.moblyHeading(13.5))
                .foregroundStyle(.white)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
        )
    }
}

#Preview {
    WelcomeView()
}
