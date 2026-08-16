import SwiftUI

// MARK: - Step 1: Credentials

struct SignupCredentialsStep: View {
    @Binding var fullName: String
    @Binding var email: String
    @Binding var password: String
    var onContinue: () -> Void

    private var canContinue: Bool {
        !fullName.trimmingCharacters(in: .whitespaces).isEmpty &&
        email.contains("@") &&
        password.count >= 8
    }

    var body: some View {
        VStack(spacing: 15) {
            MoblyTextField(
                label: "Nom complet",
                placeholder: "Jeanne Ndongo",
                systemIcon: "person",
                text: $fullName,
                textContentType: .name,
                autocapitalization: .words
            )

            MoblyTextField(
                label: "Adresse e-mail",
                placeholder: "jeanne.ndongo@gmail.com",
                systemIcon: "envelope",
                text: $email,
                keyboard: .emailAddress,
                textContentType: .emailAddress
            )

            VStack(alignment: .leading, spacing: 6) {
                MoblyTextField(
                    label: "Mot de passe",
                    placeholder: "••••••••",
                    systemIcon: "lock",
                    text: $password,
                    isSecure: true,
                    textContentType: .newPassword,
                    submitLabel: .done,
                    onSubmit: { if canContinue { onContinue() } }
                )
                Text("Au moins 8 caractères, avec une lettre et un chiffre.")
                    .font(.moblyBody(11))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
            }

            PillButton(title: "Continuer", style: .primaryBlue,
                       trailingIcon: nil, action: onContinue)
                .opacity(canContinue ? 1 : 0.5)
                .disabled(!canContinue)
                .padding(.top, 4)

            dividerRow

            HStack(spacing: 11) {
                SocialButton(kind: .google)
                SocialButton(kind: .apple)
            }
        }
    }

    private var dividerRow: some View {
        HStack(spacing: 12) {
            Rectangle().fill(Color(hex: 0xF1F2F6)).frame(height: 1)
            Text("ou s'inscrire avec")
                .font(.moblyBody(11.5, weight: .medium))
                .foregroundStyle(Color(hex: 0xC4C7D2))
                .fixedSize()
            Rectangle().fill(Color(hex: 0xF1F2F6)).frame(height: 1)
        }
        .padding(.vertical, 4)
    }
}

private struct SocialButton: View {
    enum Kind { case google, apple }
    var kind: Kind

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            HStack(spacing: 8) {
                Group {
                    switch kind {
                    case .google:
                        Text("G")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Color(hex: 0x4285F4))
                    case .apple:
                        Image(systemName: "applelogo")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                    }
                }
                Text(kind == .google ? "Google" : "Apple")
                    .font(.moblyBody(13.5, weight: .semibold))
                    .foregroundStyle(kind == .google ? Color.moblyTextPrimary : .white)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                Capsule().fill(kind == .apple ? Color(hex: 0x14152A) : .white)
            )
            .overlay(
                Capsule().stroke(kind == .google ? Color(hex: 0xE2E4EC) : .clear, lineWidth: 1.5)
            )
        }
    }
}

// MARK: - Step 2: Phone

struct SignupPhoneStep: View {
    @Binding var phone: String
    var onContinue: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 15) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Numéro de téléphone")
                    .font(.moblyBody(12.5, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x6B6F80))

                HStack(spacing: 10) {
                    Text("🇨🇲 +237")
                        .font(.moblyBody(15, weight: .semibold))
                        .foregroundStyle(Color.moblyTextPrimary)
                    Rectangle().fill(Color(hex: 0xE2E4EC)).frame(width: 1, height: 20)
                    TextField("6 77 12 34 56", text: $phone)
                        .font(.moblyBody(15, weight: .medium))
                        .foregroundStyle(Color.moblyTextPrimary)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .focused($focused)
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(hex: 0xF4F5F8))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(focused ? Color.moblyPrimary : .clear, lineWidth: 1.6)
                )
                .animation(.easeOut(duration: 0.18), value: focused)
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.moblyPrimary)
                Text("Nous enverrons un code de vérification à ce numéro par SMS.")
                    .font(.moblyBody(11.5))
                    .foregroundStyle(Color.moblyPrimary)
                    .lineSpacing(2)
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.moblySurfaceTint))

            PillButton(title: "Envoyer le code", style: .primaryBlue,
                       trailingIcon: nil, action: onContinue)
                .opacity(phone.count >= 6 ? 1 : 0.5)
                .disabled(phone.count < 6)
                .padding(.top, 4)
        }
    }
}

// MARK: - Step 3: OTP

/// Six-digit code entry, verified by the server.
///
/// The code is never checked on the device — the previous version compared it
/// against a local string and printed it on screen, which meant anyone could
/// read it and the "verification" proved nothing. `onVerify` hands the entered
/// digits to the caller, which calls the API and reports back through `error`.
struct SignupOTPStep: View {
    @Binding var otp: String
    /// Where the code went, as a complete phrase including its preposition
    /// (e.g. "au +237677889900"), so the caller controls the grammar.
    var destination: String = ""
    /// Dev-mode only: the server echoes the code back so the simulator can
    /// prefill. Always nil once OTP_DEV_MODE is off.
    var devCode: String? = nil
    var isBusy: Bool = false
    /// Server-supplied error text; nil clears the error state.
    var error: String? = nil
    /// Seconds until a resend is allowed — the server owns this value.
    var resendCooldown: Int = 0
    /// Digits the server is issuing. Driven by the response so the two can't
    /// drift — a hardcoded value is how this ended up asking for 6 while the
    /// backend sent 4.
    var length: Int = 4
    var onVerify: (String) -> Void
    var onResend: () -> Void = {}

    @FocusState private var focused: Bool

    private var isComplete: Bool { otp.count == length }

    var body: some View {
        VStack(spacing: 18) {
            if let devCode {
                // Dev builds only — the server stops sending this in production.
                HStack(spacing: 8) {
                    Image(systemName: "hammer.fill")
                        .foregroundStyle(Color(hex: 0x1F8A5B))
                    Text("Mode dev · code : \(devCode)")
                        .font(.moblyBody(12, weight: .medium))
                        .foregroundStyle(Color(hex: 0x1F8A5B))
                    Spacer()
                    Button("Utiliser") { otp = devCode }
                        .font(.moblyBody(12, weight: .bold))
                        .foregroundStyle(Color(hex: 0x1F8A5B))
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0xE9F9EF)))
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if !destination.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color(hex: 0x1F8A5B))
                    Text("Code envoyé par SMS \(destination)")
                        .font(.moblyBody(12, weight: .medium))
                        .foregroundStyle(Color(hex: 0x1F8A5B))
                    Spacer()
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0xE9F9EF)))
            }

            ZStack {
                TextField("", text: $otp)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)   // enables SMS autofill
                    .focused($focused)
                    .opacity(0.02)
                    .onChange(of: otp) { _, newValue in
                        otp = String(newValue.filter(\.isNumber).prefix(length))
                        if otp.count == length {
                            focused = false
                            // Autosubmit once the last digit lands — with SMS
                            // autofill the user would otherwise still have to
                            // reach for the button.
                            onVerify(otp)
                        }
                    }

                HStack(spacing: 7) {
                    ForEach(0..<length, id: \.self) { i in
                        OTPCell(digit: digit(at: i), active: i == otp.count, error: error != nil)
                    }
                }
                .onTapGesture { focused = true }
            }

            HStack(spacing: 5) {
                Text("Vous n'avez pas reçu de code ?")
                    .font(.moblyBody(13))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                if resendCooldown > 0 {
                    Text("Renvoyer (\(resendCooldown)s)")
                        .font(.moblyBody(13, weight: .bold))
                        .foregroundStyle(Color(hex: 0xC4C7D2))
                } else {
                    Button("Renvoyer") {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        otp = ""
                        onResend()
                    }
                    .font(.moblyBody(13, weight: .bold))
                    .foregroundStyle(Color.moblyPrimary)
                }
            }

            if let error {
                Text(LT(error))
                    .font(.moblyBody(12, weight: .medium))
                    .foregroundStyle(Color.moblyAccent)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }

            PillButton(title: isBusy ? "Vérification…" : "Vérifier",
                       style: .primaryBlue, trailingIcon: nil,
                       action: { onVerify(otp) })
                .opacity(isComplete && !isBusy ? 1 : 0.5)
                .disabled(!isComplete || isBusy)
        }
        .onAppear { focused = true }
        .onChange(of: error) { _, newValue in
            // A rejected code should clear the field so the user isn't editing
            // digits the server already refused.
            if newValue != nil { otp = "" }
        }
    }

    private func digit(at index: Int) -> String {
        guard index < otp.count else { return "" }
        let i = otp.index(otp.startIndex, offsetBy: index)
        return String(otp[i])
    }
}

private struct OTPCell: View {
    var digit: String
    var active: Bool
    var error: Bool = false

    private var strokeColor: Color {
        if error { return .moblyAccent }
        return (active || !digit.isEmpty) ? .moblyPrimary : .clear
    }

    var body: some View {
        Text(digit)
            .font(.moblyHeading(26))
            .foregroundStyle(Color.moblyTextPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(hex: 0xF4F5F8)))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(strokeColor, lineWidth: 2)
            )
            .animation(.easeOut(duration: 0.15), value: active)
            .animation(.easeOut(duration: 0.15), value: error)
    }
}

// MARK: - Step 4: Verifying

struct SignupVerifyingStep: View {
    var onDone: () -> Void
    @State private var spin = false

    var body: some View {
        VStack(spacing: 0) {
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(Color.moblyPrimary, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .frame(width: 78, height: 78)
                .background(
                    Circle().stroke(Color.moblySurfaceTint, lineWidth: 5)
                )
                .rotationEffect(.degrees(spin ? 360 : 0))
                .padding(.bottom, 26)

            Text("Vérification en cours…")
                .font(.moblyHeading(18))
                .foregroundStyle(Color.moblyTextPrimary)
                .padding(.bottom, 8)

            Text("Nous confirmons votre numéro de téléphone.")
                .font(.moblyBody(13))
                .foregroundStyle(Color(hex: 0x9A9DAC))
        }
        .padding(.top, 130)
        .onAppear {
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                spin = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { onDone() }
        }
    }
}

// MARK: - Step 5: Success

struct SignupSuccessStep: View {
    var onDone: () -> Void
    @State private var pop = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(Color(hex: 0xE9F9EF)).frame(width: 84, height: 84)
                Image(systemName: "checkmark")
                    .font(.system(size: 38, weight: .heavy))
                    .foregroundStyle(Color(hex: 0x1F8A5B))
            }
            .scaleEffect(pop ? 1 : 0.5)
            .padding(.bottom, 22)

            Text("Numéro vérifié !")
                .font(.moblyHeading(21))
                .foregroundStyle(Color.moblyTextPrimary)
                .padding(.bottom, 8)

            Text("Votre compte Mobly est prêt.")
                .font(.moblyBody(13.5))
                .foregroundStyle(Color(hex: 0x9A9DAC))
        }
        .padding(.top, 120)
        .onAppear {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { pop = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { onDone() }
        }
    }
}

// MARK: - Step 6: Welcome

struct SignupWelcomeStep: View {
    var firstName: String
    var onFinish: () -> Void
    @State private var appear = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(Color.moblySurfaceTint).frame(width: 96, height: 96)
                Text(String(firstName.prefix(1)))
                    .font(.moblyHeading(38))
                    .foregroundStyle(Color.moblyPrimary)
            }
            .scaleEffect(appear ? 1 : 0.7)
            .padding(.bottom, 22)

            Text("Bienvenue, \(firstName) 👋")
                .font(.moblyHeading(26))
                .foregroundStyle(Color.moblyTextPrimary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)

            Text("Trouvez votre espace idéal à Douala — chambres, bureaux, boutiques et plus, près de vous.")
                .font(.moblyBody(14))
                .foregroundStyle(Color(hex: 0x9A9DAC))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 280)
                .padding(.bottom, 34)

            PillButton(title: "Commencer", style: .primaryBlue, action: onFinish)
        }
        .padding(.top, 80)
        .opacity(appear ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.75)) { appear = true }
        }
    }
}
