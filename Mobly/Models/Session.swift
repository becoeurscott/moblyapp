import SwiftUI

/// App-wide signed-in user state. Persists across launches via UserDefaults.
/// `isOwner` gates the whole host/owner surface: a visitor sees the
/// "Devenir propriétaire" upsell, an owner sees their dashboard + listing flow.
final class Session: ObservableObject {
    static let shared = Session()

    /// Whether the current account can publish spaces. Set at signup (role
    /// picker) or when a visitor upgrades via BecomeOwnerView.
    @Published var isOwner: Bool = UserDefaults.standard.bool(forKey: "isOwner") {
        didSet { UserDefaults.standard.set(isOwner, forKey: "isOwner") }
    }

    /// Display name captured at signup (falls back to a placeholder).
    @Published var fullName: String = UserDefaults.standard.string(forKey: "userFullName") ?? "" {
        didSet { UserDefaults.standard.set(fullName, forKey: "userFullName") }
    }

    @Published var phone: String = UserDefaults.standard.string(forKey: "userPhone") ?? "" {
        didSet { UserDefaults.standard.set(phone, forKey: "userPhone") }
    }

    /// Server-side user id. Non-sensitive (the token is what grants access), so
    /// UserDefaults is fine here — unlike the token, which lives in the Keychain.
    @Published var userId: String? = UserDefaults.standard.string(forKey: "userId") {
        didSet { UserDefaults.standard.set(userId, forKey: "userId") }
    }

    var firstName: String {
        fullName.split(separator: " ").first.map(String.init) ?? fullName
    }

    private init() {
        // Debug hook: START_AT flows can force owner mode for screenshotting.
        if ProcessInfo.processInfo.environment["AS_OWNER"] == "1" { isOwner = true }
    }

    /// Called from auth on successful signup/signin.
    func signIn(fullName: String?, phone: String?, isOwner: Bool) {
        if let n = fullName, !n.trimmingCharacters(in: .whitespaces).isEmpty { self.fullName = n }
        if let p = phone, !p.trimmingCharacters(in: .whitespaces).isEmpty { self.phone = p }
        self.isOwner = isOwner
    }

    /// Visitor upgrading to owner in-app.
    func upgradeToOwner() { isOwner = true }

    /// Clear local identity after sign-out or an expired session.
    /// Tokens are cleared separately by `MoblyAPI` — this is only the
    /// UserDefaults-backed display state.
    func signOutLocal() {
        fullName = ""
        phone = ""
        userId = nil
        isOwner = false
    }
}

/// Publication state of an owner's space.
enum AnnonceStatus: Hashable {
    /// `inactive` covers PAUSED / REJECTED / ARCHIVED / DRAFT. Without it the
    /// mapping fell through to `.active`, so a listing an admin had rejected
    /// or archived was counted and shown under "Actives".
    case active, boosted, pending, inactive
    var label: String {
        switch self {
        case .active:   return "ACTIVE"
        case .boosted:  return "BOOSTÉE"
        case .pending:  return "EN ATTENTE"
        case .inactive: return "INACTIVE"
        }
    }
}

/// An owner's published space plus its performance metrics. Wraps a `Listing`
/// so it renders anywhere a listing does, while carrying host-only data.
struct OwnerAnnonce: Identifiable, Hashable {
    var listing: Listing
    var views: Int
    var contacts: Int
    var favorites: Int
    var available: Bool = true
    var boostDaysLeft: Int? = nil          // non-nil ⇒ boosted
    var status: AnnonceStatus = .active

    var id: String { listing.id }
    var isBoosted: Bool { boostDaysLeft != nil }
    /// Contact rate = contacts / views.
    var contactRate: Double { views > 0 ? Double(contacts) / Double(views) : 0 }
}

/// In-memory store of the spaces this owner has published. Seeded with demo
/// annonces so the dashboard has content; newly published spaces prepend as
/// "en attente" (pending review). No backend — session-only.
final class OwnerListings: ObservableObject {
    static let shared = OwnerListings()
    @Published var annonces: [OwnerAnnonce] = []
    private init() {}

    /// Load the owner's own listings from the server.
    ///
    /// This used to seed the dashboard from the first three *public* listings
    /// with invented view/contact counts — so every owner opened it to find
    /// someone else's properties presented as their own, with fabricated
    /// performance numbers attached.
    @MainActor
    func load(from dtos: [ListingDTO]) {
        annonces = dtos.map { dto in
            OwnerAnnonce(
                listing: dto.asListing,
                views: dto.views,
                contacts: dto.contacts,
                favorites: dto.favorites,
                available: dto.available,
                boostDaysLeft: dto.boostDaysLeft,
                status: Self.status(from: dto.status)
            )
        }
    }

    /// Explicit mapping — never fall through to `.active`, or every state the
    /// server invents in future silently becomes "active" on the dashboard.
    private static func status(from raw: String) -> AnnonceStatus {
        switch raw {
        case "BOOSTED":                            return .boosted
        case "PENDING", "DRAFT":                   return .pending
        case "PAUSED", "REJECTED", "ARCHIVED":     return .inactive
        default:                                   return .active
        }
    }

    func add(_ listing: Listing) {
        annonces.insert(
            OwnerAnnonce(listing: listing, views: 0, contacts: 0, favorites: 0,
                         available: true, boostDaysLeft: nil, status: .pending),
            at: 0
        )
    }

    func remove(_ annonce: OwnerAnnonce) {
        annonces.removeAll { $0.id == annonce.id }
        // Free the on-disk photos this listing owned. Safe to call even for
        // remote/imported listings — those write nothing to Caches.
        OwnerPhotoStore.clear(id: annonce.listing.id)
    }

    /// Replace an annonce's listing content (from the edit flow), keeping its
    /// metrics, availability and boost/status intact.
    func update(_ listing: Listing, for id: String) {
        guard let i = annonces.firstIndex(where: { $0.id == id }) else { return }
        annonces[i].listing = listing
    }

    /// PATCH the annonce on the server + update the local row + refresh the
    /// public listing store. Returns true on success. Fires the edit path
    /// used by the single-page manager screen so any field-level change
    /// (Meublé → Non meublé, price, description…) reaches every surface.
    @MainActor
    @discardableResult
    func updateOnServer(_ listing: Listing) async -> Bool {
        let body = MoblyAPI.CreateListingBody(
            title: listing.title,
            category: listing.category,
            deal: listing.deals.contains("Acheter") ? "SALE" : "RENT",
            region: nil,
            city: listing.location.split(separator: ",").last.map {
                String($0).trimmingCharacters(in: .whitespaces)
            } ?? listing.location,
            neighborhood: listing.location.contains(",")
                ? listing.location.split(separator: ",").first.map {
                    String($0).trimmingCharacters(in: .whitespaces)
                }
                : nil,
            priceFcfa: Int(listing.price.filter(\.isNumber)) ?? 0,
            furnished: !listing.deals.contains("Non meublé"),
            rooms: Int(listing.features["Chambres"] ?? "") ?? 1,
            about: listing.about.isEmpty ? nil : listing.about,
            tags: listing.tags,
            coverUrl: listing.coverUrl?.hasPrefix("http") == true ? listing.coverUrl : nil,
            imageName: nil,
            photos: listing.photos.filter { $0.hasPrefix("http") },
            lat: listing.lat,
            lng: listing.lng
        )
        do {
            let dto = try await MoblyAPI.shared.updateListing(id: listing.id, body: body)
            update(dto.asListing, for: listing.id)
            await ListingStore.shared.refresh()
            return true
        } catch {
            // Keep the local edit so the owner isn't left thinking their
            // work was lost — the next successful sync re-tries.
            update(listing, for: listing.id)
            return false
        }
    }

    func toggleAvailability(_ annonce: OwnerAnnonce) {
        guard let i = annonces.firstIndex(where: { $0.id == annonce.id }) else { return }
        // Optimistic flip so the dashboard reacts instantly. The server call
        // below is what actually removes the annonce from `GET /listings`
        // (public search filters `available: true`); revert on failure so
        // the owner isn't lied to about visibility.
        annonces[i].available.toggle()
        let target = annonces[i].available
        let id = annonce.listing.id
        Task {
            do {
                _ = try await MoblyAPI.shared.setListingAvailability(id: id, available: target)
                // Refresh the public store so Home / Explore / Search drop
                // (or bring back) this annonce without a manual pull.
                await ListingStore.shared.refresh()
            } catch {
                await MainActor.run {
                    guard let j = self.annonces.firstIndex(where: { $0.id == annonce.id }) else { return }
                    self.annonces[j].available = !target
                }
            }
        }
    }

    func boost(_ annonce: OwnerAnnonce, days: Int = 30) {
        guard let i = annonces.firstIndex(where: { $0.id == annonce.id }) else { return }
        annonces[i].boostDaysLeft = days
        annonces[i].status = .boosted
    }

    // Aggregate 30-day performance across all annonces.
    var totalViews: Int { annonces.reduce(0) { $0 + $1.views } }
    var totalContacts: Int { annonces.reduce(0) { $0 + $1.contacts } }
    var totalFavorites: Int { annonces.reduce(0) { $0 + $1.favorites } }

}
