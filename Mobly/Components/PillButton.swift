import SwiftUI

enum PillButtonStyle {
    case primaryBlue
    case primaryOrange
    case onBlue
    case outline
}

struct PillButton: View {
    var title: String
    var style: PillButtonStyle = .primaryBlue
    var trailingIcon: String? = "arrow.right"
    var height: CGFloat = 56
    var action: () -> Void = {}

    @State private var pressed = false

    var body: some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        }) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.moblyHeading(16))
                if let icon = trailingIcon {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                }
            }
            .foregroundStyle(fg)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(Capsule().fill(bg))
            .overlay(Capsule().stroke(strokeColor, lineWidth: strokeWidth))
            .shadow(color: shadowColor, radius: 14, x: 0, y: 10)
            .scaleEffect(pressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.12), value: pressed)
        }
        .buttonStyle(PressReporterStyle(pressed: $pressed))
    }

    private var bg: Color {
        switch style {
        case .primaryBlue:      return .moblyPrimary
        case .primaryOrange:    return .moblyAccent
        case .onBlue, .outline: return .white
        }
    }

    private var fg: Color {
        switch style {
        case .primaryBlue, .primaryOrange: return .white
        case .onBlue:  return .moblyPrimary
        case .outline: return .moblyTextPrimary
        }
    }

    private var strokeColor: Color {
        style == .outline ? Color(hex: 0xE2E4EC) : .clear
    }
    private var strokeWidth: CGFloat { style == .outline ? 1.5 : 0 }

    private var shadowColor: Color {
        switch style {
        case .primaryBlue:   return Color.moblyPrimary.opacity(0.28)
        case .primaryOrange: return Color.moblyAccent.opacity(0.30)
        case .onBlue:        return Color.black.opacity(0.20)
        case .outline:       return .clear
        }
    }
}

private struct PressReporterStyle: ButtonStyle {
    @Binding var pressed: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, newValue in
                pressed = newValue
            }
    }
}

struct CircleBackButton: View {
    var action: () -> Void
    @State private var pressed = false
    var body: some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        }) {
            Image(systemName: "chevron.left")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.moblyTextPrimary)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Color(hex: 0xF4F5F8)))
                .scaleEffect(pressed ? 0.94 : 1.0)
                .animation(.easeOut(duration: 0.12), value: pressed)
        }
        .buttonStyle(PressReporterStyle(pressed: $pressed))
    }
}
