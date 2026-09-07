import SwiftUI

/// Shown when this build is below the minimum version an operator configured.
///
/// Deliberately has no dismiss: every authenticated request is being refused
/// with 426, so there is nothing behind this screen that would work. The only
/// way forward is the App Store.
struct ForceUpdateView: View {
    let update: ForceUpdate

    @State private var appear = false

    var body: some View {
        ZStack {
            Color.moblySurface.ignoresSafeArea()

            VStack(spacing: 26) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.moblyPrimary.opacity(0.28), Color.moblyPrimary.opacity(0)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .frame(width: 220, height: 220)
                        .blur(radius: 40)
                    Circle()
                        .fill(.white)
                        .frame(width: 116, height: 116)
                        .shadow(color: Color.moblyPrimary.opacity(0.28), radius: 22, y: 10)
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 50, weight: .semibold))
                        .foregroundStyle(Color.moblyPrimary)
                }
                .scaleEffect(appear ? 1 : 0.9)
                .opacity(appear ? 1 : 0)

                VStack(spacing: 12) {
                    Text("Mise à jour requise")
                        .font(.moblyHeading(27))
                        .foregroundStyle(Color.moblyTextPrimary)
                        .multilineTextAlignment(.center)

                    Text(LT(update.message))
                        .font(.moblyBody(15))
                        .foregroundStyle(Color(hex: 0x666F80))
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 32)
                .opacity(appear ? 1 : 0)
                .offset(y: appear ? 0 : 10)

                Spacer()

                if let urlString = update.storeUrl, let url = URL(string: urlString) {
                    Button {
                        UIApplication.shared.open(url)
                    } label: {
                        HStack(spacing: 8) {
                            Text("Mettre à jour")
                                .font(.moblyHeading(15.5))
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 56)
                        .background(Color.moblyPrimary)
                        .clipShape(Capsule())
                        .shadow(color: Color.moblyPrimary.opacity(0.35), radius: 14, y: 8)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 24)
                }

                Text("Mobly · Votre espace, à portée de main.")
                    .font(.moblyBody(11.5))
                    .foregroundStyle(Color(hex: 0xC4C7D2))
                    .padding(.bottom, 24)
            }
        }
        .onAppear { withAnimation(.easeOut(duration: 0.5)) { appear = true } }
    }
}

/// Transient banner carrying the server's own explanation for a refused action
/// — a feature switched off, a restriction on the account, a frozen thread.
///
/// Sits at the top of the window rather than inside a screen because the
/// refusal can come from anywhere, including calls whose result the calling
/// view discarded.
struct BlockedBanner: View {
    let message: String
    var onDismiss: () -> Void

    @State private var dismissTask: Task<Void, Never>?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(hex: 0xE5950C))

            Text(LT(message))
                .font(.moblyBody(13.5))
                .foregroundStyle(Color.moblyTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white)
                .shadow(color: Color(hex: 0x14152A).opacity(0.12), radius: 16, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(hex: 0xE5950C).opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .onAppear {
            // Auto-dismiss so a stale explanation doesn't sit over the UI, but
            // long enough to read a full sentence of French prose.
            dismissTask?.cancel()
            dismissTask = Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if !Task.isCancelled { onDismiss() }
            }
        }
        .onDisappear { dismissTask?.cancel() }
    }
}
