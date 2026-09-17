import SwiftUI

/// The owner dashboard as a full-screen space, opened the same way from Home
/// and from Profile. Presenting it full screen (rather than pushing it inside
/// the Profile stack) keeps the tab bar out of the way, and the short branded
/// intro makes entering "Mon espace propriétaire" feel like switching modes.
struct OwnerDashboardCover: View {
    @State private var phase: Phase = .intro

    private enum Phase { case intro, revealing, shown }

    var body: some View {
        ZStack {
            NavigationStack { OwnerDashboardView() }
                .opacity(phase == .intro ? 0 : 1)
                .scaleEffect(phase == .intro ? 0.94 : 1)
                .offset(y: phase == .intro ? 24 : 0)

            if phase != .shown {
                intro
                    .opacity(phase == .intro ? 1 : 0)
                    .scaleEffect(phase == .intro ? 1 : 1.08)
                    .allowsHitTesting(false)
            }
        }
        .background(Color.moblySurface.ignoresSafeArea())
        .task {
            // Two seconds in all: hold the intro, then reveal the dashboard.
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            withAnimation(.easeInOut(duration: 0.6)) { phase = .revealing }
            try? await Task.sleep(nanoseconds: 600_000_000)
            phase = .shown
        }
    }

    private var intro: some View {
        ZStack {
            LinearGradient(colors: [Color.moblyPrimary, Color(hex: 0x2A3ADB)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 22).fill(.white.opacity(0.16))
                        .frame(width: 84, height: 84)
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.bounce, value: phase)
                }
                Text("Mon espace propriétaire")
                    .font(.moblyHeading(20))
                    .foregroundStyle(.white)
            }
            .transition(.scale)
        }
    }
}
