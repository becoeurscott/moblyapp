import SwiftUI

/// Where tapping a notification (or a visit card) should land.
enum NotificationTarget: Equatable {
    case thread(String)
    case listing(String)
    case visits
    /// Start the become-owner flow (the "Vous avez un espace à louer ?" invite).
    case becomeOwner
    /// Open the e-mail confirmation screen.
    case verifyEmail
}

struct MoblyNotification: Identifiable {
    enum Kind {
        case message, visit, match, priceDrop, verified, boost, newListing, reengage, welcome
        case ownerInvite, verifyEmail
        var icon: String {
            switch self {
            case .message:    return "bubble.left.fill"
            case .visit:      return "calendar.badge.checkmark"
            case .match:      return "sparkles"
            case .priceDrop:  return "arrow.down.circle.fill"
            case .verified:   return "checkmark.seal.fill"
            case .boost:      return "megaphone.fill"
            case .newListing: return "house.fill"
            case .reengage:   return "bell.badge.fill"
            case .welcome:    return "hand.wave.fill"
            case .ownerInvite: return "house.fill"
            case .verifyEmail: return "envelope.badge.fill"
            }
        }
        var tint: UInt32 {
            switch self {
            case .message:    return 0x3A4FF0
            case .visit:      return 0x1F8A5B
            case .match:      return 0x4C9BFF
            case .priceDrop:  return 0x1F8A5B
            case .verified:   return 0x3A4FF0
            case .boost:      return 0x4C9BFF
            case .newListing: return 0x4C9BFF
            case .reengage:   return 0x3A4FF0
            case .welcome:    return 0x3A4FF0
            case .ownerInvite: return 0x1F8A5B
            case .verifyEmail: return 0xE5950C
            }
        }
        var bg: UInt32 {
            switch self {
            case .message, .verified, .reengage, .welcome: return 0xEEF0FE
            case .ownerInvite:                   return 0xEAF6EF
            case .verifyEmail:                   return 0xFFF4E5
            case .visit, .priceDrop:             return 0xEAF6EF
            case .match, .boost, .newListing:    return 0xEAF3FF
            }
        }
        /// Header of an expanded stack.
        var groupTitle: String {
            switch self {
            case .message:    return "Messages"
            case .visit:      return "Visites"
            case .match:      return "Recherches"
            case .priceDrop:  return "Baisses de prix"
            case .verified:   return "Vérification"
            case .boost:      return "Mobly"
            case .newListing: return "Nouvelles annonces"
            case .reengage:   return "Rappels"
            case .welcome:    return "Bienvenue"
            case .ownerInvite: return "Devenir propriétaire"
            case .verifyEmail: return "Adresse e-mail"
            }
        }
    }

    let id: String
    let kind: Kind
    let title: String
    let message: String
    let time: String
    let createdAt: Date
    var unread: Bool
    /// Where this notification happened — `threadId`, `listingId`, `visitId`.
    var payload: [String: String] = [:]

    init(id: String = UUID().uuidString, kind: Kind, title: String,
         message: String, time: String, createdAt: Date = Date(),
         unread: Bool, payload: [String: String] = [:]) {
        self.id = id; self.kind = kind; self.title = title; self.message = message
        self.time = time; self.createdAt = createdAt; self.unread = unread
        self.payload = payload
    }

    /// Resolved destination for a tap. Nil when the server sent no target, in
    /// which case the row stays inert rather than pretending to lead somewhere.
    var destination: NotificationTarget? {
        switch payload["action"] {
        case "become_owner": return .becomeOwner
        case "verify_email": return .verifyEmail
        default: break
        }
        if let t = payload["threadId"], !t.isEmpty { return .thread(t) }
        if let l = payload["listingId"], !l.isEmpty { return .listing(l) }
        if payload["visitId"] != nil || kind == .visit { return .visits }
        return nil
    }

    /// Convert a raw server DTO into the display model. Chooses an icon /
    /// tint from the server's `type` string; unknown types fall through to
    /// the neutral "message" style.
    static func from(_ dto: NotificationDTO) -> MoblyNotification {
        let k: Kind
        switch (dto.type ?? "").uppercased() {
        case "VISIT", "VISIT_REQUEST", "VISIT_CONFIRMED":  k = .visit
        case "MATCH", "SAVED_SEARCH":                       k = .match
        case "PRICE_DROP":                                  k = .priceDrop
        case "VERIFIED":                                    k = .verified
        case "BOOST", "PROMO", "ANNOUNCEMENT", "ALERT":     k = .boost
        case "NEW_LISTING":                                 k = .newListing
        case "REENGAGE_3D", "REENGAGE_7D", "REENGAGE_14D": k = .reengage
        case "WELCOME":                                     k = .welcome
        case "OWNER_INVITE":                                k = .ownerInvite
        case "VERIFY_EMAIL":                                k = .verifyEmail
        default:                                            k = .message
        }
        return MoblyNotification(
            id: dto.id,
            kind: k,
            title: dto.title,
            message: dto.body ?? "",
            time: Self.relative(dto.createdAt),
            createdAt: dto.createdAt,
            unread: !dto.read,
            payload: dto.payload ?? [:]
        )
    }

    private static func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}

enum NotificationData {
    static let today: [MoblyNotification] = []
    static let earlier: [MoblyNotification] = []
}

struct NotificationsView: View {
    /// Called with the deep-link target when a notification is tapped.
    var onOpen: (NotificationTarget) -> Void = { _ in }
    var onClose: () -> Void = {}

    @ObservedObject private var userData = UserDataStore.shared
    /// Stacks the user fanned out (section + category).
    @State private var expanded: Set<String> = []

    /// Server notifications split into "today" vs "earlier" so the section
    /// headers actually reflect when things happened. Both computed from a
    /// single source (`userData.notifications`) so mark-all-read wipes both
    /// without any local drift.
    private var todayItems: [MoblyNotification] {
        source.filter { Calendar.current.isDateInToday($0.createdAt) }
            .map(MoblyNotification.from)
    }
    private var earlierItems: [MoblyNotification] {
        source.filter { !Calendar.current.isDateInToday($0.createdAt) }
            .map(MoblyNotification.from)
    }

    private var source: [NotificationDTO] {
        #if DEBUG
        if let demo = Self.demoNotifications { return demo }
        #endif
        return userData.notifications
    }

    #if DEBUG
    /// `NOTIF_DEMO=1`: a fixed inbox for screenshotting the stacks without a
    /// signed-in account. Debug builds only.
    private static let demoNotifications: [NotificationDTO]? = {
        guard ProcessInfo.processInfo.environment["NOTIF_DEMO"] == "1" else { return nil }
        let now = Date()
        func at(_ minutesAgo: Double) -> String {
            ISO8601DateFormatter().string(from: now.addingTimeInterval(-minutesAgo * 60))
        }
        let rows: [(String, String, String, Double, Bool)] = [
            ("OWNER_INVITE", "Vous avez un espace à louer ?", "Devenez propriétaire sur Mobly : publiez vos annonces gratuitement pendant 7 jours.", 61, false),
            ("VERIFY_EMAIL", "Confirmez votre adresse e-mail", "Confirmez votre adresse avec un code pour pouvoir récupérer votre compte.", 62, false),
            ("MESSAGE", "Aïcha N.", "Bonjour, le studio est-il toujours disponible ?", 3, false),
            ("MESSAGE", "Paul M.", "Je peux passer demain à 10h ?", 18, false),
            ("MESSAGE", "Brenda T.", "Merci pour la visite !", 42, true),
            ("VISIT_REQUEST", "Nouvelle demande de visite", "Kevin souhaite visiter Kina Home Complex samedi.", 25, false),
            ("WELCOME", "Bienvenue sur Mobly Thomas 👋", "Trouvez une chambre, un studio, un bureau ou une boutique partout au Cameroun.", 60, false),
            ("NEW_LISTING", "Nouvelle annonce à Bonamoussadi", "Chambre moderne · 30 000 FCFA/mois", 1500, true),
            ("NEW_LISTING", "Nouvelle annonce à Akwa", "Studio meublé · 85 000 FCFA/mois", 1600, true),
            ("PRICE_DROP", "Baisse de prix", "Villa Bonapriso passe à 450 000 FCFA/mois", 2900, true),
        ]
        let json = "[" + rows.enumerated().map { i, r in
            let action = r.0 == "OWNER_INVITE" ? #","payload":{"action":"become_owner"}"#
                : r.0 == "VERIFY_EMAIL" ? #","payload":{"action":"verify_email"}"# : ""
            return #"{"id":"demo\#(i)","type":"\#(r.0)","title":"\#(r.1)","body":"\#(r.2)","read":\#(r.4),"createdAt":"\#(at(r.3))"\#(action)}"#
        }.joined(separator: ",") + "]"
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode([NotificationDTO].self, from: Data(json.utf8))
    }()
    #endif

    var body: some View {
        VStack(spacing: 0) {
            header

            if source.isEmpty {
                emptyState
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        if !todayItems.isEmpty { section("Aujourd'hui", items: todayItems) }
                        if !earlierItems.isEmpty { section("Plus tôt", items: earlierItems) }
                    }
                    .padding(.bottom, 30)
                    // A notification arriving from the background poll slides
                    // the list rather than reshuffling it under the thumb.
                    .animation(Motion.content, value: userData.notifications.map(\.id))
                }
                .refreshable { await userData.loadNotifications() }
            }
        }
        .background(Color.white)
        .task { await userData.loadNotifications() }
    }

    private var header: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 13).fill(Color(hex: 0xF4F5F8)))
            }
            Spacer()
            Text("Notifications")
                .font(.moblyHeading(18))
                .foregroundStyle(Color.moblyTextPrimary)
            Spacer()
            Button {
                markAllRead()
            } label: {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.moblyPrimary)
                    .frame(width: 40, height: 40)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    /// One category's notifications within a section, newest first.
    private struct NotifGroup: Identifiable {
        let id: String
        let kind: MoblyNotification.Kind
        let items: [MoblyNotification]
    }

    /// Category stacks, ordered by each one's most recent notification — the
    /// same ordering iOS uses for its own notification groups.
    private func groups(_ items: [MoblyNotification], section: String) -> [NotifGroup] {
        var order: [MoblyNotification.Kind] = []
        var byKind: [MoblyNotification.Kind: [MoblyNotification]] = [:]
        for item in items.sorted(by: { $0.createdAt > $1.createdAt }) {
            if byKind[item.kind] == nil { order.append(item.kind) }
            byKind[item.kind, default: []].append(item)
        }
        return order.map { NotifGroup(id: "\(section)-\($0)", kind: $0, items: byKind[$0] ?? []) }
    }

    private func section(_ title: String, items: [MoblyNotification]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(LT(title))
                .font(.moblyBody(12.5, weight: .semibold))
                .foregroundStyle(Color(hex: 0x9A9DAC))
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 8)
            VStack(spacing: 10) {
                ForEach(groups(items, section: title)) { group in
                    stack(group)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private func stack(_ group: NotifGroup) -> some View {
        if group.items.count == 1, let only = group.items.first {
            card(only)
        } else if expanded.contains(group.id) {
            VStack(spacing: 8) {
                HStack {
                    Text(LT(group.kind.groupTitle))
                        .font(.moblyHeading(15))
                        .foregroundStyle(Color.moblyTextPrimary)
                    Spacer()
                    Button {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                            _ = expanded.remove(group.id)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Réduire").font(.moblyBody(12.5, weight: .semibold))
                            Image(systemName: "chevron.up").font(.system(size: 11, weight: .bold))
                        }
                        .foregroundStyle(Color(hex: 0x6B6F80))
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(Capsule().fill(Color(hex: 0xF0F1F5)))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 2)

                ForEach(group.items) { item in
                    card(item)
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity
                        ))
                }
            }
        } else {
            collapsedStack(group)
        }
    }

    /// Newest card on top, up to two cards peeking out underneath, like a
    /// grouped notification on the iOS lock screen. A tap fans it out.
    private func collapsedStack(_ group: NotifGroup) -> some View {
        let top = group.items[0]
        let behind = min(group.items.count - 1, 2)
        let unreadCount = group.items.filter(\.unread).count
        return ZStack(alignment: .top) {
            ForEach((1...max(behind, 1)).reversed(), id: \.self) { depth in
                if depth <= behind {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(hex: depth == 1 ? 0xF4F5FA : 0xEDEEF4))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color(hex: 0xE6E8EF), lineWidth: 1))
                        .padding(.horizontal, CGFloat(depth) * 10)
                        .offset(y: CGFloat(depth) * 8)
                }
            }
            NotificationRow(item: top, unreadOverride: unreadCount > 0) {
                Text("+\(group.items.count - 1) \(group.items.count - 1 > 1 ? "autres" : "autre")")
                    .font(.moblyBody(11.5, weight: .semibold))
                    .foregroundStyle(Color.moblyPrimary)
                    .padding(.top, 4)
            }
        }
        .padding(.bottom, CGFloat(behind) * 8)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                _ = expanded.insert(group.id)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Afficher les \(group.items.count) notifications"))
    }

    private func card(_ item: MoblyNotification) -> some View {
        NotificationRow(item: item)
            .contentShape(Rectangle())
            .onTapGesture {
                // Mark-read of a single row is a next step; for now
                // any tap flips the whole inbox to read.
                Task { await userData.markAllNotificationsRead() }
                // …and take the user to where it happened. Rows with
                // no target stay put rather than bouncing you to a
                // screen that has nothing to do with the alert.
                if let target = item.destination {
                    onOpen(target)
                }
            }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "bell.slash")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Color(hex: 0xD5D8E2))
            Text("Aucune notification")
                .font(.moblyHeading(18))
                .foregroundStyle(Color.moblyTextPrimary)
            Text("Vos messages et visites apparaîtront ici.")
                .font(.moblyBody(13))
                .foregroundStyle(Color(hex: 0x9A9DAC))
            Spacer()
        }
    }

    private func markAllRead() {
        Task { await userData.markAllNotificationsRead() }
        withAnimation(Motion.quick) {
        }
    }
}

struct NotificationRow<Footer: View>: View {
    let item: MoblyNotification
    /// A stack shows its dot when any notification in it is unread.
    var unreadOverride: Bool? = nil
    @ViewBuilder var footer: () -> Footer

    private var unread: Bool { unreadOverride ?? item.unread }

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            ZStack {
                Circle().fill(Color(hex: item.kind.bg))
                Image(systemName: item.kind.icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(hex: item.kind.tint))
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.title)
                        .font(.moblyHeading(14.5))
                        .foregroundStyle(Color.moblyTextPrimary)
                    Spacer()
                    Text(item.time)
                        .font(.moblyBody(11))
                        .foregroundStyle(Color(hex: 0x9A9DAC))
                }
                Text(item.message)
                    .font(.moblyBody(12.5))
                    .foregroundStyle(Color(hex: 0x6B6F80))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                footer()
            }

            if unread {
                Circle().fill(Color.moblyAccent).frame(width: 8, height: 8)
                    .offset(y: 6)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(unread ? Color(hex: 0xF7F8FF) : Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(hex: 0xE6E8EF), lineWidth: 1)
        )
    }
}

extension NotificationRow where Footer == EmptyView {
    init(item: MoblyNotification, unreadOverride: Bool? = nil) {
        self.init(item: item, unreadOverride: unreadOverride) { EmptyView() }
    }
}

#Preview {
    NotificationsView()
}
