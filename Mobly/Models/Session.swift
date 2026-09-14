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

/// Where an annonce created on this device is in its trip to the server.
enum PublishState: Hashable {
    /// Photos and details are still being sent.
    case uploading
    /// The send failed; the message is shown on the card with a retry.
    case failed(String)
}

/// Result of one publish attempt, reported back to the publish sheet.
enum PublishOutcome {
    case published
    case failed(String)
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
    /// Non-nil only for an annonce published from this device that the server
    /// hasn't confirmed yet. Server-backed annonces are always nil.
    var publishState: PublishState? = nil

    var isPublishing: Bool { publishState == .uploading }

    var id: String { listing.id }
    var isBoosted: Bool { boostDaysLeft != nil }
    /// Contact rate = contacts / views.
    var contactRate: Double { views > 0 ? Double(contacts) / Double(views) : 0 }
}

/// The owner's annonces, loaded from the server. A space published from this
/// device appears at the top immediately as "Publication…" while it is sent in
/// the background, then turns into the server's row once it's accepted.
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
        // An annonce still being sent (or whose send failed) isn't on the server
        // yet, so a refresh must not wipe it off the dashboard.
        let inFlight = annonces.filter { $0.publishState != nil }
        annonces = inFlight + dtos.map { dto in
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
        guard !annonces.contains(where: { $0.id == listing.id }) else { return }
        annonces.insert(
            OwnerAnnonce(listing: listing, views: 0, contacts: 0, favorites: 0,
                         available: true, boostDaysLeft: nil, status: .pending),
            at: 0
        )
    }

    /// Clear everything — on sign-out, so a publish still running for the
    /// previous account can't land in (or post under) the next one.
    func reset() {
        annonces = []
        publishJobs = [:]
    }

    // MARK: Background publish

    /// Everything needed to send (or re-send) an annonce created on this device.
    private struct PublishJob {
        var listing: Listing
        let photos: [Data]
        /// Remote URLs from a successful photo upload, kept so a retry after a
        /// later failure doesn't upload the same photos twice.
        var uploadedURLs: [String]?
        let makeBody: (_ photos: [String], _ cover: String?) -> MoblyAPI.CreateListingBody
    }
    private var publishJobs: [String: PublishJob] = [:]

    /// Show the annonce on the dashboard right away as "Publication…" and send
    /// it in the background. The returned task finishes when the server has
    /// accepted it (the card then turns active) or the send has failed.
    @MainActor
    func startPublishing(_ listing: Listing, photos: [Data],
                         makeBody: @escaping ([String], String?) -> MoblyAPI.CreateListingBody)
        -> Task<PublishOutcome, Never>
    {
        publishJobs[listing.id] = PublishJob(listing: listing, photos: photos, uploadedURLs: nil, makeBody: makeBody)
        let placeholder = OwnerAnnonce(listing: listing, views: 0, contacts: 0, favorites: 0,
                                       available: true, boostDaysLeft: nil, status: .pending,
                                       publishState: .uploading)
        if let i = annonces.firstIndex(where: { $0.id == listing.id }) {
            annonces[i] = placeholder
        } else {
            annonces.insert(placeholder, at: 0)
        }
        return runPublish(localId: listing.id)
    }

    @MainActor
    func retryPublishing(_ id: String) {
        guard publishJobs[id] != nil, let i = annonces.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(Motion.standard) { annonces[i].publishState = .uploading }
        _ = runPublish(localId: id)
    }

    /// Drop an annonce that never reached the server.
    @MainActor
    func discardPublishing(_ id: String) {
        publishJobs[id] = nil
        withAnimation(Motion.standard) { annonces.removeAll { $0.id == id } }
        OwnerPhotoStore.clear(id: id)
    }

    @MainActor
    private func runPublish(localId: String) -> Task<PublishOutcome, Never> {
        Task { @MainActor in
            guard var job = publishJobs[localId] else { return .failed("Publication annulée.") }

            // 1) Photos → Cloudinary. The wizard requires photos, so a failed
            //    upload fails the publish (and a retry re-sends them) rather
            //    than putting an annonce online without its pictures.
            if job.uploadedURLs == nil && !job.photos.isEmpty {
                do {
                    let uploaded = try await MoblyAPI.shared.uploadOwnerPhotos(job.photos)
                    job.uploadedURLs = uploaded.map { $0.url }
                    guard publishJobs[localId] != nil else { return .failed("Publication annulée.") }
                    publishJobs[localId] = job
                    SessionTracker.shared.log("owner.photos_uploaded", ["count": uploaded.count, "listingId": localId])
                } catch {
                    SessionTracker.shared.log("owner.photos_upload_failed", ["listingId": localId])
                    return failPublishing(localId, Self.publishMessage(error, fallback: "Envoi des photos impossible. Réessayez."))
                }
            }

            // 2) The owner flag may exist locally before the server catches up;
            //    sync it first so the POST doesn't 403 OWNER_REQUIRED.
            if AuthStore.shared.user?.isOwner == false {
                _ = await AuthStore.shared.becomeOwnerOnServer()
            }
            guard publishJobs[localId] != nil else { return .failed("Publication annulée.") }

            // 3) Create the annonce. A verified owner's annonce is live at once.
            let urls = job.uploadedURLs ?? []
            do {
                let dto = try await MoblyAPI.shared.createListing(job.makeBody(urls, urls.first))
                guard publishJobs.removeValue(forKey: localId) != nil else { return .published }

                // Server id and status, local presentation details (the server
                // doesn't store the wizard's subtitle / features) and the local
                // photo bytes so the cover renders without a download.
                var listing = dto.asListing
                listing.subtitle = job.listing.subtitle
                listing.deals = job.listing.deals
                listing.features = job.listing.features
                listing.tags = job.listing.tags
                listing.rating = job.listing.rating
                listing.customImageData = job.listing.customImageData
                listing.customPhotos = job.listing.customPhotos
                if listing.photos.isEmpty { listing.photos = job.listing.photos }

                let published = OwnerAnnonce(listing: listing, views: dto.views, contacts: dto.contacts,
                                             favorites: dto.favorites, available: dto.available,
                                             boostDaysLeft: dto.boostDaysLeft,
                                             status: Self.status(from: dto.status), publishState: nil)
                withAnimation(Motion.standard) {
                    if let i = annonces.firstIndex(where: { $0.id == localId }) {
                        annonces[i] = published
                    } else {
                        annonces.insert(published, at: 0)
                    }
                }
                SessionTracker.shared.log("owner.published", ["listingId": dto.id, "status": dto.status])
                Task { await ListingStore.shared.refresh() }
                return .published
            } catch {
                SessionTracker.shared.log("owner.publish_failed", ["listingId": localId])
                return failPublishing(localId, Self.publishMessage(error, fallback: "Publication impossible. Réessayez."))
            }
        }
    }

    @MainActor
    private func failPublishing(_ id: String, _ message: String) -> PublishOutcome {
        if let i = annonces.firstIndex(where: { $0.id == id }) {
            withAnimation(Motion.standard) { annonces[i].publishState = .failed(message) }
        }
        return .failed(message)
    }

    private static func publishMessage(_ error: Error, fallback: String) -> String {
        if let e = error as? MoblyAPI.APIError {
            return e.isOffline ? "Pas de connexion. Réessayez une fois connecté." : e.message
        }
        return fallback
    }

    func remove(_ annonce: OwnerAnnonce) {
        publishJobs[annonce.id] = nil
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

    /// Awaitable variant so the calling view can show a spinner for the
    /// duration of the server round-trip. Same optimistic-flip + revert-on-
    /// failure behaviour as `toggleAvailability`, but the caller can `await`
    /// it to know when the save has actually landed.
    @MainActor
    func toggleAvailabilityAsync(_ annonce: OwnerAnnonce) async {
        guard let i = annonces.firstIndex(where: { $0.id == annonce.id }) else { return }
        withAnimation(Motion.standard) { annonces[i].available.toggle() }
        let target = annonces[i].available
        let id = annonce.listing.id
        do {
            _ = try await MoblyAPI.shared.setListingAvailability(id: id, available: target)
            await ListingStore.shared.refresh()
        } catch {
            guard let j = annonces.firstIndex(where: { $0.id == annonce.id }) else { return }
            withAnimation(Motion.standard) { annonces[j].available = !target }
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
