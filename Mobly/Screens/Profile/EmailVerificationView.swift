import SwiftUI

/// Profil → Adresse e-mail. Confirm the current address, or switch to a new
/// one, with a 6-digit code mailed through the server (InsForge mail).
///
/// The account keeps its old address until the code for the new one checks
/// out, so a typo here can never lock the user out of password reset.
struct EmailVerificationView: View {
    @ObservedObject private var auth = AuthStore.shared

    private enum Step { case address, code, done }
    @State private var step: Step = .address
    @State private var email = ""
    @State private var otp = ""
    @State private var autoSent = false

    /// Set when Modifier le profil hands over the address typed there: the
    /// field starts on it and the code goes out without a second tap.
    private let pendingEmail: String?

    init(pendingEmail: String? = nil) {
        self.pendingEmail = pendingEmail
    }

    private var currentEmail: String { auth.user?.email ?? "" }
    private var trimmed: String { email.trimmingCharacters(in: .whitespaces).lowercased() }
    private var isChange: Bool { !trimmed.isEmpty && trimmed != currentEmail.lowercased() }
    private var canSend: Bool {
        IdentifierDetector.isValidEmail(trimmed) && (isChange || !auth.isEmailVerified)
    }

    var body: some View {
        ProfileScaffold(title: "Adresse e-mail") {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    switch step {
                    case .address: addressStep
                    case .code:    codeStep
                    case .done:    doneStep
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            if email.isEmpty { email = pendingEmail ?? currentEmail }
            auth.errorMessage = nil
            // Once only — onAppear fires again when coming back to this screen.
            if pendingEmail != nil, !autoSent {
                autoSent = true
                send()
            }
        }
    }

    // MARK: Steps

    private var addressStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusCard.padding(.bottom, 22)

            MoblyTextField(label: "E-mail", placeholder: "vous@exemple.com",
                           systemIcon: "envelope", text: $email,
                           keyboard: .emailAddress, textContentType: .emailAddress,
                           submitLabel: .send, onSubmit: send)

            if let error = auth.fieldErrors["email"] ?? auth.errorMessage {
                Text(LT(error))
                    .font(.moblyBody(12.5, weight: .medium))
                    .foregroundStyle(Color.moblyAccent)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }

            PillButton(title: auth.isBusy ? "Envoi…" : "Recevoir un code",
                       style: .primaryBlue, trailingIcon: nil, action: send)
                .opacity(canSend && !auth.isBusy ? 1 : 0.5)
                .disabled(!canSend || auth.isBusy)
                .padding(.top, 20)

            Text("Une adresse confirmée vous permet de réinitialiser votre mot de passe par e-mail si vous n’avez plus accès à votre numéro.")
                .font(.moblyBody(12))
                .foregroundStyle(Color(hex: 0x9A9DAC))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
        }
    }

    private var codeStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Entrez le code")
                .font(.moblyHeading(22))
                .foregroundStyle(Color.moblyTextPrimary)
                .padding(.bottom, 6)
            Text("Code à \(auth.emailCodeLength) chiffres envoyé à \(auth.emailCodeDestination ?? trimmed). Pensez à vérifier vos spams.")
                .font(.moblyBody(13.5))
                .foregroundStyle(Color(hex: 0x9A9DAC))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 24)

            SignupOTPStep(
                otp: $otp,
                destination: auth.emailCodeDestination.map { "à \($0)" } ?? "",
                devCode: auth.devCode,
                isBusy: auth.isBusy,
                error: auth.errorMessage,
                resendCooldown: auth.resendCooldown,
                length: auth.emailCodeLength,
                onVerify: { code in
                    guard code.count == auth.emailCodeLength, !auth.isBusy else { return }
                    Task {
                        if await auth.verifyEmailCode(code) {
                            withAnimation(Motion.standard) { step = .done }
                        }
                    }
                },
                onResend: { Task { _ = await auth.sendEmailCode(email: isChange ? trimmed : nil) } }
            )

            Button {
                otp = ""
                auth.errorMessage = nil
                withAnimation(Motion.standard) { step = .address }
            } label: {
                Text("Modifier l’adresse")
                    .font(.moblyBody(13.5, weight: .semibold))
                    .foregroundStyle(Color.moblyPrimary)
            }
            .buttonStyle(.plain)
            .padding(.top, 18)
        }
    }

    private var doneStep: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(Color(hex: 0x1F8A5B))
                .padding(.top, 30)
            Text("E-mail confirmé")
                .font(.moblyHeading(20))
                .foregroundStyle(Color.moblyTextPrimary)
            Text(currentEmail)
                .font(.moblyBody(14))
                .foregroundStyle(Color(hex: 0x6B6E80))
        }
        .frame(maxWidth: .infinity)
    }

    private var statusCard: some View {
        let verified = auth.isEmailVerified
        return HStack(spacing: 12) {
            Image(systemName: verified ? "checkmark.seal.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color(hex: verified ? 0x1F8A5B : 0xE5950C))
            VStack(alignment: .leading, spacing: 2) {
                Text(verified ? "Adresse confirmée" : "Adresse non confirmée")
                    .font(.moblyBody(14, weight: .semibold))
                    .foregroundStyle(Color.moblyTextPrimary)
                Text(currentEmail.isEmpty ? "Aucune adresse enregistrée" : currentEmail)
                    .font(.moblyBody(12.5))
                    .foregroundStyle(Color(hex: 0x6B6E80))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16)
            .fill(Color(hex: verified ? 0xE9F9EF : 0xFFF4E5)))
    }

    private func send() {
        guard canSend, !auth.isBusy else { return }
        Task {
            if await auth.sendEmailCode(email: isChange ? trimmed : nil) {
                otp = ""
                withAnimation(Motion.standard) {
                    step = auth.isEmailVerified && !isChange ? .done : .code
                }
            }
        }
    }
}
