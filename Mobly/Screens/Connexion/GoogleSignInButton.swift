import SwiftUI

/// "Continuer avec Google" — visually matches the existing social buttons but
/// actually drives the OAuth flow.
struct GoogleSignInButton: View {
    @State private var isBusy = false

    var body: some View {
        Button(action: start) {
            HStack(spacing: 9) {
                if isBusy {
                    ProgressView().tint(Color.moblyTextPrimary)
                } else {
                    // Google's brand "G" — colored letter on white matches
                    // their sign-in button guidelines closely enough for
                    // review, without pulling in the SDK's asset catalogue.
                    Text("G").font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color(hex: 0x4285F4))
                }
                Text(isBusy ? "Connexion…" : "Continuer avec Google")
                    .font(.moblyHeading(16))
                    .foregroundStyle(Color.moblyTextPrimary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(Capsule().fill(.white))
            .overlay(Capsule().stroke(Color(hex: 0xE2E4EC), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }

    private func start() {
        isBusy = true
        Task { @MainActor in
            defer { isBusy = false }
            let anchor = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }
            do {
                let idToken = try await GoogleSignIn.presentAndGetIdToken(from: anchor)
                _ = await AuthStore.shared.signInWithGoogle(idToken: idToken)
            } catch {
                // Cancelled / offline / bad callback — AuthStore surfaces
                // sign-in errors, and cancel isn't worth its own toast.
            }
        }
    }
}
