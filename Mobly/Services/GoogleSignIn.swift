import Foundation
import AuthenticationServices
import CryptoKit
import UIKit

/// Sign in with Google — implemented manually against Google's OAuth 2.0
/// endpoints via `ASWebAuthenticationSession` + PKCE, so we don't ship the
/// full GoogleSignIn SDK just to get an idToken.
///
/// Flow:
///   1. Build the authorize URL with `response_type=code`, `code_challenge`
///      (SHA256 of a random verifier), and our reversed-domain redirect URI.
///   2. Present it in ASWebAuthenticationSession. Google shows their standard
///      sign-in web UI in a system browser sheet.
///   3. On success, the callback URL has `?code=...`. Exchange that code at
///      `oauth2.googleapis.com/token` (POST form-encoded) with the PKCE
///      `code_verifier`. Public iOS clients have no client secret.
///   4. Response contains `id_token` (a JWT signed by Google) which we send to
///      our backend `/auth/google` for verification.
///
/// The token exchange must succeed on the client because Google requires the
/// redirect URI *exactly* — including the app URL scheme — and only the app
/// itself has that scheme registered.
enum GoogleSignIn {

    /// The iOS OAuth client id from Google Cloud Console.
    /// Reversed = the URL scheme that the app registers in Info.plist.
    private static let clientId =
        "961218606453-3ovpslv8p174c6sii8t9h3otb7gn4er9.apps.googleusercontent.com"

    /// The reversed-domain redirect URI Google expects for iOS OAuth.
    /// Standard shape: `<reversed-client-id>:/oauth2redirect`.
    private static var redirectURI: String {
        let reversed = "com.googleusercontent.apps.\(clientId.replacingOccurrences(of: ".apps.googleusercontent.com", with: ""))"
        return "\(reversed):/oauth2redirect"
    }
    private static var callbackScheme: String {
        "com.googleusercontent.apps.\(clientId.replacingOccurrences(of: ".apps.googleusercontent.com", with: ""))"
    }

    /// Present Google's OAuth UI and return the idToken. Throws on cancel or
    /// any network / parse failure; the caller shows a generic message.
    @MainActor
    static func presentAndGetIdToken(from presenter: UIWindow?) async throws -> String {
        let verifier = codeVerifier()
        let challenge = codeChallenge(from: verifier)
        let state = UUID().uuidString

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "openid email profile"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            // Force the account chooser so the user can pick which Google
            // account — otherwise it silently signs in with the last one.
            .init(name: "prompt", value: "select_account"),
        ]

        let callbackURL: URL = try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(
                url: comps.url!,
                callbackURLScheme: callbackScheme
            ) { url, error in
                if let url {
                    cont.resume(returning: url)
                } else {
                    cont.resume(throwing: error ?? GoogleSignInError.cancelled)
                }
            }
            session.presentationContextProvider = WindowAnchor(window: presenter)
            // Ephemeral so the user is asked which account each time; the
            // browser session doesn't stick around in Safari's cookies.
            session.prefersEphemeralWebBrowserSession = true
            session.start()
        }

        // Parse the callback: `?code=AUTH_CODE&state=...`
        guard let callbackComps = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let items = callbackComps.queryItems,
              let code = items.first(where: { $0.name == "code" })?.value,
              items.first(where: { $0.name == "state" })?.value == state
        else {
            throw GoogleSignInError.invalidCallback
        }

        // Exchange the auth code for tokens.
        var body = URLComponents()
        body.queryItems = [
            .init(name: "code", value: code),
            .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "code_verifier", value: verifier),
        ]
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GoogleSignInError.tokenExchangeFailed
        }

        struct TokenResponse: Decodable {
            let id_token: String?
        }
        guard let parsed = try? JSONDecoder().decode(TokenResponse.self, from: data),
              let idToken = parsed.id_token
        else {
            throw GoogleSignInError.tokenExchangeFailed
        }

        return idToken
    }

    // MARK: - PKCE helpers

    /// A high-entropy random string (43–128 chars) used as the code_verifier.
    /// RFC 7636 requires unreserved characters only; base64url-encoded random
    /// bytes fit that constraint.
    private static func codeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    /// SHA256(verifier), base64url-encoded — this is the S256 challenge.
    private static func codeChallenge(from verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }
}

enum GoogleSignInError: Error {
    case cancelled
    case invalidCallback
    case tokenExchangeFailed
}

/// ASWebAuthenticationSession asks its presenter for a UIWindow to anchor the
/// system sheet on. On modern iOS, any key window will do.
private final class WindowAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    let window: UIWindow?
    init(window: UIWindow?) { self.window = window }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let w = window { return w }
        // Fall back to any key window across scenes.
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
            ?? UIWindow()
    }
}

private extension Data {
    /// base64url = base64 with `+` → `-`, `/` → `_`, no padding.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
