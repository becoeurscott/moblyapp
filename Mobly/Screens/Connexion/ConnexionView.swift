import SwiftUI

enum AuthMode { case signin, signup }
private enum AuthPhase { case form, code, loading, welcome, resetCode, resetPassword }

/// Unified auth screen: the Connexion / Inscription toggle stays static at the
/// top and only the form body swaps between the two modes — so the user can
/// freely switch back and forth without any screen navigation.
struct ConnexionView: View {
    var initialMode: AuthMode = .signin
    var onExit: () -> Void = {}
    var onFinish: () -> Void = {}

    @ObservedObject private var auth = AuthStore.shared

    @State private var mode: AuthMode
    @State private var phase: AuthPhase = {
        // Debug hook to screenshot a specific phase directly.
        if ProcessInfo.processInfo.environment["AUTH_PHASE"] == "code" { return .code }
        if ProcessInfo.processInfo.environment["AUTH_PHASE"] == "welcome" { return .welcome }
        return .form
    }()

    // Fields
    @State private var identifier = ""     // sign-in
    @State private var fullName: String = ProcessInfo.processInfo.environment["PREFILL_NAME"] ?? ""
    @State private var phone: String = ProcessInfo.processInfo.environment["PREFILL_PHONE"] ?? ""
    @State private var country: Country = .deviceDefault
    @State private var email: String = ProcessInfo.processInfo.environment["PREFILL_EMAIL"] ?? ""
    @State private var password: String = ProcessInfo.processInfo.environment["PREFILL_PASSWORD"] ?? ""
    @State private var otp = ""
    @State private var newPassword = ""

    init(initialMode: AuthMode = .signin,
         onExit: @escaping () -> Void = {},
         onFinish: @escaping () -> Void = {}) {
        self.initialMode = initialMode
        self.onExit = onExit
        self.onFinish = onFinish
        _mode = State(initialValue: {
            if ProcessInfo.processInfo.environment["AUTH_MODE"] == "signup" { return .signup }
            if ProcessInfo.processInfo.environment["AUTH_MODE"] == "signin" { return .signin }
            return initialMode
        }())
    }

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            switch phase {
            case .form:    formView.transition(.opacity)
            case .code:    codeView.transition(.opacity)
            case .loading: loadingView.transition(.opacity)
            case .welcome: welcomeView.transition(.opacity)
            case .resetCode:     resetCodeView.transition(.opacity)
            case .resetPassword: resetPasswordView.transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: phase)
        // Flag a taken number/e-mail while the user is still typing rather than
        // after they submit. Debounced so each keystroke isn't a request.
        .task(id: availabilityKey) {
            guard mode == .signup else { return }
            // Clear any stale "already used" errors immediately — otherwise
            // the button reads a state that doesn't match what's on-screen
            // during the 600 ms debounce window. Also flips
            // `isCheckingAvailability = true`, which keeps `canSubmit` false
            // through both the debounce and the round-trip.
            auth.beginCheckingAvailability()
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            let p = phoneForAuth
            await auth.checkAvailability(
                phone: AuthStore.isValidPhone(p) ? p : nil,
                email: (email.contains("@") && email.contains(".")) ? email : nil
            )
        }
        .alert("Compte existant",
               isPresented: .constant(auth.accountExistsMessage != nil)) {
            Button("Se connecter") {
                auth.accountExistsMessage = nil
                switchTo(.signin)
                withAnimation { phase = .form }
            }
            Button("Modifier", role: .cancel) { auth.accountExistsMessage = nil }
        } message: {
            Text(auth.accountExistsMessage ?? "")
        }
    }

    // MARK: - Form (toggle stays static; body swaps by mode)

    private var formView: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Button(action: onExit) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.moblyTextPrimary)
                        .frame(width: 40, height: 40)
                        .background(RoundedRectangle(cornerRadius: 13).fill(Color(hex: 0xF4F5F8)))
                }
                .padding(.bottom, 22)

                Text("mobly")
                    .font(.moblyWordmark(size: 24))
                    .tracking(-0.3)
                    .foregroundStyle(Color.moblyPrimary)
                    .padding(.bottom, 6)

                Text(mode == .signin ? "Content de vous revoir" : "Créer un compte")
                    .font(.moblyHeading(24))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .padding(.bottom, 6)

                Text(mode == .signin
                     ? "Connectez-vous pour retrouver vos recherches et vos annonces."
                     : "Rejoignez Mobly pour trouver ou publier un espace en quelques minutes.")
                    .font(.moblyBody(13.5))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                    .lineSpacing(2)
                    .padding(.bottom, 22)

                // The static toggle — same position in both modes.
                AuthModeToggle(
                    isSignIn: mode == .signin,
                    onSignIn: { switchTo(.signin) },
                    onSignUp: { switchTo(.signup) }
                )
                .padding(.bottom, 24)

                if mode == .signin { signInFields } else { signUpFields }

                if mode == .signin, auth.lastErrorCode == .accountNotFound {
                    // The account doesn't exist — the useful action is to
                    // create one, not to retype the password.
                    HStack(spacing: 6) {
                        Text("Pas encore inscrit ?")
                            .font(.moblyBody(12.5))
                            .foregroundStyle(Color(hex: 0x9A9DAC))
                        Button("Créer un compte") { switchTo(.signup) }
                            .font(.moblyBody(12.5, weight: .bold))
                            .foregroundStyle(Color.moblyPrimary)
                        Spacer()
                    }
                    .padding(.bottom, 12)
                }

                if let error = auth.errorMessage {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.moblyAccent)
                        Text(LT(error))
                            .font(.moblyBody(12.5, weight: .medium))
                            .foregroundStyle(Color.moblyAccent)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12)
                        .fill(Color.moblyAccent.opacity(0.08)))
                    .padding(.bottom, 14)
                    .transition(.opacity)
                }

                PillButton(title: submitTitle,
                           style: .primaryBlue, trailingIcon: nil, action: submit)
                    .opacity(canSubmit && !auth.isBusy ? 1 : 0.5)
                    .disabled(!canSubmit || auth.isBusy)
                    .padding(.top, 4)
                    .padding(.bottom, 16)

                AuthDivider(text: "ou").padding(.bottom, 16)

                VStack(spacing: 11) {
                    GoogleSignInButton()
                    AppleSignInButton { _ in
                        // AuthStore updates `user` on success, which flips
                        // RootView into the signed-in screen automatically.
                    }
                }
                .padding(.bottom, 22)

                HStack(spacing: 5) {
                    Spacer()
                    Text(mode == .signin ? "Pas encore de compte ?" : "Déjà inscrit ?")
                        .font(.moblyBody(13))
                        .foregroundStyle(Color(hex: 0x9A9DAC))
                    Button(mode == .signin ? "S'inscrire" : "Se connecter") {
                        switchTo(mode == .signin ? .signup : .signin)
                    }
                    .font(.moblyBody(13, weight: .bold))
                    .foregroundStyle(Color.moblyPrimary)
                    Spacer()
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
    }

    // MARK: Sign-in fields

    private var signInFields: some View {
        VStack(alignment: .leading, spacing: 0) {
            IdentifierField(
                text: $identifier,
                country: $country,
                errorMessage: auth.fieldErrors["identifier"],
                onSubmit: { if canSubmit { submit() } }
            )
            Spacer().frame(height: 16)

            MoblyTextField(
                label: "Mot de passe",
                placeholder: "••••••••",
                systemIcon: "lock",
                text: $password,
                isSecure: true,
                textContentType: .password,
                submitLabel: .go,
                onSubmit: { if canSubmit { submit() } }
            )
            fieldError("password")
                .padding(.top, 5)
            Spacer().frame(height: 10)

            HStack {
                Spacer()
                // Reset sends a code to the phone *on the account*, not to
                // whatever was typed — otherwise anyone could aim a reset at a
                // number they control.
                Button("Mot de passe oublié ?") {
                    Task {
                        auth.errorMessage = nil
                        guard !identifier.trimmingCharacters(in: .whitespaces).isEmpty else {
                            auth.errorMessage = "Entrez votre numéro ou e-mail d'abord."
                            return
                        }
                        if await auth.forgotPassword(identifier: identifierForAuth) {
                            otp = ""
                            newPassword = ""
                            withAnimation { phase = .resetCode }
                        }
                    }
                }
                .font(.moblyBody(12.5, weight: .semibold))
                .foregroundStyle(Color.moblyPrimary)
                .disabled(auth.isBusy)
            }
            .padding(.bottom, 18)
        }
    }

    // MARK: Sign-up fields

    private var signUpFields: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                MoblyTextField(label: "Nom complet", placeholder: "Jeanne Ndongo",
                               systemIcon: "person", text: $fullName,
                               textContentType: .name, autocapitalization: .words)
                fieldError("fullName")
            }
            .padding(.bottom, 16)

            PhoneNumberField(country: $country, number: $phone,
                             errorMessage: auth.fieldErrors["phone"])
                .padding(.bottom, 16)

            VStack(alignment: .leading, spacing: 5) {
                MoblyTextField(label: "Adresse e-mail", placeholder: "jeanne.ndongo@gmail.com",
                               systemIcon: "envelope", text: $email,
                               keyboard: .emailAddress, textContentType: .emailAddress)
                fieldError("email")
                // A near-miss almost always means the same person mistyping —
                // without this they get a second, empty account and their
                // history looks lost.
                if let similar = auth.similarEmailHint, auth.fieldErrors["email"] == nil {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(hex: 0xD9A21B))
                        Text("Un compte existe avec une adresse très proche (\(similar)). Vouliez-vous vous connecter ?")
                            .font(.moblyBody(11))
                            .foregroundStyle(Color(hex: 0x8A6D1F))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0xFDF6E3)))
                }
            }
            .padding(.bottom, 16)

            VStack(alignment: .leading, spacing: 6) {
                MoblyTextField(label: "Mot de passe", placeholder: "••••••••",
                               systemIcon: "lock", text: $password, isSecure: true,
                               textContentType: .newPassword)
                // Live checklist rather than a static hint, so the user sees
                // exactly which rule is still unmet while typing.
                if password.isEmpty {
                    Text("8+ caractères, une majuscule, une minuscule, un chiffre.")
                        .font(.moblyBody(11))
                        .foregroundStyle(Color(hex: 0x9A9DAC))
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(PasswordRules.evaluate(password, personal: [fullName, email, phoneForAuth]),
                                id: \.label) { rule in
                            HStack(spacing: 5) {
                                Image(systemName: rule.met ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(rule.met ? Color(hex: 0x1F8A5B)
                                                              : Color(hex: 0xC4C7D2))
                                Text(rule.label)
                                    .font(.moblyBody(11))
                                    .foregroundStyle(rule.met ? Color(hex: 0x1F8A5B)
                                                              : Color(hex: 0x9A9DAC))
                            }
                        }
                    }
                }
                fieldError("password")
            }
            .padding(.bottom, 16)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.moblyPrimary)
                Text("Un code de vérification sera envoyé pour confirmer votre compte.")
                    .font(.moblyBody(11.5))
                    .foregroundStyle(Color.moblyPrimary)
                    .lineSpacing(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.moblySurfaceTint))
            .padding(.bottom, 20)
        }
    }

    // MARK: Code phase (signup only)

    private var codeView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { withAnimation { phase = .form } }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 13).fill(Color(hex: 0xF4F5F8)))
            }
            .padding(.bottom, 22)

            Text("Entrez le code")
                .font(.moblyHeading(24))
                .foregroundStyle(Color.moblyTextPrimary)
                .padding(.bottom, 6)
            Text("Code à \(auth.codeLength) chiffres envoyé \(codeDestination).")
                .font(.moblyBody(13.5))
                .foregroundStyle(Color(hex: 0x9A9DAC))
                .padding(.bottom, 26)

            SignupOTPStep(
                otp: $otp,
                destination: codeDestination,
                devCode: auth.devCode,
                isBusy: auth.isBusy,
                error: auth.errorMessage,
                resendCooldown: auth.resendCooldown,
                length: auth.codeLength,
                onVerify: { code in Task { await verifyCode(code) } },
                onResend: {
                    Task {
                        if mode == .signup {
                            _ = await auth.startSignup(fullName: fullName, phone: phoneForAuth,
                                                       email: email, password: password)
                        } else {
                            _ = await auth.requestCode(phone: phoneForAuth)
                        }
                    }
                }
            )

            Spacer()
        }
        .padding(.horizontal, 26)
        .padding(.top, 56)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Shown only while a real request is in flight — it no longer waits on a
    /// timer, so the duration reflects the actual round trip.
    // MARK: Reset — step 1, confirm the code

    private var resetCodeView: some View {
        VStack(alignment: .leading, spacing: 0) {
            backButton { withAnimation { phase = .form } }

            Text("Réinitialiser le mot de passe")
                .font(.moblyHeading(24))
                .foregroundStyle(Color.moblyTextPrimary)
                .padding(.bottom, 6)
            Text("Code à \(auth.codeLength) chiffres envoyé au \(auth.resetPhone ?? "votre numéro").")
                .font(.moblyBody(13.5))
                .foregroundStyle(Color(hex: 0x9A9DAC))
                .padding(.bottom, 26)

            SignupOTPStep(
                otp: $otp,
                destination: auth.resetPhone.map { "au \($0)" } ?? "",
                devCode: auth.devCode,
                isBusy: auth.isBusy,
                error: auth.errorMessage,
                resendCooldown: auth.resendCooldown,
                length: auth.codeLength,
                onVerify: { code in
                    // The code is only spent once the new password is entered,
                    // so this just advances — a code consumed here would be
                    // wasted if the password step failed validation.
                    guard code.count == auth.codeLength else { return }
                    auth.errorMessage = nil
                    withAnimation { phase = .resetPassword }
                },
                onResend: {
                    Task { _ = await auth.forgotPassword(identifier: identifierForAuth) }
                }
            )
            Spacer()
        }
        .padding(.horizontal, 26)
        .padding(.top, 56)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Reset — step 2, choose the new password

    private var resetPasswordView: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                backButton { withAnimation { phase = .resetCode } }

                Text("Nouveau mot de passe")
                    .font(.moblyHeading(24))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .padding(.bottom, 6)
                Text("Choisissez un mot de passe pour \(auth.resetPhone ?? "votre compte").")
                    .font(.moblyBody(13.5))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                    .padding(.bottom, 24)

                MoblyTextField(label: "Mot de passe", placeholder: "••••••••",
                               systemIcon: "lock", text: $newPassword, isSecure: true,
                               textContentType: .newPassword)

                VStack(alignment: .leading, spacing: 3) {
                    ForEach(PasswordRules.evaluate(newPassword,
                                                   personal: [auth.resetPhone ?? ""]),
                            id: \.label) { rule in
                        HStack(spacing: 5) {
                            Image(systemName: rule.met ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 10.5))
                                .foregroundStyle(rule.met ? Color(hex: 0x1F8A5B)
                                                          : Color(hex: 0xC4C7D2))
                            Text(rule.label)
                                .font(.moblyBody(11))
                                .foregroundStyle(rule.met ? Color(hex: 0x1F8A5B)
                                                          : Color(hex: 0x9A9DAC))
                        }
                    }
                }
                .padding(.top, 8)

                fieldError("password").padding(.top, 8)

                if let error = auth.errorMessage {
                    Text(LT(error))
                        .font(.moblyBody(12.5, weight: .medium))
                        .foregroundStyle(Color.moblyAccent)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                }

                PillButton(title: auth.isBusy ? "Enregistrement…" : "Enregistrer",
                           style: .primaryBlue, trailingIcon: nil) {
                    Task {
                        if await auth.resetPassword(code: otp, newPassword: newPassword) {
                            withAnimation { phase = .welcome }
                        } else if auth.lastErrorCode == .otpInvalid
                                    || auth.lastErrorCode == .otpExpired
                                    || auth.lastErrorCode == .otpLocked {
                            // The code, not the password, was the problem —
                            // send them back to re-enter it.
                            otp = ""
                            withAnimation { phase = .resetCode }
                        }
                    }
                }
                .opacity(canResetPassword && !auth.isBusy ? 1 : 0.5)
                .disabled(!canResetPassword || auth.isBusy)
                .padding(.top, 20)

                Spacer()
            }
            .padding(.horizontal, 26)
            .padding(.top, 56)
        }
    }

    private var canResetPassword: Bool {
        PasswordRules.allMet(newPassword, personal: [auth.resetPhone ?? ""])
    }

    private func backButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.moblyTextPrimary)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 13).fill(Color(hex: 0xF4F5F8)))
        }
        .padding(.bottom, 22)
    }

    private var loadingView: some View {
        AuthSpinnerView(
            title: mode == .signin ? "Connexion en cours…" : "Vérification en cours…",
            subtitle: mode == .signin
                ? "Un instant pendant que nous vérifions vos identifiants."
                : "Nous confirmons votre numéro de téléphone."
        )
    }

    private var welcomeView: some View {
        AuthWelcomeBackView(
            firstName: firstName,
            title: firstName.isEmpty
                ? (mode == .signin ? "Bon retour" : "Bienvenue")
                : (mode == .signin ? "Bon retour, \(firstName)" : "Bienvenue, \(firstName)"),
            subtitle: mode == .signin
                ? "Vos recherches et préférés vous attendent."
                : "Votre compte Mobly est prêt.",
            // Session is already applied from the server's user object by
            // AuthStore — nothing to persist here.
            onDone: { onFinish() }
        )
    }

    // MARK: Logic

    private var canSubmit: Bool {
        switch mode {
        case .signin:
            // Require a plausibly complete identifier of whichever kind was
            // detected, so the button doesn't enable on "j" or a single digit.
            let identifierOK: Bool
            switch IdentifierDetector.detect(identifier) {
            case .email:   identifierOK = IdentifierDetector.isValidEmail(identifier)
            case .phone:   identifierOK = identifier.filter(\.isNumber).count >= 8
            case .unknown: identifierOK = false
            }
            return identifierOK && password.count >= 6
        case .signup:
            // Local rules first — no round trip on a form we already know is
            // invalid — then availability. The button stays grey while the
            // live e-mail/phone check is in flight OR the server has flagged
            // one of them as already taken, so the user can't submit a form
            // that's guaranteed to fail server-side.
            let localOK =
                fullName.trimmingCharacters(in: .whitespaces).count >= 2
                && AuthStore.isValidPhone(phoneForAuth)
                && email.contains("@") && email.contains(".")
                && PasswordRules.allMet(password, personal: [fullName, email, phoneForAuth])
            let alreadyTaken =
                auth.fieldErrors["phone"] == "Ce numéro est déjà utilisé"
                || auth.fieldErrors["email"] == "Cet e-mail est déjà utilisé"
            return localOK && !alreadyTaken && !auth.isCheckingAvailability
        }
    }

    private var firstName: String {
        // Prefer the name the server returned; fall back to what was typed.
        if let name = auth.user?.fullName.split(separator: " ").first { return String(name) }
        if mode == .signup, let f = fullName.split(separator: " ").first { return String(f) }
        if identifier.contains("@") {
            return identifier.split(separator: "@").first.map { String($0).capitalized } ?? ""
        }
        // No invented name — the welcome copy drops the name when we don't
        // have one rather than greeting everyone as "Jeanne".
        return ""
    }

    /// Inline message for one field, from the server's `fields` map.
    @ViewBuilder
    private func fieldError(_ key: String) -> some View {
        if let msg = auth.fieldErrors[key] {
            Text(LT(msg))
                .font(.moblyBody(11, weight: .medium))
                .foregroundStyle(Color.moblyAccent)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
        }
    }

    /// Changes whenever a checked field changes, restarting the debounce.
    private var availabilityKey: String { "\(country.dial)\(phone)|\(email)" }

    private var submitTitle: String {
        if auth.isBusy { return mode == .signin ? "Connexion…" : "Envoi du code…" }
        return mode == .signin ? "Connexion" : "Créer mon compte"
    }

    /// Number the OTP is tied to: signup has a dedicated field, sign-in reuses
    /// the shared identifier.
    /// Full E.164 for the number being verified. Signup composes it from the
    /// selected country plus the local digits; sign-in takes whatever was typed
    /// into the shared identifier field.
    private var phoneForAuth: String {
        mode == .signup
            ? country.dialCode + phone.filter(\.isNumber)
            : IdentifierField.apiValue(text: identifier, country: country)
    }

    /// What sign-in sends: E.164 when the field looks like a number, a trimmed
    /// lowercase address when it looks like an e-mail.
    private var identifierForAuth: String {
        IdentifierField.apiValue(text: identifier, country: country)
    }

    /// Where the code went, as a complete phrase including its preposition —
    /// "au +237677889900" vs "à votre numéro". Keeping the preposition here is
    /// what stops the fallback reading as "au votre numéro".
    private var codeDestination: String {
        guard phone.contains(where: \.isNumber) || identifier.contains(where: \.isNumber)
        else { return "à votre numéro" }
        return "au " + AuthStore.normalizePhone(phoneForAuth)
    }

    private func switchTo(_ newMode: AuthMode) {
        guard newMode != mode else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        // An error from the other mode would otherwise stay pinned to a form
        // it no longer applies to.
        auth.errorMessage = nil
        withAnimation(.easeInOut(duration: 0.28)) { mode = newMode }
    }

    // MARK: Real auth calls

    private func submit() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        auth.errorMessage = nil
        otp = ""
        switch mode {
        case .signup: Task { await startSignup() }
        case .signin: Task { await startSignin() }
        }
    }

    /// Signup is phone-first: prove the number with an OTP, then create the
    /// account. Only move to the code screen once the server confirms it sent
    /// one — otherwise the user waits for an SMS that was never dispatched.
    private func startSignup() async {
        // Server-side validation of every field happens here, before any SMS is
        // sent — so a duplicate e-mail or weak password never costs a message.
        if await auth.startSignup(fullName: fullName, phone: phoneForAuth,
                                  email: email, password: password) {
            withAnimation { phase = .code }
        }
    }

    /// Sign-in tries the password first. Accounts created by OTP have no
    /// password until one is set, so a failure falls back to sending a code
    /// rather than dead-ending the user.
    private func startSignin() async {
        withAnimation { phase = .loading }
        if await auth.signIn(identifier: identifierForAuth, password: password) {
            withAnimation { phase = .welcome }
            return
        }
        // Branch on the code, not the message — the wording is free to change.
        // Only fall through to SMS when the account exists but has no password;
        // a wrong password or an unknown account both need the user to act, and
        // silently texting a code would hide which of the two happened.
        // An account with no password (created by OTP or a social provider)
        // can't sign in this way at all — send them through reset so they end
        // up with a password rather than a one-off session.
        if auth.lastErrorCode == .noPasswordSet {
            auth.errorMessage = nil
            if await auth.forgotPassword(identifier: identifierForAuth) {
                otp = ""
                newPassword = ""
                withAnimation { phase = .resetCode }
                return
            }
        }
        withAnimation { phase = .form }
    }

    private func verifyCode(_ code: String) async {
        guard code.count == auth.codeLength, !auth.isBusy else { return }
        let ok: Bool
        if mode == .signup {
            // Creates the account with the password already validated at /start.
            ok = await auth.verifySignup(fullName: fullName, phone: phoneForAuth,
                                         email: email, password: password, code: code)
        } else {
            ok = await auth.verifyCode(phone: phoneForAuth, code: code)
        }
        guard ok else { return }   // stay on the code screen; error shows inline
        withAnimation { phase = .welcome }
    }
}

// MARK: - Shared auth components

struct AuthModeToggle: View {
    var isSignIn: Bool
    var onSignIn: () -> Void
    var onSignUp: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            tab(title: "Connexion", active: isSignIn, action: onSignIn)
            tab(title: "Inscription", active: !isSignIn, action: onSignUp)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0xF4F5F8)))
    }

    private func tab(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(LT(title))
                .font(.moblyBody(13, weight: .bold))
                .foregroundStyle(active ? Color.moblyPrimary : Color(hex: 0x9A9DAC))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 11)
                        .fill(active ? .white : .clear)
                        .shadow(color: active ? Color(hex: 0x14152A).opacity(0.08) : .clear,
                                radius: 6, y: 2)
                )
        }
    }
}

struct AuthDivider: View {
    var text: String
    var body: some View {
        HStack(spacing: 12) {
            Rectangle().fill(Color(hex: 0xF1F2F6)).frame(height: 1)
            Text(LT(text))
                .font(.moblyBody(11.5, weight: .medium))
                .foregroundStyle(Color(hex: 0xC4C7D2))
            Rectangle().fill(Color(hex: 0xF1F2F6)).frame(height: 1)
        }
    }
}

struct AuthSocialWide: View {
    enum Kind { case google, apple }
    var kind: Kind

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            HStack(spacing: 9) {
                if kind == .google {
                    Text("G").font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color(hex: 0x4285F4))
                } else {
                    Image(systemName: "applelogo")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                }
                Text(kind == .google ? "Continuer avec Google" : "Continuer avec Apple")
                    .font(.moblyBody(14, weight: .semibold))
                    .foregroundStyle(kind == .google ? Color.moblyTextPrimary : .white)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(Capsule().fill(kind == .apple ? Color(hex: 0x14152A) : .white))
            .overlay(Capsule().stroke(kind == .google ? Color(hex: 0xE2E4EC) : .clear, lineWidth: 1.5))
        }
    }
}

struct AuthSpinnerView: View {
    var title: String
    var subtitle: String
    @State private var spin = false

    var body: some View {
        VStack(spacing: 0) {
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(Color.moblyPrimary, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .frame(width: 78, height: 78)
                .background(Circle().stroke(Color.moblySurfaceTint, lineWidth: 5))
                .rotationEffect(.degrees(spin ? 360 : 0))
                .padding(.bottom, 26)

            Text(LT(title))
                .font(.moblyHeading(18))
                .foregroundStyle(Color.moblyTextPrimary)
                .padding(.bottom, 8)

            Text(LT(subtitle))
                .font(.moblyBody(13))
                .foregroundStyle(Color(hex: 0x9A9DAC))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .onAppear {
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true }
        }
    }
}

/// Splash-style welcome screen shown after auth completes. No button —
/// it plays a 5-second entrance + progress-ring animation, then auto-redirects
/// to Home via onDone().
struct AuthWelcomeBackView: View {
    var firstName: String
    var title: String
    var subtitle: String
    var onDone: () -> Void

    private let duration: Double = 5.0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appear = false
    @State private var avatarPop = false
    @State private var glowPulse = false
    @State private var ringProgress: CGFloat = 0

    var body: some View {
        ZStack {
            // Brand splash background
            Color.moblyPrimary.ignoresSafeArea()

            // Soft orange glow behind the avatar, like the splash screen
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.moblyAccent.opacity(0.22), Color.moblyAccent.opacity(0)],
                        center: .center, startRadius: 0, endRadius: 220
                    )
                )
                .frame(width: 440, height: 440)
                .scaleEffect(glowPulse ? 1.06 : 0.9)
                .opacity(glowPulse ? 1 : 0.6)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                // Avatar with a progress ring that fills over `duration`
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.18), lineWidth: 4)
                        .frame(width: 116, height: 116)

                    Circle()
                        .trim(from: 0, to: ringProgress)
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: 116, height: 116)
                        .rotationEffect(.degrees(-90))

                    Circle().fill(.white).frame(width: 92, height: 92)
                    Text(String(firstName.prefix(1)))
                        .font(.moblyHeading(38))
                        .foregroundStyle(Color.moblyPrimary)
                }
                .scaleEffect(avatarPop ? 1 : 0.7)
                .padding(.bottom, 26)

                Text(LT(title))
                    .font(.moblyHeading(27))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 10)

                Text(LT(subtitle))
                    .font(.moblyBody(14))
                    .foregroundStyle(Color.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 280)
            }
            .opacity(appear ? 1 : 0)
            .offset(y: appear ? 0 : 10)
        }
        .onAppear(perform: run)
    }

    private func run() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        if reduceMotion {
            appear = true; avatarPop = true; ringProgress = 1
        } else {
            withAnimation(.easeOut(duration: 0.6)) { appear = true }
            withAnimation(.spring(response: 0.6, dampingFraction: 0.6)) { avatarPop = true }
            withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
                glowPulse = true
            }
            withAnimation(.linear(duration: duration)) { ringProgress = 1 }
        }

        // Auto-redirect to Home after the animation completes.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            onDone()
        }
    }
}

#Preview("Sign in") { ConnexionView(initialMode: .signin) }
#Preview("Sign up") { ConnexionView(initialMode: .signup) }
