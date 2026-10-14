import SwiftUI
import UserNotifications

/// What the in-app visit reminder card shows.
struct VisitReminderContent: Equatable, Identifiable {
    enum Kind: Equatable { case upcoming, pending(count: Int) }
    let id: String
    let kind: Kind
    let title: String
    let listingTitle: String
    let whenLabel: String
    let counterpart: String
    /// Where "Voir" lands in the visits hub.
    let visitId: String?
    let tab: VisitsHubView.Tab
}

/// Decides which reminder (if any) to show, and keeps the local reminder
/// notifications in step with the user's confirmed visits.
@MainActor
enum VisitReminderCenter {
    static var isDemo: Bool { DevSwitch["VISIT_REMINDER_DEMO"] == "1" }

    private static let shownKey = "visitReminder.shown"
    private static var pendingShownThisSession = false
    private static let hour: TimeInterval = 3600
    private static let tz = TimeZone(identifier: "Africa/Douala") ?? .current

    static func demo() -> VisitReminderContent {
        let at = Date().addingTimeInterval(20 * hour)
        return VisitReminderContent(
            id: "demo", kind: .upcoming, title: "Rappel de visite",
            listingTitle: "Studio meublé à Bonapriso",
            whenLabel: whenLabel(at), counterpart: "Avec Paul Ndongo",
            visitId: nil, tab: .mine
        )
    }

    /// "Demain à 15h00", "Aujourd'hui à 9h30" or "Mardi 14 octobre à 15h00".
    static func whenLabel(_ at: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let hf = DateFormatter()
        hf.locale = Locale(identifier: "fr_FR"); hf.timeZone = tz; hf.dateFormat = "H'h'mm"
        let time = hf.string(from: at)
        if cal.isDateInToday(at) { return "Aujourd'hui à \(time)" }
        if cal.isDateInTomorrow(at) { return "Demain à \(time)" }
        let df = DateFormatter()
        df.locale = Locale(identifier: "fr_FR"); df.timeZone = tz; df.dateFormat = "EEEE d MMMM"
        return "\(df.string(from: at).capitalized(with: Locale(identifier: "fr_FR"))) à \(time)"
    }

    /// The four reminder moments, same as the server job.
    enum Slot: String, CaseIterable { case eve, morning, h1 = "1h", m30 = "30m" }

    static func fireDate(_ slot: Slot, for at: Date) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let day = cal.startOfDay(for: at)
        switch slot {
        case .eve: return day.addingTimeInterval(-6 * hour)            // 18h00 the day before
        case .morning:
            return at.timeIntervalSince(day) < 9 * hour ? nil : day.addingTimeInterval(8 * hour)
        case .h1: return at.addingTimeInterval(-hour)
        case .m30: return at.addingTimeInterval(-30 * 60)
        }
    }

    static func hourText(_ at: Date) -> String {
        let hf = DateFormatter()
        hf.locale = Locale(identifier: "fr_FR"); hf.timeZone = tz; hf.dateFormat = "H'h'mm"
        return hf.string(from: at)
    }

    static func body(_ slot: Slot, listing: String, at: Date) -> String {
        let h = hourText(at)
        switch slot {
        case .eve: return "Rappel : votre visite de \(listing) est demain à \(h)"
        case .morning: return "Aujourd'hui à \(h) : visite de \(listing)"
        case .h1: return "Votre visite de \(listing) est dans 1 heure"
        case .m30: return "Votre visite de \(listing) est dans 30 minutes"
        }
    }

    private static func me() -> String? { AuthStore.shared.user?.id }

    private static func counterpartName(_ v: VisitRequestDTO, me: String) -> String {
        let other = v.ownerId == me ? v.visitor : v.owner
        let name = other?.fullName?.trimmingCharacters(in: .whitespaces) ?? ""
        if name.isEmpty { return v.ownerId == me ? "Avec votre visiteur" : "Avec le propriétaire" }
        return "Avec \(name)"
    }

    /// Refresh both lists, sync local notifications, and return the card to
    /// show now, if any. Marks it shown so it appears once per visit and window.
    static func check() async -> VisitReminderContent? {
        if isDemo { return demo() }
        guard MoblyAPI.shared.isAuthenticated, let me = me() else { return nil }
        let store = VisitRequestStore.shared
        await store.refreshMine(silent: true)
        if Session.shared.isOwner { await store.refresh(silent: true) }

        var seen = Set<String>()
        let all = (store.myRequests + store.items).filter { seen.insert($0.id).inserted }
        await syncLocalNotifications(all, me: me)

        let now = Date()
        var shown = Set(UserDefaults.standard.stringArray(forKey: shownKey) ?? [])
        let confirmed = all
            .filter { $0.status == "CONFIRMED" && $0.scheduledAt > now }
            .sorted { $0.scheduledAt < $1.scheduledAt }
        for v in confirmed {
            // Latest slot whose moment has been reached; keyed by visit time
            // too, so a rescheduled visit is reminded again.
            guard let slot = Slot.allCases.last(where: { s in
                fireDate(s, for: v.scheduledAt).map { $0 <= now } ?? false
            }) else { continue }
            let key = "\(v.id)|\(Int(v.scheduledAt.timeIntervalSince1970))|\(slot.rawValue)"
            guard !shown.contains(key) else { continue }
            shown.insert(key)
            UserDefaults.standard.set(Array(shown.suffix(200)), forKey: shownKey)
            return VisitReminderContent(
                id: key, kind: .upcoming, title: "Rappel de visite",
                listingTitle: v.listing?.title ?? "Votre visite",
                whenLabel: slot == .h1 ? "Dans 1 heure, à \(hourText(v.scheduledAt))"
                    : slot == .m30 ? "Dans 30 minutes, à \(hourText(v.scheduledAt))"
                    : whenLabel(v.scheduledAt),
                counterpart: counterpartName(v, me: me),
                visitId: v.id, tab: v.ownerId == me ? .received : .mine
            )
        }

        if Session.shared.isOwner, !pendingShownThisSession {
            let pending = store.items.filter { $0.status == "REQUESTED" && $0.ownerId == me && $0.scheduledAt > now }
            if !pending.isEmpty {
                pendingShownThisSession = true
                let n = pending.count
                return VisitReminderContent(
                    id: "pending-\(n)", kind: .pending(count: n),
                    title: n == 1 ? "Vous avez 1 demande de visite en attente"
                                  : "Vous avez \(n) demandes de visite en attente",
                    listingTitle: n == 1 ? (pending[0].listing?.title ?? "") : "",
                    whenLabel: "", counterpart: "",
                    visitId: n == 1 ? pending[0].id : nil, tab: .received
                )
            }
        }
        return nil
    }

    // MARK: Local notifications

    private static let prefix = "visit-reminder-"

    /// Four reminders per confirmed visit (eve 18h00, morning 08h00, 1h, 30 min), identifiers keyed by
    /// visit id so a reschedule replaces them. Skipped when the server sends
    /// the reminders itself (flag `visits.serverReminders`, off by default).
    static func syncLocalNotifications(_ visits: [VisitRequestDTO], me: String) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
            .map(\.identifier).filter { $0.hasPrefix(prefix) }
        let serverOn = RemoteConfigStore.shared.config.flags["visits.serverReminders"]?.enabled ?? false
        let settings = await center.notificationSettings()
        let allowed = [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
        guard allowed, !serverOn else {
            center.removePendingNotificationRequests(withIdentifiers: pending)
            return
        }
        let now = Date()
        var wanted = Set<String>()
        for v in visits where v.status == "CONFIRMED" && v.scheduledAt > now {
            for slot in Slot.allCases {
                guard let fire = fireDate(slot, for: v.scheduledAt),
                      fire > now.addingTimeInterval(30) else { continue }
                let id = "\(prefix)\(v.id)-\(slot.rawValue)"
                wanted.insert(id)
                let content = UNMutableNotificationContent()
                content.title = "Rappel de visite"
                content.body = body(slot, listing: v.listing?.title ?? "votre annonce", at: v.scheduledAt)
                content.sound = .default
                content.userInfo = ["visitId": v.id, "type": "visit.reminder"]
                let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fire)
                let req = UNNotificationRequest(
                    identifier: id, content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                )
                try? await center.add(req)
            }
        }
        // Cancelled, done or past visits lose their reminders.
        let stale = pending.filter { !wanted.contains($0) }
        if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
    }
}

/// Centered card over a dimmed backdrop, in the app's card style.
struct VisitReminderCard: View {
    let content: VisitReminderContent
    var onOpen: () -> Void
    var onDismiss: () -> Void

    private var isPending: Bool { if case .pending = content.kind { return true } else { return false } }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture(perform: onDismiss)
            VStack(spacing: 14) {
                Circle()
                    .fill(Color.moblyPrimary.opacity(0.12))
                    .frame(width: 56, height: 56)
                    .overlay(
                        Image(systemName: isPending ? "tray.full.fill" : "calendar.badge.clock")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundColor(Color.moblyPrimary)
                    )
                Text(content.title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(Color.moblyTextPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if !content.listingTitle.isEmpty || !content.whenLabel.isEmpty {
                    VStack(spacing: 6) {
                        if !content.listingTitle.isEmpty {
                            Text(content.listingTitle)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(Color.moblyTextPrimary)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                        }
                        if !content.whenLabel.isEmpty {
                            Label(content.whenLabel, systemImage: "clock")
                                .font(.system(size: 14))
                                .foregroundColor(Color.moblyTextSecondary)
                        }
                        if !content.counterpart.isEmpty {
                            Label(content.counterpart, systemImage: "person")
                                .font(.system(size: 14))
                                .foregroundColor(Color.moblyTextSecondary)
                        }
                    }
                }
                VStack(spacing: 8) {
                    Button(action: onOpen) {
                        Text(isPending ? "Voir" : "Voir la visite")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Capsule().fill(Color.moblyPrimary))
                    }
                    Button(action: onDismiss) {
                        Text("OK")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Color.moblyTextPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                }
                .padding(.top, 4)
            }
            .padding(22)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.white)
            )
            .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
            .padding(.horizontal, 32)
        }
    }
}
