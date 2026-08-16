import SwiftUI

/// A conversation row.
///
/// `id` is the **server** thread id, not a locally-minted UUID — an incoming
/// socket event has to be matched to the row it belongs to, and a client-side
/// identifier can never do that.
struct ChatThread: Identifiable, Hashable {
    let id: String
    let initial: String
    /// Peer's identity colour — from the peer's stored `avatarColor`, or the
    /// deterministic palette fallback. All chat surfaces (row avatar, thread
    /// header, testimonial-like cards) key on this so the person is
    /// recognisable across the app.
    let color: Color
    let name: String
    let verified: Bool
    let online: Bool
    let time: String
    let listing: String        // "Studio Akwa · 80 000 FCFA"
    let listingTitle: String
    let listingPrice: String
    let listingImage: String
    /// Remote cover for the listing, when the thread has one.
    var listingCoverUrl: String? = nil
    let preview: String
    var unread: Int            // 0 = read
    let fromMe: Bool           // preview is "Vous: …"
    /// Server ids the visit flow needs — the visitor (the other party in the
    /// conversation), the listing being discussed, and its owner. Nil when the
    /// thread is a preview / synthesized locally.
    var peerId: String? = nil
    var listingId: String? = nil
    var listingOwnerId: String? = nil
}

extension ChatThread {
    /// Build a row from the server payload.
    static func from(_ dto: ThreadDTO, myUserId: String?) -> ChatThread {
        let peer = dto.participants.first
        let name = peer?.fullName ?? "Utilisateur"
        let last = dto.lastMessage
        let mine = last?.senderId == myUserId

        return ChatThread(
            id: dto.id,
            initial: String(name.prefix(1)).uppercased(),
            color: AvatarPalette.color(for: peer?.id ?? dto.id, stored: peer?.avatarColor),
            name: name,
            verified: peer?.verified ?? false,
            online: peer?.online ?? false,
            time: Self.relativeTime(dto.lastMessage?.createdAt ?? dto.updatedAt),
            listing: [dto.listing?.title, dto.listing?.priceFcfa.map(Self.formatFcfa)]
                .compactMap { $0 }.joined(separator: " · "),
            listingTitle: dto.listing?.title ?? "",
            listingPrice: dto.listing?.priceFcfa.map(Self.formatFcfa) ?? "",
            listingImage: dto.listing?.imageName ?? "ListingGreen",
            listingCoverUrl: dto.listing?.coverUrl,
            preview: last?.text ?? "",
            unread: dto.unread,
            fromMe: mine,
            peerId: peer?.id,
            listingId: dto.listing?.id,
            listingOwnerId: dto.listing?.ownerId
        )
    }

    /// Stable colour derived from the thread id, so an avatar doesn't change
    /// hue between launches.
    private static func avatarColor(for id: String) -> Color {
        let palette: [Color] = [
            .moblyPrimary, Color(hex: 0xFF6B35), Color(hex: 0x1F8A5B),
            Color(hex: 0x8B5CF6), Color(hex: 0xD9A21B), Color(hex: 0x2E7BE4),
        ]
        return palette[abs(id.hashValue) % palette.count]
    }

    private static func formatFcfa(_ n: Int) -> String {
        let s = String(n)
        var out = ""
        for (i, c) in s.reversed().enumerated() {
            if i > 0 && i % 3 == 0 { out.append(" ") }
            out.append(c)
        }
        return String(out.reversed()) + " FCFA"
    }

    static func relativeTime(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: date)
        }
        if cal.isDateInYesterday(date) { return "Hier" }
        if let days = cal.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR")
            f.dateFormat = "EEE"; return f.string(from: date).capitalized
        }
        let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "d MMM"; return f.string(from: date)
    }
}

enum MessageStatus { case sent, delivered, read }
enum MessageKind { case text, voice, image, visit, location }

struct ChatMessage: Identifiable, Equatable {
    /// Server message id, or "local-…" while a send is still in flight.
    var id: String = UUID().uuidString
    var text: String
    var time: String
    var fromMe: Bool
    var status: MessageStatus = .read
    var kind: MessageKind = .text
    var reaction: String? = nil
    var replyToText: String? = nil
    var replyToMe: Bool = false
    var voiceDuration: String? = nil     // e.g. "0:12"
    var voiceSeconds: Int? = nil         // integer duration used by the player
    var imageName: String? = nil
    /// Set only when `kind == .location`. Coordinates parsed from the
    /// message text (a Google Maps URL) and reused to open the native map app.
    var locationLat: Double? = nil
    var locationLng: Double? = nil
    var day: String = "Aujourd'hui"      // date-separator label
    /// Set only when `kind == .visit`. Snapshot of the visit transition; the
    /// current status may have moved on server-side.
    var visitId: String? = nil
    var visitAction: String? = nil       // REQUESTED / CONFIRMED / CANCELLED / COMPLETED / NO_SHOW / RESCHEDULED
    /// True when the CURRENT user sent this message. Distinct from `fromMe`
    /// on `ChatMessage` because SYSTEM messages track who *originated* the
    /// visit transition — the "other party" is the one who acts on the card.
    var visitIsMine: Bool = false

    static func == (a: ChatMessage, b: ChatMessage) -> Bool { a.id == b.id }
}

enum ChatConstants {
    /// Suggestions depend on which side of the conversation you're on.
    /// An owner being offered "Est-ce toujours disponible ?" as a reply to
    /// someone asking exactly that is nonsense — they need answers, not
    /// questions.
    static let visitorReplies = [
        "Est-ce toujours disponible ?",
        "Je peux visiter ce week-end ?",
        "Quel est le prix total ?",
        "L'eau et l'électricité sont incluses ?",
    ]

    static let ownerReplies = [
        "Oui, c'est toujours disponible.",
        "Quand souhaitez-vous visiter ?",
        "Le prix est négociable.",
        "Oui, l'eau et l'électricité sont incluses.",
        "Je vous envoie plus de photos.",
    ]

    /// Kept for anything still referring to the old name.
    static let quickReplies = visitorReplies
    static let reactions = ["❤️", "👍", "😂", "😮", "😢", "🙏"]
}

/// No seeded conversations. A new account starts with an empty inbox — demo
/// threads here would show every user someone else's messages, which is what
/// they looked like before this was wired to the server.
enum ChatData {
    static let threads: [ChatThread] = []
    static let sampleMessages: [ChatMessage] = []
}

extension ChatThread {
    /// Placeholder for SwiftUI previews and debug routes only — never shown to
    /// a real user, since every list now comes from the server.
    static let preview = ChatThread(
        id: "preview-thread", initial: "M", color: .moblyPrimary,
        name: "Aperçu", verified: false, online: false, time: "",
        listing: "", listingTitle: "", listingPrice: "", listingImage: "ListingGreen",
        preview: "", unread: 0, fromMe: false
    )
}
