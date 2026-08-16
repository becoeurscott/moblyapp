import SwiftUI

/// Mobly's standard filled text field: leading SF Symbol, grey fill,
/// focus ring in brand blue, optional password reveal toggle.
struct MoblyTextField: View {
    var label: String
    var placeholder: String
    var systemIcon: String
    @Binding var text: String

    var isSecure: Bool = false
    var keyboard: UIKeyboardType = .default
    var textContentType: UITextContentType? = nil
    var autocapitalization: TextInputAutocapitalization = .never
    var submitLabel: SubmitLabel = .next
    var onSubmit: () -> Void = {}

    @FocusState private var focused: Bool
    @State private var reveal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.moblyBody(12.5, weight: .semibold))
                .foregroundStyle(Color(hex: 0x6B6F80))

            HStack(spacing: 10) {
                Image(systemName: systemIcon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(focused ? Color.moblyPrimary : Color(hex: 0x9A9DAC))
                    .frame(width: 20)

                Group {
                    if isSecure && !reveal {
                        SecureField(placeholder, text: $text)
                    } else {
                        TextField(placeholder, text: $text)
                    }
                }
                .font(.moblyBody(15, weight: .medium))
                .foregroundStyle(Color.moblyTextPrimary)
                .focused($focused)
                .keyboardType(keyboard)
                .textContentType(textContentType)
                .textInputAutocapitalization(autocapitalization)
                .autocorrectionDisabled()
                .submitLabel(submitLabel)
                .onSubmit(onSubmit)

                if isSecure {
                    Button {
                        reveal.toggle()
                    } label: {
                        Image(systemName: reveal ? "eye.slash" : "eye")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color(hex: 0x9A9DAC))
                    }
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
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
    }
}
