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
            .animation(.easeInOut(duration: 0.55), value: index)

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
            .animation(.easeInOut(duration: 0.55), value: index)
        }
    }

    private func advance() {
        let next = min(index + 1, slideCount - 1)
        withAnimation(.easeInOut(duration: 0.55)) { index = next }
    }

    private func retreat() {
        let prev = max(index - 1, 0)
        withAnimation(.easeInOut(duration: 0.55)) { index = prev }
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
