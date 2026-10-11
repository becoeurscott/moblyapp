import SwiftUI

/// The in-app welcome shown once, the first time a brand-new account reaches
/// Home. The server already writes a WELCOME notification at signup, but its
/// push goes out before the user has granted notification permission (the
/// primer comes later in the post-signup steps), so no banner ever appeared
/// and the bell kept its stale empty state. This card makes the welcome
/// visible regardless of push permission.
enum WelcomeBannerGate {
    private static func pendingKey(_ uid: String) -> String { "welcomeBanner.pending.\(uid)" }
    private static func shownKey(_ uid: String) -> String { "welcomeBanner.shown.\(uid)" }

    /// Called when the post-signup onboarding finishes (a new account only).
    @MainActor static func markPending() {
        guard let uid = Session.shared.userId else { return }
        UserDefaults.standard.set(true, forKey: pendingKey(uid))
    }

    static var isDemo: Bool { ProcessInfo.processInfo.environment["WELCOME_DEMO"] == "1" }

    /// True at most once per account: consumes the pending flag.
    @MainActor static func consume() -> Bool {
        if isDemo { return true }
        guard let uid = Session.shared.userId else { return false }
        let d = UserDefaults.standard
        guard d.bool(forKey: pendingKey(uid)), !d.bool(forKey: shownKey(uid)) else { return false }
        d.set(true, forKey: shownKey(uid))
        d.removeObject(forKey: pendingKey(uid))
        return true
    }
}

struct WelcomeBannerContent: Equatable {
    let title: String
    let body: String

    @MainActor static func make(from notifications: [NotificationDTO]) -> WelcomeBannerContent {
        if let n = notifications.first(where: { ($0.type ?? "").uppercased() == "WELCOME" }) {
            return .init(title: n.title, body: n.body ?? fallbackBody)
        }
        let first = Session.shared.firstName
        let name = first.isEmpty ? "" : " \(first)"
        return .init(title: "Bienvenue sur Mobly\(name) 👋", body: fallbackBody)
    }

    static let fallbackBody =
        "Trouvez une chambre, un studio, un bureau ou une boutique partout au Cameroun. " +
        "Enregistrez vos coups de cœur et échangez directement avec les propriétaires."
}

/// iOS notification style card that slides from the top.
struct WelcomeBannerView: View {
    let content: WelcomeBannerContent
    var onTap: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.moblyPrimary)
                .frame(width: 38, height: 38)
                .overlay(
                    Image(systemName: "house.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                )
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("MOBLY")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color.moblyTextSecondary)
                    Spacer()
                    Text("maintenant")
                        .font(.system(size: 12))
                        .foregroundColor(Color.moblyTextSecondary)
                }
                Text(content.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color.moblyTextPrimary)
                    .lineLimit(1)
                Text(content.body)
                    .font(.system(size: 14))
                    .foregroundColor(Color.moblyTextPrimary.opacity(0.85))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 18, y: 8)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .gesture(
            DragGesture(minimumDistance: 10).onEnded { v in
                if v.translation.height < -10 { onDismiss() }
            }
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
