import SwiftUI

/// Full-screen explainer shown right before an iOS permission prompt, at the
/// end of signup.
///
/// iOS shows its own dialog exactly once; a refusal there can only be undone
/// in Réglages. So the user first sees, in Mobly's words, what the permission
/// is for — and "Plus tard" leaves the system prompt unused, to be asked again
/// at a better moment (e.g. the first message sent) instead of burnt.
struct PermissionPrimerView: View {
    enum Kind { case notifications, location }

    var kind: Kind
    var firstName: String = ""
    /// Position of this screen among the primers actually shown (1-based).
    var step: Int = 1
    var stepCount: Int = 1
    var isBusy: Bool = false
    var onAllow: () -> Void
    var onSkip: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appear = false

    var body: some View {
        VStack(spacing: 0) {
            if stepCount > 1 {
                HStack(spacing: 6) {
                    ForEach(1...stepCount, id: \.self) { i in
                        Capsule()
                            .fill(i <= step ? Color.moblyPrimary : Color(hex: 0xE2E4EC))
                            .frame(width: i == step ? 22 : 8, height: 8)
                    }
                }
                .padding(.top, 12)
            }

            Spacer(minLength: 12)

            PrimerIllustration(art: kind == .notifications ? .notifications : .location, appear: appear)
                .padding(.bottom, 34)

            VStack(spacing: 12) {
                if !firstName.isEmpty {
                    Text(eyebrow)
                        .font(.moblyBody(13, weight: .semibold))
                        .foregroundStyle(Color.moblyPrimary)
                }
                Text(title)
                    .font(.moblyHeading(28))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(message)
                    .font(.moblyBody(15))
                    .foregroundStyle(Color(hex: 0x6B6F80))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 30)
            .opacity(appear ? 1 : 0)
            .offset(y: appear ? 0 : 12)

            Spacer(minLength: 24)

            VStack(spacing: 6) {
                PillButton(title: allowTitle, style: .primaryBlue,
                           trailingIcon: nil, action: onAllow)
                    .opacity(isBusy ? 0.6 : 1)
                    .disabled(isBusy)
                Button(action: onSkip) {
                    Text("Plus tard")
                        .font(.moblyHeading(16))
                        .foregroundStyle(Color.moblyTextPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.ignoresSafeArea())
        .onAppear {
            if reduceMotion { appear = true } else {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.78).delay(0.1)) { appear = true }
            }
        }
    }

    // Copy speaks to what a tenant or owner actually worries about — a
    // reply missed, a visit forgotten, a listing too far away — and says
    // plainly what we will NOT do with the permission.

    private var eyebrow: LocalizedStringKey {
        switch kind {
        case .notifications: return "\(firstName), une dernière chose"
        case .location:      return "Presque fini, \(firstName)"
        }
    }

    private var title: LocalizedStringKey {
        switch kind {
        case .notifications: return "Ne ratez aucune réponse"
        case .location:      return "Voyez d'abord ce qui est près de vous"
        }
    }

    private var message: LocalizedStringKey {
        switch kind {
        case .notifications:
            return "Les bons espaces partent vite. On vous prévient dès qu'un propriétaire vous répond ou confirme votre visite — rien d'autre."
        case .location:
            return "Mobly classe les annonces selon la distance. Votre position exacte n'est jamais partagée avec les propriétaires."
        }
    }

    private var allowTitle: String {
        switch kind {
        case .notifications: return L("Activer les notifications")
        case .location:      return L("Autoriser la localisation")
        }
    }
}

// MARK: - Illustration

/// What the floating card in the illustration previews.
enum PrimerArt {
    case notifications, location
    /// Signup's code screens: the SMS on its way, the e-mail in the inbox.
    case sms, email
}

/// A phone rising out of a soft disc with a card floating across it — the
/// card previews what the step actually brings.
///
/// `compact` is the code screens' version: the keyboard is up there, so the
/// disc is drawn at half size and the card shows shapes instead of text,
/// which would be too small to read.
struct PrimerIllustration: View {
    var art: PrimerArt
    var appear: Bool
    var compact: Bool = false

    private let disc: CGFloat = 300
    private var scale: CGFloat { compact ? 0.5 : 1 }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.moblySurfaceTint.opacity(0.7))
                .frame(width: disc, height: disc)

            phone
                .frame(width: disc, height: disc)
                .clipShape(Circle())

            card
                .offset(y: appear ? 12 : 34)
                .scaleEffect(appear ? 1 : 0.92)
                .opacity(appear ? 1 : 0)
        }
        .frame(width: disc, height: disc)
        // scaleEffect alone keeps the full-size layout footprint.
        .scaleEffect(scale)
        .frame(width: disc * scale, height: disc * scale)
        .accessibilityHidden(true)
    }

    /// Only the top two-thirds of the phone shows; the disc crops the rest.
    private var phone: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 40, style: .continuous)
                .fill(Color(hex: 0x14152A))
            RoundedRectangle(cornerRadius: 33, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0xA9B3FF), Color(hex: 0xD6DBFF)],
                                     startPoint: .top, endPoint: .bottom))
                .padding(7)
                .overlay(screenContent.padding(7))
            Capsule()
                .fill(Color(hex: 0x14152A))
                .frame(width: 58, height: 17)
                .overlay(alignment: .trailing) {
                    Circle().fill(Color(hex: 0x2A2C44)).frame(width: 7, height: 7).padding(.trailing, 6)
                }
                .padding(.top, 17)
        }
        .frame(width: 168, height: 330)
        .offset(y: 62)
    }

    /// For location, a hint of a map behind the card.
    @ViewBuilder private var screenContent: some View {
        if art == .location {
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h * 0.62)); p.addLine(to: CGPoint(x: w, y: h * 0.48))
                    p.move(to: CGPoint(x: w * 0.3, y: 0)); p.addLine(to: CGPoint(x: w * 0.42, y: h))
                    p.move(to: CGPoint(x: w * 0.78, y: 0)); p.addLine(to: CGPoint(x: w * 0.7, y: h))
                }
                .stroke(Color.white.opacity(0.55), lineWidth: 6)
                ForEach(Array(pins.enumerated()), id: \.offset) { _, pin in
                    Circle()
                        .fill(Color.moblyPrimary)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .position(x: w * pin.x, y: h * pin.y)
                }
            }
        }
    }

    private var pins: [CGPoint] {
        [CGPoint(x: 0.22, y: 0.72), CGPoint(x: 0.58, y: 0.66), CGPoint(x: 0.82, y: 0.8)]
    }

    private var icon: String {
        switch art {
        case .notifications: return "bell.fill"
        case .location:      return "location.fill"
        case .sms:           return "message.fill"
        case .email:         return "envelope.fill"
        }
    }

    private var card: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.moblySurfaceTint).frame(width: 58, height: 58)
                Circle().fill(Color.moblyPrimary).frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.bounce, value: appear)
            }
            if compact { cardShapes } else { cardText }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .frame(width: 292)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.white)
                .shadow(color: Color(hex: 0x14152A).opacity(0.12), radius: 18, y: 10)
        )
    }

    private var cardText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(cardTitle)
                .font(.moblyBody(13.5, weight: .bold))
                .foregroundStyle(Color.moblyTextPrimary)
                .lineLimit(1)
            Text(cardSubtitle)
                .font(.moblyBody(12))
                .foregroundStyle(Color(hex: 0x6B6F80))
                .lineLimit(2)
        }
    }

    /// A line for the sender, then either the code's digits (SMS) or the
    /// body of a mail.
    private var cardShapes: some View {
        VStack(alignment: .leading, spacing: 12) {
            Capsule().fill(Color(hex: 0xDDE1FB)).frame(width: 120, height: 12)
            if art == .sms {
                HStack(spacing: 10) {
                    ForEach(0..<4, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 6).fill(Color.moblyPrimary)
                            .frame(width: 22, height: 26)
                    }
                }
            } else {
                Capsule().fill(Color(hex: 0xDDE1FB)).frame(width: 170, height: 12)
                Capsule().fill(Color(hex: 0xDDE1FB)).frame(width: 90, height: 12)
            }
        }
    }

    private var cardTitle: LocalizedStringKey {
        art == .notifications ? "Visite confirmée" : "Près de vous"
    }

    private var cardSubtitle: LocalizedStringKey {
        art == .notifications
            ? "Le propriétaire vous attend demain à 10 h."
            : "Les espaces les plus proches en premier."
    }
}

// MARK: - Code screens header

/// Top of the phone and e-mail code screens: the compact illustration, then
/// a title and one or two sentences on why we ask — so a code reads as a
/// reason, not a hoop.
struct CodeHeroHeader: View {
    var art: PrimerArt
    var title: LocalizedStringKey
    var message: LocalizedStringKey
    var onBack: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appear = false

    var body: some View {
        VStack(spacing: 0) {
            PrimerIllustration(art: art, appear: appear, compact: true)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .topLeading) {
                    if let onBack {
                        Button(action: onBack) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Color.moblyTextPrimary)
                                .frame(width: 40, height: 40)
                                .background(RoundedRectangle(cornerRadius: 13).fill(Color(hex: 0xF4F5F8)))
                        }
                    }
                }
                .padding(.bottom, 12)

            Text(title)
                .font(.moblyHeading(24))
                .foregroundStyle(Color.moblyTextPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)
            Text(message)
                .font(.moblyBody(13.5))
                .foregroundStyle(Color(hex: 0x6B6F80))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 18)
        .onAppear {
            if reduceMotion { appear = true } else {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.78).delay(0.1)) { appear = true }
            }
        }
    }
}

#Preview("Notifications") {
    PermissionPrimerView(kind: .notifications, firstName: "Jeanne", step: 1, stepCount: 2,
                         onAllow: {}, onSkip: {})
}

#Preview("Location") {
    PermissionPrimerView(kind: .location, firstName: "Jeanne", step: 2, stepCount: 2,
                         onAllow: {}, onSkip: {})
}
