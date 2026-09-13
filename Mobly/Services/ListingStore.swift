import Foundation
import Combine
import SwiftUI

/// Fetches listings from the backend and caches them so a relaunch paints
/// instantly. Surfaces load/offline/error state for the UI to render.
@MainActor
final class ListingStore: ObservableObject {
    static let shared = ListingStore()

    @Published private(set) var listings: [Listing] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isOffline = false
    /// Non-nil when the last fetch failed for a reason that isn't connectivity.
    /// Kept separate from `isOffline` so the UI doesn't tell someone to check
    /// their network when the real problem is a 500.
    @Published private(set) var lastError: String?

    private let cacheKey = "cachedListingDTOs_v2"

    init() {
        loadCached()
        // First launch paints from cache, so even this one can be silent when
        // the cache had something to show.
        let hadCache = !listings.isEmpty
        Task { await fetch(silent: hadCache) }
    }

    // MARK: - Public

    /// - Parameter silent: a background refresh nobody asked for. It never
    ///   raises `isLoading` and never replaces a good screen with an error
    ///   banner, so the UI shows no sign a fetch happened — the data just
    ///   becomes current. Only user-initiated loads (first launch,
    ///   pull-to-refresh, retry) pass `false`.
    func fetch(city: String? = nil, category: String? = nil, silent: Bool = false) async {
        if !silent {
            isLoading = true
            isOffline = false
            lastError = nil
        }
        do {
            let dtos = try await MoblyAPI.shared.searchListings(category: category, city: city)
            let fresh = dtos.map { $0.asListing }
            // Assigning an identical array would still publish and rebuild
            // every card — on a 30s poll that is a visible hitch for nothing.
            if fresh != listings {
                withAnimation(Motion.content) { listings = fresh }
                saveCached(dtos)
                prefetchCovers(for: fresh)
            }
            if silent {
                // A silent success clears a stale banner from an earlier failure.
                if isOffline { isOffline = false }
                if lastError != nil { lastError = nil }
            }
        } catch let apiError as MoblyAPI.APIError {
            // Whatever the cache gave us stays on screen; only the banner changes.
            // A silent poll failing is not news — the user asked for nothing, so
            // they get told nothing and the next tick tries again.
            if !silent && !apiError.isCancelled {
                if apiError.isOffline {
                    isOffline = true
                } else {
                    lastError = apiError.message
                }
            }
        } catch {
            if !silent { lastError = "Impossible de charger les annonces." }
        }
        if !silent { isLoading = false }
    }

    /// Pull-to-refresh / retry entry point — the one place a spinner is
    /// legitimate, because the user pulled it themselves.
    func refresh() async { await fetch() }

    /// Background poll. See `fetch(silent:)`.
    func refreshSilently() async { await fetch(silent: true) }

    // MARK: - Prefetch

    /// Warm URLCache with the covers the user is about to scroll past, so the
    /// first screens paint from disk instead of the network. Limited to the
    /// visible-ish window — prefetching all 126 would waste a data plan.
    private func prefetchCovers(for listings: [Listing]) {
        let covers = listings.prefix(24).compactMap { $0.coverUrl }
        ImagePrefetch.warm(covers, width: ImageSlot.hero)
    }

    /// Call when the user taps a listing card — warms the gallery photos during
    /// the 300ms present animation so the detail screen opens without shimmers.
    func prefetchGallery(for listing: Listing) {
        ImagePrefetch.warm(listing.photos, width: ImageSlot.hero)
    }

    // MARK: - Cache

    private func loadCached() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let dtos = try? JSONDecoder().decode([ListingDTO].self, from: data)
        else { return }
        listings = dtos.map { $0.asListing }
    }

    private func saveCached(_ dtos: [ListingDTO]) {
        guard let data = try? JSONEncoder().encode(dtos) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }
}

// MARK: - DTO → Listing mapping

extension ListingDTO {
    /// Bookkeeping tags the backend uses but users must never see. The import
    /// script needs `airbnb-import` on the row to stay idempotent, so it's
    /// stripped here rather than in the DB.
    static let internalTags: Set<String> = ["airbnb-import"]

    var asListing: Listing {
        let ratingStr: String
        if let r = rating, reviewCount > 0 { ratingStr = String(format: "%.1f", min(5.0, r)) }
        else { ratingStr = "" }

        return Listing(
            id: id,
            title: title,
            location: location,
            price: price,
            rating: ratingStr,
            imageName: imageName ?? "ListingGreen",
            coverUrl: coverUrl,
            photos: photos ?? [],
            ownerId: owner?.id,
            ownerName: owner?.fullName,
            // "Propriétaire vérifié" reflects the identity/KYC check, matching
            // the owner's own profile badge — not merely a confirmed phone.
            ownerVerified: owner?.identityVerified ?? false,
            category: category,
            subtitle: subtitle,
            about: about,
            verified: verified,
            available: available,
            boosted: boosted,
            tags: tags.filter { !Self.internalTags.contains($0) },
            reviewCount: reviewCount,
            deals: deals,
            lat: lat,
            lng: lng
        )
    }
}
