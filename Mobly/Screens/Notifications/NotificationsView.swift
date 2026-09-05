import SwiftUI

struct MoblyNotification: Identifiable {
    enum Kind {
        case message, visit, match, priceDrop, verified, boost, newListing, reengage
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
            }
        }
        var tint: UInt32 {
            switch self {
            case .message:    return 0x3A4FF0
            case .visit:      return 0x1F8A5B
            case .match:      return 0xFF6B35
            case .priceDrop:  return 0x1F8A5B
            case .verified:   return 0x3A4FF0
            case .boost:      return 0xFF6B35
            case .newListing: return 0xFF6B35
            case .reengage:   return 0x3A4FF0
            }
        }
        var bg: UInt32 {
            switch self {
            case .message, .verified, .reengage: return 0xEEF0FE
            case .visit, .priceDrop:             return 0xEAF6EF
            case .match, .boost, .newListing:    return 0xFFF1EA
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

    init(id: String = UUID().uuidString, kind: Kind, title: String,
         message: String, time: String, createdAt: Date = Date(),
         unread: Bool) {
        self.id = id; self.kind = kind; self.title = title; self.message = message
        self.time = time; self.createdAt = createdAt; self.unread = unread
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
        default:                                            k = .message
        }
        return MoblyNotification(
            id: dto.id,
            kind: k,
            title: dto.title,
            message: dto.body ?? "",
            time: Self.relative(dto.createdAt),
            createdAt: dto.createdAt,
            unread: !dto.read
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
    var onClose: () -> Void = {}

    @ObservedObject private var userData = UserDataStore.shared

    /// Server notifications split into "today" vs "earlier" so the section
    /// headers actually reflect when things happened. Both computed from a
    /// single source (`userData.notifications`) so mark-all-read wipes both
    /// without any local drift.
    private var todayItems: [MoblyNotification] {
        userData.notifications.filter { Calendar.current.isDateInToday($0.createdAt) }
            .map(MoblyNotification.from)
    }
    private var earlierItems: [MoblyNotification] {
        userData.notifications.filter { !Calendar.current.isDateInToday($0.createdAt) }
            .map(MoblyNotification.from)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if userData.notifications.isEmpty {
                emptyState
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        if !todayItems.isEmpty { section("Aujourd'hui", items: todayItems) }
                        if !earlierItems.isEmpty { section("Plus tôt", items: earlierItems) }
                    }
                    .padding(.bottom, 30)
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

    private func section(_ title: String, items: [MoblyNotification]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(LT(title))
                .font(.moblyBody(12.5, weight: .semibold))
                .foregroundStyle(Color(hex: 0x9A9DAC))
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 8)
            ForEach(items) { item in
                NotificationRow(item: item)
                    .onTapGesture {
                        // Mark-read of a single row is a next step; for now
                        // any tap flips the whole inbox to read.
                        Task { await userData.markAllNotificationsRead() }
                    }
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
        withAnimation(.easeOut(duration: 0.25)) {
        }
    }
}

struct NotificationRow: View {
    let item: MoblyNotification

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
            }

            if item.unread {
                Circle().fill(Color.moblyAccent).frame(width: 8, height: 8)
                    .offset(y: 6)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(item.unread ? Color(hex: 0xF7F8FF) : Color.white)
    }
}

#Preview {
    NotificationsView()
}
