import SwiftUI

/// Full-screen block shown while the backend is in a maintenance window.
///
/// Covers everything — there is no dismiss and no back gesture, because every
/// API call behind it is refused anyway; letting the user through would only
/// show them empty screens and failed requests. It lets itself go the moment
/// `MaintenanceStore` sees the window lifted.
struct MaintenanceView: View {
    @ObservedObject private var store = MaintenanceStore.shared
    @State private var pulse = false

    private var copy: String {
        let m = store.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let m, !m.isEmpty { return m }
        return "Nous améliorons Mobly en ce moment. L'application sera de nouveau disponible très bientôt."
    }

    var body: some View {
        ZStack {
            // Same blue→violet ground as the splash and first onboarding slide,
            // so a blocked launch still reads as Mobly rather than an error page.
            LinearGradient(
                colors: [Color(hex: 0x3A4FF0), Color(hex: 0x2B2FB8)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            // Soft orange glow, echoing the splash.
            Circle()
                .fill(Color(hex: 0xFF6B35).opacity(0.28))
                .frame(width: 320, height: 320)
                .blur(radius: 90)
                .offset(y: -180)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 24)

                icon

                Text("mobly")
                    .font(.moblyWordmark(size: 34))
                    .foregroundStyle(.white)
                    .padding(.top, 22)

                Text("Maintenance en cours")
                    .font(.moblyBody(19, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.top, 14)

                Text(copy)
                    .font(.moblyBody(14.5))
                    .foregroundStyle(.white.opacity(0.78))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 34)
                    .padding(.top, 10)

                countdown
                    .padding(.top, 30)

                Spacer(minLength: 24)

                retryButton
                    .padding(.horizontal, 30)

                Text("Merci de votre patience.")
                    .font(.moblyBody(12.5))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.top, 14)
                    .padding(.bottom, 26)
            }
        }
        .transition(.opacity)
        // The screen is one announcement; VoiceOver should read it as such
        // rather than letting the user swipe through decorative pieces.
        .accessibilityElement(children: .contain)
        .onAppear { pulse = true }
    }

    // MARK: Pieces

    private var icon: some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.12))
                .frame(width: 116, height: 116)
                .scaleEffect(pulse ? 1.08 : 0.94)
                .animation(.easeInOut(duration: 1.9).repeatForever(autoreverses: true),
                           value: pulse)
            Circle()
                .fill(.white.opacity(0.16))
                .frame(width: 84, height: 84)
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.system(size: 33, weight: .medium))
                .foregroundStyle(.white)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var countdown: some View {
        if store.overdue {
            Text("Nous revenons d'un instant à l'autre…")
                .font(.moblyBody(14, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(Capsule().fill(.white.opacity(0.14)))
                .accessibilityLabel("Nous revenons d’un instant à l’autre")

        } else if let remaining = store.remaining {
            let p = Self.parts(from: remaining)
            VStack(spacing: 12) {
                Text("DE RETOUR DANS")
                    .font(.moblyBody(11, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(.white.opacity(0.6))

                HStack(spacing: 8) {
                    unit(p.days, "JOURS")
                    unit(p.hours, "HEURES")
                    unit(p.minutes, "MIN")
                    unit(p.seconds, "SEC")
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "De retour dans \(p.days) jours, \(p.hours) heures, \(p.minutes) minutes et \(p.seconds) secondes"
            )

        } else {
            // No end time was set — say so plainly rather than showing 00:00:00.
            Text("Durée indéterminée")
                .font(.moblyBody(14, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(Capsule().fill(.white.opacity(0.14)))
        }
    }

    private func unit(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 6) {
            Text(String(format: "%02d", value))
                .font(.moblyBody(27, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                // A fixed width stops the row from jittering as digits change.
                .frame(width: 62, height: 60)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.white.opacity(0.16))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.white.opacity(0.14), lineWidth: 1)
                )
                // Only the seconds box animates, so the row reads as a ticking
                // clock without the whole thing twitching every minute.
                .contentTransition(.numericText(countsDown: true))

            Text(label)
                .font(.moblyBody(9.5, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private var retryButton: some View {
        Button {
            Task { await store.recheck() }
        } label: {
            HStack(spacing: 8) {
                if store.checking {
                    ProgressView().tint(Color(hex: 0x3A4FF0))
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                }
                Text(store.checking ? "Vérification…" : "Réessayer")
                    .font(.moblyBody(15, weight: .semibold))
            }
            .foregroundStyle(Color(hex: 0x3A4FF0))
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Capsule().fill(.white))
        }
        .buttonStyle(.plain)
        .disabled(store.checking)
    }

    // MARK: Countdown maths

    static func parts(from interval: TimeInterval) -> (days: Int, hours: Int, minutes: Int, seconds: Int) {
        let total = max(0, Int(interval.rounded(.down)))
        return (total / 86400, (total % 86400) / 3600, (total % 3600) / 60, total % 60)
    }
}

#Preview {
    MaintenanceView()
}
