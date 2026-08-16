import SwiftUI

struct SplashView: View {
    var onFinished: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var wordmarkOpacity: Double = 0
    @State private var wordmarkScale: CGFloat = 0.94
    @State private var glowScale: CGFloat = 0.85
    @State private var glowOpacity: Double = 0.55

    private let holdSeconds: Double = 1.6

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let designReference: CGFloat = 402
            let scale = max(min(w / designReference, 1.4), 0.85)
            let wordmarkSize = 48 * scale
            let glowSize = 540 * scale

            ZStack {
                Color.moblyPrimary
                    .ignoresSafeArea()

                Circle()
                    .fill(
                        RadialGradient(
                            gradient: Gradient(colors: [
                                Color.moblyAccent.opacity(0.22),
                                Color.moblyAccent.opacity(0.0)
                            ]),
                            center: .center,
                            startRadius: 0,
                            endRadius: glowSize / 2
                        )
                    )
                    .frame(width: glowSize, height: glowSize)
                    .scaleEffect(glowScale)
                    .opacity(glowOpacity)
                    .position(x: w / 2, y: h / 2 - glowSize * 0.08)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)

                VStack(spacing: 14) {
                    Text("mobly")
                        .font(.moblyWordmark(size: wordmarkSize))
                        .tracking(-0.5)
                        .foregroundStyle(.white)
                        .opacity(wordmarkOpacity)
                        .scaleEffect(wordmarkScale)
                }
                .offset(y: -26)

                VStack(spacing: 18) {
                    Spacer()
                    LoaderDots()
                        .opacity(wordmarkOpacity)
                    Text("Votre espace, à portée de main.")
                        .font(.moblyBody(13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.72))
                        .opacity(wordmarkOpacity * 0.9)
                        .padding(.bottom, max(geo.safeAreaInsets.bottom + 24, 56))
                }
            }
            .frame(width: w, height: h)
        }
        .onAppear(perform: runEntrance)
    }

    private func runEntrance() {
        if reduceMotion {
            wordmarkOpacity = 1
            wordmarkScale = 1
            glowOpacity = 1
            glowScale = 1
        } else {
            withAnimation(.easeOut(duration: 0.55)) {
                wordmarkOpacity = 1
            }
            withAnimation(.interpolatingSpring(stiffness: 180, damping: 18).delay(0.05)) {
                wordmarkScale = 1
            }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                glowOpacity = 1.0
                glowScale = 1.05
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + holdSeconds) {
            onFinished()
        }
    }
}

private struct LoaderDots: View {
    @State private var animating = false
    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 6, height: 6)
                    .scaleEffect(animating ? 1.0 : 0.5)
                    .opacity(animating ? 1.0 : 0.3)
                    .animation(
                        .easeInOut(duration: 0.6)
                        .repeatForever()
                        .delay(Double(i) * 0.15),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}

#Preview {
    SplashView()
}
