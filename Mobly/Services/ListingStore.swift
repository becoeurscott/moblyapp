import Foundation
import Combine

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
        Task { await fetch() }
    }

    // MARK: - Public

    func fetch(city: String? = nil, category: String? = nil) async {
        isLoading = true
        isOffline = false
        lastError = nil
        do {
            let dtos = try await MoblyAPI.shared.searchListings(category: category, city: city)
            listings = dtos.map { $0.asListing }
            saveCached(dtos)
            prefetchCovers(for: listings)
        } catch let apiError as MoblyAPI.APIError {
            // Whatever the cache gave us stays on screen; only the banner changes.
            if apiError.isOffline {
                isOffline = true
            } else {
                lastError = apiError.message
            }
        } catch {
            lastError = "Impossible de charger les annonces."
        }
        isLoading = false
    }

    /// Pull-to-refresh / retry entry point.
    func refresh() async { await fetch() }

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
        if let r = rating { ratingStr = String(format: "%.1f", min(5.0, r)) }
        else { ratingStr = "4.5" }

        return Listing(
            id: id,
            title: title,
            location: location,
            price: price,
            rating: ratingStr,
            imageName: imageName ?? "ListingGreen",
            coverUrl: coverUrl,
            photos: photos ?? [],
            ownerName: owner?.fullName,
            ownerVerified: owner?.verified ?? false,
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
