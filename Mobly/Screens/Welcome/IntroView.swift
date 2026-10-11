import SwiftUI

/// First screen for signed-out users at each cold start, before Welcome.
/// A full-bleed interior photo fading into white, a short pitch and a
/// single "Continuer" button.
struct IntroView: View {
    var onContinue: () -> Void

    @State private var appeared = false

    var body: some View {
        GeometryReader { geo in
            let photoHeight = geo.size.height * 0.70
            ZStack(alignment: .top) {
                Color.white.ignoresSafeArea()

                Image("IntroHero")
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: photoHeight + geo.safeAreaInsets.top, alignment: .top)
                    .clipped()
                    .overlay(alignment: .bottom) {
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0), location: 0),
                                .init(color: .white.opacity(0.7), location: 0.5),
                                .init(color: .white, location: 0.85)
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                        .frame(height: (photoHeight + geo.safeAreaInsets.top) * 0.29)
                    }
                    .scaleEffect(appeared ? 1 : 1.06, anchor: .top)
                    .ignoresSafeArea(edges: .top)

                VStack(spacing: 0) {
                    Spacer(minLength: photoHeight - 24)

                    VStack(spacing: 14) {
                        Text("Votre prochain espace\nvous attend")
                            .font(.moblyHeading(30))
                            .foregroundStyle(Color.moblyTextPrimary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Chambres, appartements, bureaux et boutiques vérifiés partout au Cameroun. Trouvez, visitez et réservez en toute confiance.")
                            .font(.moblyBody(15))
                            .foregroundStyle(Color.moblyTextSecondary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 28)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 14)

                    Spacer(minLength: 20)

                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onContinue()
                    } label: {
                        Text("Continuer")
                            .font(.moblyHeading(16))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(Capsule().fill(Color.moblyPrimary))
                            .shadow(color: Color.moblyPrimary.opacity(0.28), radius: 14, y: 6)
                    }
                    .buttonStyle(IntroPressStyle())
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 20)
                }
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) { appeared = true }
        }
    }
}

private struct IntroPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
