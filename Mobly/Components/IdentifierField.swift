import SwiftUI

/// Sign-in identifier that adapts to what's being typed: an e-mail field when
/// it sees letters, a phone field (with country selector and digit grouping)
/// when it sees digits.
///
/// The keyboard stays on `.emailAddress` throughout rather than swapping to
/// `.phonePad` mid-entry — a keyboard that changes under the user's thumb
/// drops focus and loses characters, and the e-mail keyboard already carries
/// digits.
struct IdentifierField: View {
    var label: String = "Numéro ou e-mail"
    /// Raw text the user sees.
    @Binding var text: String
    /// Country used when the input is a phone number.
    @Binding var country: Country
    var errorMessage: String?
    var onSubmit: () -> Void = {}

    @State private var showPicker = false
    @FocusState private var focused: Bool

    var kind: IdentifierKind { IdentifierDetector.detect(text) }

    /// The value to send to the API: E.164 for a phone, trimmed and lowercased
    /// for an e-mail.
    static func apiValue(text: String, country: Country) -> String {
        switch IdentifierDetector.detect(text) {
        case .phone:
            return country.dialCode + text.filter(\.isNumber)
        case .email, .unknown:
            return text.trimmingCharacters(in: .whitespaces).lowercased()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !label.isEmpty {
                Text(label)
                    .font(.moblyBody(12.5, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x6B6F80))
            }

            HStack(spacing: 10) {
                if kind == .phone {
                    Button { showPicker = true } label: {
                        HStack(spacing: 5) {
                            Text(country.flag).font(.system(size: 18))
                            Text(country.dialCode)
                                .font(.moblyBody(14.5, weight: .semibold))
                                .foregroundStyle(Color.moblyTextPrimary)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color(hex: 0x9A9DAC))
                        }
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                    Rectangle().fill(Color(hex: 0xE2E4EC)).frame(width: 1, height: 18)
                } else {
                    Image(systemName: kind == .email ? "envelope" : "person.text.rectangle")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color(hex: 0x9A9DAC))
                        .transition(.opacity)
                }

                TextField("+237 6 77 12 34 56 ou e-mail", text: $text)
                    .font(.moblyBody(14, weight: .medium))
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                    .focused($focused)
                    .submitLabel(.go)
                    .onSubmit(onSubmit)
                    .onChange(of: text) { _, newValue in
                        text = normalise(newValue)
                    }

                if trailingIcon != nil {
                    Image(systemName: trailingIcon!)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isComplete ? Color(hex: 0x1F8A5B) : Color(hex: 0xC4C7D2))
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0xF4F5F8)))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(errorMessage == nil ? .clear : Color.moblyAccent, lineWidth: 1)
            )
            .animation(.easeInOut(duration: 0.18), value: kind)

            if let errorMessage {
                Text(errorMessage)
                    .font(.moblyBody(11, weight: .medium))
                    .foregroundStyle(Color.moblyAccent)
                    .fixedSize(horizontal: false, vertical: true)
            } else if kind == .phone {
                Text("Numéro détecté · \(country.name)")
                    .font(.moblyBody(11))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                    .transition(.opacity)
            }
        }
        .sheet(isPresented: $showPicker) {
            CountryPickerSheet(selected: $country)
        }
    }

    private var trailingIcon: String? {
        switch kind {
        case .unknown: return nil
        case .email:   return isComplete ? "checkmark.circle.fill" : nil
        case .phone:   return isComplete ? "checkmark.circle.fill" : nil
        }
    }

    private var isComplete: Bool {
        switch kind {
        case .unknown: return false
        case .email:   return IdentifierDetector.isValidEmail(text)
        case .phone:   return text.filter(\.isNumber).count >= 8
        }
    }

    /// Reformat as the user types: phone numbers get grouped, e-mails are left
    /// alone (spaces stripped, since they're never valid and are easy to paste).
    private func normalise(_ input: String) -> String {
        switch IdentifierDetector.detect(input) {
        case .email:
            return input.replacingOccurrences(of: " ", with: "")
        case .phone:
            var digits = input.filter(\.isNumber)
            // A pasted international number re-selects the country and drops
            // its prefix, so it can't end up duplicated next to the selector.
            if input.contains("+") || digits.count > 9,
               let match = Country.matching(dialCode: digits),
               digits.count > match.dial.count {
                country = match
                digits = String(digits.dropFirst(match.dial.count))
            }
            return IdentifierDetector.formatPhone(digits)
        case .unknown:
            return input
        }
    }
}
