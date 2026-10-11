import SwiftUI

/// Stand-in for a whole screen whose feature an operator switched off.
///
/// Entry points are hidden when a flag is off, but a screen can still be
/// reached from an older route (a notification, a deep link) or be on screen
/// when the switch flips. This says why it is empty, in the operator's words,
/// instead of showing a half-working screen.
struct FeatureOffView: View {
    let flag: String
    var title: String = "Indisponible"
    var onClose: (() -> Void)? = nil

    @ObservedObject private var config = RemoteConfigStore.shared

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Color(hex: 0xEEF0FE)).frame(width: 78, height: 78)
                Image(systemName: "pause.circle")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Color.moblyPrimary)
            }
            Text(title)
                .font(.moblyHeading(18))
                .foregroundStyle(Color.moblyTextPrimary)
            Text(config.message(for: flag))
                .font(.moblyBody(13.5))
                .foregroundStyle(Color(hex: 0x9A9DAC))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 40)
            if let onClose {
                Button("Fermer", action: onClose)
                    .font(.moblyBody(14, weight: .semibold))
                    .foregroundStyle(Color.moblyPrimary)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
    }
}
