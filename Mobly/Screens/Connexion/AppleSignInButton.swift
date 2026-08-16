import SwiftUI
import AuthenticationServices

/// "Continuer avec Apple" button.
///
/// Drives `ASAuthorizationController` directly rather than using
/// `SignInWithAppleButton`, because that native button locks its typography —
/// which put the Apple label at a different visible size from the Google
/// button next to it. This custom shell keeps the Apple logo + French
/// "Continuer avec Apple" copy (still App Store compliant) but lets the font
/// match the rest of the auth screen (`moblyHeading(16)`).
///
/// **Apple only ships `fullName` and `email` on the FIRST sign-in.** Subsequent
/// sign-ins arrive with those fields empty — the server persists them the
/// first time so we don't have to.
struct AppleSignInButton: View {
    var onCompletion: (Bool) -> Void = { _ in }

    @State private var isBusy = false

    var body: some View {
        Button(action: start) {
            HStack(spacing: 9) {
                if isBusy {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "applelogo")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                }
                Text(isBusy ? "Connexion…" : "Continuer avec Apple")
                    .font(.moblyHeading(16))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(Capsule().fill(Color(hex: 0x14152A)))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }

    private func start() {
        isBusy = true
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]

        let controller = ASAuthorizationController(authorizationRequests: [request])
        let delegate = AppleSignInDelegate { result in
            isBusy = false
            switch result {
            case .success(let (idToken, name)):
                Task {
                    let ok = await AuthStore.shared.signInWithApple(idToken: idToken, fullName: name)
                    onCompletion(ok)
                }
            case .failure:
                // Includes user-cancelled. Silent — no toast needed.
                onCompletion(false)
            }
        }
        controller.delegate = delegate
        controller.presentationContextProvider = delegate
        // Keep the delegate alive for the duration of the request.
        AppleSignInDelegate.retained = delegate
        controller.performRequests()
    }
}

// MARK: - Delegate

private final class AppleSignInDelegate: NSObject,
                                        ASAuthorizationControllerDelegate,
                                        ASAuthorizationControllerPresentationContextProviding {
    /// The system holds only a weak reference to a controller delegate; without
    /// this static latch the delegate would be released before the sheet ever
    /// calls back.
    static var retained: AppleSignInDelegate?

    let onCompletion: (Result<(String, String?), Error>) -> Void
    init(_ onCompletion: @escaping (Result<(String, String?), Error>) -> Void) {
        self.onCompletion = onCompletion
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization auth: ASAuthorization) {
        defer { Self.retained = nil }
        guard
            let credential = auth.credential as? ASAuthorizationAppleIDCredential,
            let tokenData = credential.identityToken,
            let idToken = String(data: tokenData, encoding: .utf8)
        else {
            onCompletion(.failure(NSError(domain: "AppleSignIn", code: -1)))
            return
        }
        let name: String? = {
            let parts = [credential.fullName?.givenName, credential.fullName?.familyName]
                .compactMap { $0 }
                .joined(separator: " ")
            return parts.isEmpty ? nil : parts
        }()
        onCompletion(.success((idToken, name)))
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithError error: Error) {
        defer { Self.retained = nil }
        onCompletion(.failure(error))
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
            ?? UIWindow()
    }
}
