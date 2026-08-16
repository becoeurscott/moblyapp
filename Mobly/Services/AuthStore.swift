import Foundation
import Combine

/// Owns the signed-in user and every auth transition.
///
/// The screens stay dumb: they call these methods and render `phase`, `isBusy`
/// and `errorMessage`. All server-error translation happens here, in one place,
/// keyed off `MoblyAPI.Code` — never off message text.
@MainActor
final class AuthStore: ObservableObject {
    static let shared = AuthStore()

    @Published private(set) var user: UserDTO?
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?
    /// Machine-readable form of the last failure. Callers branch on this —
    /// comparing `errorMessage` breaks the moment any wording changes.
    @Published private(set) var lastErrorCode: MoblyAPI.Code?
    /// Dev-mode convenience: the server echoes the code back so the simulator
    /// can prefill it. Always nil once OTP_DEV_MODE is off.
    @Published private(set) var devCode: String?
    /// Seconds the server says to wait before another code can be requested.
    @Published private(set) var resendCooldown: Int = 0
    /// Per-field server messages, keyed by field name ("phone", "email", …).
    @Published private(set) var fieldErrors: [String: String] = [:]
    /// Set when the server says the account already exists — drives the
    /// "connectez-vous" prompt rather than a plain inline error.
    @Published var accountExistsMessage: String?
    /// Code length the server is issuing. Read from the response so the two
    /// can't drift — hardcoding it is how the UI ended up asking for 6 digits
    /// while the backend sent 4.
    @Published private(set) var codeLength: Int = 4

    var isSignedIn: Bool { user != nil }

    private let api = MoblyAPI.shared
    private var cooldownTimer: Timer?

    private init() {
        // A refused refresh (expired, revoked, or reuse detected) ends the
        // session wherever the app happens to be.
        NotificationCenter.default.addObserver(
            forName: MoblyAPI.sessionExpired, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.user = nil
                Session.shared.signOutLocal()
                ChatStore.shared.stop()
                self?.errorMessage = "Votre session a expiré. Reconnectez-vous."
            }
        }
    }

    // MARK: - Launch

    /// Restore the session at launch. A token in the Keychain only means we
    /// *had* a session — it may have been revoked server-side since, so this
    /// confirms with /me rather than trusting local state.
    func bootstrap() async {
        guard api.isAuthenticated else { return }
        do {
            let u = try await api.me()
            apply(u)
        } catch let e as MoblyAPI.APIError {
            // Offline at launch isn't a sign-out — keep the token and retry later.
            if !e.isOffline { api.clearSession() }
        } catch {
            // Leave the session alone on an unrecognised failure.
        }
    }

    // MARK: - OTP

    /// Ask for a code. Returns false and sets `errorMessage` on failure.
    func requestCode(phone: String) async -> Bool {
        let normalized = Self.normalizePhone(phone)
        guard Self.isValidPhone(normalized) else {
            errorMessage = "Numéro de téléphone invalide."
            return false
        }

        isBusy = true
        errorMessage = nil
        lastErrorCode = nil
        fieldErrors = [:]
        defer { isBusy = false }

        do {
            let res = try await api.requestOTP(phone: normalized)
            devCode = res.devCode
            startCooldown(60)
            return true
        } catch let e as MoblyAPI.APIError {
            // The server owns the cooldown; parse the seconds it reports so the
            // countdown matches reality instead of a guess.
            if e.code == .otpRateLimited, let secs = Self.secondsIn(e.message) {
                startCooldown(secs)
            }
            lastErrorCode = e.code
            fieldErrors = e.fields
            errorMessage = message(for: e)
            return false
        } catch {
            errorMessage = "Impossible d'envoyer le code. Réessayez."
            return false
        }
    }

    /// Verify a code. On success the tokens are stored and `user` is set.
    func verifyCode(phone: String, code: String,
                    fullName: String? = nil, email: String? = nil) async -> Bool {
        isBusy = true
        errorMessage = nil
        lastErrorCode = nil
        fieldErrors = [:]
        defer { isBusy = false }

        do {
            let res = try await api.verifyOTP(
                phone: Self.normalizePhone(phone),
                code: code.filter(\.isNumber),
                fullName: fullName?.trimmingCharacters(in: .whitespaces).nilIfEmpty,
                isOwner: nil
            )
            apply(res.user)
            devCode = nil
            return true
        } catch let e as MoblyAPI.APIError {
            lastErrorCode = e.code
            fieldErrors = e.fields
            errorMessage = message(for: e)
            return false
        } catch {
            errorMessage = "Vérification impossible. Réessayez."
            return false
        }
    }

    // MARK: - Signup

    /// Step 1: validate the whole form server-side and send the code.
    /// Field errors land in `fieldErrors`; a duplicate sets `accountExistsMessage`.
    func startSignup(fullName: String, phone: String,
                     email: String, password: String) async -> Bool {
        isBusy = true
        errorMessage = nil
        lastErrorCode = nil
        fieldErrors = [:]
        accountExistsMessage = nil
        defer { isBusy = false }

        do {
            let res = try await api.signupStart(.init(
                fullName: fullName.trimmingCharacters(in: .whitespaces),
                phone: Self.normalizePhone(phone),
                email: email.trimmingCharacters(in: .whitespaces).lowercased(),
                password: password
            ))
            devCode = res.devCode
            codeLength = res.codeLength
            startCooldown(60)
            return true
        } catch let e as MoblyAPI.APIError {
            lastErrorCode = e.code
            fieldErrors = e.fields
            if e.code == .alreadyExists {
                // Distinct from a validation error: the fix is to sign in, not
                // to correct the field.
                accountExistsMessage = e.message
            } else {
                if e.code == .otpRateLimited, let secs = Self.secondsIn(e.message) {
                    startCooldown(secs)
                }
                errorMessage = message(for: e)
            }
            return false
        } catch {
            errorMessage = "Inscription impossible. Réessayez."
            return false
        }
    }

    /// Step 2: confirm the code and create the account.
    func verifySignup(fullName: String, phone: String, email: String,
                      password: String, code: String) async -> Bool {
        isBusy = true
        errorMessage = nil
        lastErrorCode = nil
        fieldErrors = [:]
        defer { isBusy = false }

        do {
            let res = try await api.signupVerify(.init(
                fullName: fullName.trimmingCharacters(in: .whitespaces),
                phone: Self.normalizePhone(phone),
                email: email.trimmingCharacters(in: .whitespaces).lowercased(),
                password: password,
                code: code.filter(\.isNumber)
            ))
            apply(res.user)
            devCode = nil
            return true
        } catch let e as MoblyAPI.APIError {
            lastErrorCode = e.code
            fieldErrors = e.fields
            if e.code == .alreadyExists { accountExistsMessage = e.message }
            else { errorMessage = message(for: e) }
            return false
        } catch {
            errorMessage = "Vérification impossible. Réessayez."
            return false
        }
    }

    /// Set when the typed e-mail is a character or two from an existing one.
    @Published private(set) var similarEmailHint: String?

    /// True while the debounced availability request is either pending (in
    /// its debounce window) or in flight. The signup button reads this so it
    /// doesn't flash "enabled" between an edit and the server's answer.
    @Published private(set) var isCheckingAvailability = false

    /// Called from the view's `.task(id:)` the moment the phone/e-mail
    /// combination changes, so the "already used" error clears without
    /// waiting for the 600 ms debounce + round-trip. The taken state will be
    /// re-established (or confirmed cleared) once `checkAvailability` returns.
    func beginCheckingAvailability() {
        isCheckingAvailability = true
        var next = fieldErrors
        if next["phone"] == "Ce numéro est déjà utilisé" { next["phone"] = nil }
        if next["email"] == "Cet e-mail est déjà utilisé" { next["email"] = nil }
        fieldErrors = next
    }

    /// Live availability while typing. Silent on failure — this is a hint, and
    /// the authoritative check happens at /signup/start anyway.
    func checkAvailability(phone: String?, email: String?) async {
        isCheckingAvailability = true
        defer { isCheckingAvailability = false }
        guard let res = try? await api.checkAvailability(phone: phone, email: email) else { return }
        similarEmailHint = res.similarEmail
        var next = fieldErrors
        if let taken = res.phoneTaken {
            if taken { next["phone"] = "Ce numéro est déjà utilisé" }
            else if next["phone"] == "Ce numéro est déjà utilisé" { next["phone"] = nil }
        }
        if let taken = res.emailTaken {
            if taken { next["email"] = "Cet e-mail est déjà utilisé" }
            else if next["email"] == "Cet e-mail est déjà utilisé" { next["email"] = nil }
        }
        fieldErrors = next
    }

    // MARK: - Password reset

    /// Masked destination for display only, e.g. "+237 6•• •• •• 66".
    @Published private(set) var resetPhone: String?
    /// Signed token identifying the account being reset. The real phone never
    /// reaches the client.
    private var resetToken: String?

    /// Step 1: ask for a reset code.
    func forgotPassword(identifier: String) async -> Bool {
        isBusy = true
        errorMessage = nil
        lastErrorCode = nil
        fieldErrors = [:]
        defer { isBusy = false }

        do {
            let res = try await api.forgotPassword(identifier: identifier)
            resetPhone = res.maskedPhone
            resetToken = res.resetToken
            devCode = res.devCode
            codeLength = res.codeLength
            startCooldown(60)
            return true
        } catch let e as MoblyAPI.APIError {
            lastErrorCode = e.code
            fieldErrors = e.fields
            if e.code == .otpRateLimited, let secs = Self.secondsIn(e.message) {
                startCooldown(secs)
            }
            errorMessage = message(for: e)
            return false
        } catch {
            errorMessage = "Impossible d'envoyer le code. Réessayez."
            return false
        }
    }

    /// Step 2: confirm the code and set the new password. On success the user
    /// is signed in and every other session is revoked server-side.
    func resetPassword(code: String, newPassword: String) async -> Bool {
        guard let resetToken else { return false }
        isBusy = true
        errorMessage = nil
        lastErrorCode = nil
        fieldErrors = [:]
        defer { isBusy = false }

        do {
            let res = try await api.resetPassword(resetToken: resetToken, code: code,
                                                  password: newPassword)
            apply(res.user)
            devCode = nil
            resetPhone = nil
            self.resetToken = nil
            return true
        } catch let e as MoblyAPI.APIError {
            lastErrorCode = e.code
            fieldErrors = e.fields
            errorMessage = message(for: e)
            return false
        } catch {
            errorMessage = "Réinitialisation impossible. Réessayez."
            return false
        }
    }

    // MARK: - Password

    func signIn(identifier: String, password: String) async -> Bool {
        isBusy = true
        errorMessage = nil
        lastErrorCode = nil
        fieldErrors = [:]
        defer { isBusy = false }

        // A phone typed into the shared identifier field still needs
        // normalizing, or "+237 6 77..." won't match the stored value.
        let id = identifier.contains("@")
            ? identifier.trimmingCharacters(in: .whitespaces)
            : Self.normalizePhone(identifier)

        do {
            struct Body: Encodable { let identifier: String; let password: String }
            let res: AuthResponse = try await api.request(
                "auth/login", method: "POST", body: Body(identifier: id, password: password)
            )
            api.store(token: res.token, refreshToken: res.refreshToken)
            apply(res.user)
            return true
        } catch let e as MoblyAPI.APIError {
            lastErrorCode = e.code
            fieldErrors = e.fields
            errorMessage = message(for: e)
            return false
        } catch {
            errorMessage = "Connexion impossible. Réessayez."
            return false
        }
    }

    // MARK: - Sign in with Apple

    /// Complete a Sign-in with Apple after `ASAuthorizationController` returns
    /// an identity token. The full name is only present on the *first* Apple
    /// sign-in; we forward it so the server can persist it before Apple stops
    /// sharing it.
    func signInWithApple(idToken: String, fullName: String?) async -> Bool {
        isBusy = true
        errorMessage = nil
        lastErrorCode = nil
        defer { isBusy = false }
        do {
            let res = try await api.signInWithApple(idToken: idToken, fullName: fullName)
            apply(res.user)
            return true
        } catch let e as MoblyAPI.APIError {
            lastErrorCode = e.code
            errorMessage = message(for: e)
            return false
        } catch {
            errorMessage = "Connexion Apple impossible. Réessayez."
            return false
        }
    }

    /// Complete a Sign in with Google after the OAuth callback returns an
    /// idToken. Same success/failure surface as Apple.
    func signInWithGoogle(idToken: String) async -> Bool {
        isBusy = true
        errorMessage = nil
        lastErrorCode = nil
        defer { isBusy = false }
        do {
            let res = try await api.signInWithGoogle(idToken: idToken)
            apply(res.user)
            return true
        } catch let e as MoblyAPI.APIError {
            lastErrorCode = e.code
            errorMessage = message(for: e)
            return false
        } catch {
            errorMessage = "Connexion Google impossible. Réessayez."
            return false
        }
    }

    /// Attach a password to the freshly created account so the user can sign in
    /// with it next time. Best-effort: OTP already proved ownership of the
    /// number, so failing here must not block signup.
    func setPassword(_ password: String) async {
        guard password.count >= 6 else { return }
        struct Body: Encodable { let password: String }
        _ = try? await api.request(
            "auth/me", method: "PATCH", body: Body(password: password), authorized: true
        ) as EmptyResponse
    }

    /// Overwrite the avatar URL on the local user without waiting for a
    /// full `bootstrap()` — the identity card / edit sheet / chat rows
    /// switch to the new photo immediately after upload.
    func applyAvatarUrl(_ url: String) {
        guard var u = user else { return }
        let json = """
        {"id":"\(u.id)","phone":"\(u.phone)","fullName":"\(u.fullName)",
        "email":\(u.email.map { "\"\($0)\"" } ?? "null"),
        "isOwner":\(u.isOwner),"verified":\(u.verified),
        "city":\(u.city.map { "\"\($0)\"" } ?? "null"),
        "region":\(u.region.map { "\"\($0)\"" } ?? "null"),
        "rating":\(u.rating.map { String($0) } ?? "null"),
        "avatarUrl":"\(url)",
        "avatarColor":\(u.avatarColor.map { "\"\($0)\"" } ?? "null"),
        "isAdmin":\(u.isAdmin ?? false)}
        """
        _ = u
        if let data = json.data(using: .utf8),
           let updated = try? JSONDecoder().decode(UserDTO.self, from: data) {
            self.user = updated
        }
    }

    /// Flip the signed-in user to owner on the SERVER. Without this, a purely
    /// local `Session.upgradeToOwner()` leaves the DB row's `isOwner = false`,
    /// so `POST /listings` and every other `requireOwner` route returns 403 —
    /// the annonce never reaches the database and the chat button that would
    /// open a thread about it 404s ("Impossible d'ouvrir la conversation").
    /// Returns true on success so callers can wait before publishing.
    @discardableResult
    func becomeOwnerOnServer() async -> Bool {
        guard api.isAuthenticated else { return false }
        do {
            let updated = try await api.updateMe(isOwner: true)
            user = updated
            Session.shared.isOwner = true
            return true
        } catch {
            return false
        }
    }

    func signOut(allDevices: Bool = false) async {
        // ORDER MATTERS. Unregister the push device FIRST, while the access
        // token is still valid — `api.logout()` clears the session, and a
        // DELETE /devices sent afterwards 401s, leaving the handset bound to
        // the previous account. The next person to hold the phone would then
        // receive push notifications for messages sent to the old user.
        await PushService.shared.unregister()
        await api.logout(allDevices: allDevices)

        user = nil
        Session.shared.signOutLocal()

        // Wipe every trace of the previous user. Anything persisted under a
        // GLOBAL key (not namespaced by user id) leaks across accounts on a
        // shared device — common in this market — so each store below must be
        // reset explicitly. Adding a new persisted store? Clear it here too.
        ChatStore.shared.stop()
        ChatStore.shared.clearLocal()          // threads + messages + disk cache
        UserDataStore.shared.clear()           // favourites + notifications
        OwnerListings.shared.annonces = []     // owner's published annonces
        SavedSearchStore.shared.clear()        // saved recherches
        ThreadPrefs.shared.clearAll()          // pin / mute / archive / deleted
        BlockedUsers.shared.clearAll()         // blocked peers
        VisitRequestStore.shared.clearAll()    // visit inbox (visitor phone numbers)
    }

    // MARK: - Internals

    #if DEBUG
    /// Debug-only: inject a synthetic user so screenshot routes (`START_AT=…`)
    /// have an authenticated session without hitting the API.
    func debugSetUser(id: String, name: String) {
        let json = """
        {"id":"\(id)","phone":"","fullName":"\(name)","email":null,"isOwner":false,
        "verified":true,"city":"Douala","region":null,"rating":null,"avatarUrl":null,
        "avatarColor":null,"isAdmin":false}
        """
        if let data = json.data(using: .utf8),
           let u = try? JSONDecoder().decode(UserDTO.self, from: data) {
            self.user = u
        }
    }
    #endif

    private func apply(_ u: UserDTO) {
        user = u
        // Bring the user's own data online as soon as there's a session.
        ChatStore.shared.start()
        Task {
            // Link the anonymous analytics session to this account so the
            // pre-sign-in events (splash, welcome, sign-up funnel) survive.
            await SessionTracker.shared.attach()
            SessionTracker.shared.log("auth.signin", ["isOwner": u.isOwner])
            // The APNs token often arrives before sign-in, so register it here
            // too — otherwise the first session after install gets no pushes.
            await PushService.shared.sync()
            await UserDataStore.shared.loadAll()
            if u.isOwner {
                await UserDataStore.shared.loadMyListings()
                OwnerListings.shared.load(from: UserDataStore.shared.myListings)
            }
        }
        // Keep the existing UserDefaults-backed Session in sync so the many
        // views already reading Session.shared don't each need rewiring.
        Session.shared.signIn(fullName: u.fullName, phone: u.phone, isOwner: u.isOwner)
        Session.shared.userId = u.id
    }

    private func message(for e: MoblyAPI.APIError) -> String {
        switch e.code {
        case .otpInvalid:     return "Code incorrect. Vérifiez et réessayez."
        case .otpExpired:     return "Ce code a expiré. Demandez-en un nouveau."
        case .otpLocked:      return "Trop de tentatives. Demandez un nouveau code."
        case .otpRateLimited: return e.message
        case .rateLimited:    return "Trop de tentatives. Patientez quelques minutes."
        case .accountNotFound: return e.message   // "Aucun compte avec cet e-mail/ce numéro"
        case .invalidPassword: return "Mot de passe incorrect."
        case .noPasswordSet:
            return "Ce compte n’a pas de mot de passe. Utilisez « Se connecter par SMS »."
        case .unauthenticated where e.status == 401:
            return "Identifiants incorrects."
        case .offline:        return "Pas de connexion. Vérifiez votre réseau."
        case .validationFailed: return "Vérifiez les informations saisies."
        case .internalError:
            // Surface the request id — it's the only thing that makes a user
            // report traceable in the logs.
            return e.requestId.map { "Erreur serveur. Référence : \(String($0.prefix(8)))" }
                ?? "Erreur serveur. Réessayez."
        default:              return e.message
        }
    }

    private func startCooldown(_ seconds: Int) {
        cooldownTimer?.invalidate()
        resendCooldown = seconds
        guard seconds > 0 else { return }
        cooldownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self else { t.invalidate(); return }
                if self.resendCooldown > 0 { self.resendCooldown -= 1 }
                if self.resendCooldown <= 0 { t.invalidate() }
            }
        }
    }

    private static func secondsIn(_ message: String) -> Int? {
        // Server message reads "Patientez 42s avant de redemander un code".
        let digits = message.compactMap { $0.isNumber ? $0 : nil }
        return Int(String(digits))
    }

    // MARK: - Phone normalization

    /// Normalize to E.164, defaulting to Cameroon (+237).
    ///
    /// The signup form shows "+237" as a static prefix and the user types only
    /// the local part, while sign-in accepts a full number — both land here so
    /// the value sent to the server is identical either way.
    static func normalizePhone(_ raw: String) -> String {
        var s = raw.filter { $0.isNumber || $0 == "+" }
        if s.hasPrefix("+") {
            return s
        }
        if s.hasPrefix("00") { return "+" + s.dropFirst(2) }
        if s.hasPrefix("237") { return "+" + s }
        // Local Cameroonian numbers are sometimes written with a leading 0.
        if s.hasPrefix("0") { s = String(s.dropFirst()) }
        return "+237" + s
    }

    static func isValidPhone(_ e164: String) -> Bool {
        let digits = e164.filter(\.isNumber)
        return e164.hasPrefix("+") && digits.count >= 8 && digits.count <= 15
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
