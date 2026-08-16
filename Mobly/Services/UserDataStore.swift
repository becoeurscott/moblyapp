import Foundation
import Combine

/// Everything that belongs to the signed-in user: favourites, notifications,
/// and the owner's own listings.
///
/// All of it starts **empty**. A new account has no favourites, no
/// notifications and no listings — seeding any of those means showing someone
/// data that isn't theirs, which is exactly what the demo arrays did.
@MainActor
final class UserDataStore: ObservableObject {
    static let shared = UserDataStore()

    // Favourites
    @Published private(set) var favorites: [Listing] = []
    @Published private(set) var favoriteIds: Set<String> = []
    @Published private(set) var loadingFavorites = false

    // Notifications
    @Published private(set) var notifications: [NotificationDTO] = []
    @Published private(set) var unreadNotifications = 0

    // Owner
    @Published private(set) var myListings: [ListingDTO] = []

    @Published private(set) var isOffline = false

    private let api = MoblyAPI.shared

    private init() {
        NotificationCenter.default.addObserver(
            forName: MoblyAPI.sessionExpired, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.clear() }
        }
    }

    /// Wipe everything. Called on sign-out so the next person on this device
    /// doesn't inherit the previous user's data.
    func clear() {
        favorites = []
        favoriteIds = []
        notifications = []
        unreadNotifications = 0
        myListings = []
    }

    func loadAll() async {
        guard api.isAuthenticated else { return clear() }
        async let f: Void = loadFavorites()
        async let n: Void = loadNotifications()
        _ = await (f, n)
    }

    // MARK: - Favourites

    func loadFavorites() async {
        guard api.isAuthenticated else { return }
        loadingFavorites = true
        defer { loadingFavorites = false }
        do {
            let dtos = try await api.favorites()
            favorites = dtos.map { $0.asListing }
            favoriteIds = Set(dtos.map(\.id))
            isOffline = false
        } catch let e as MoblyAPI.APIError {
            if e.isOffline { isOffline = true }
        } catch {}
    }

    func isFavorite(_ listingId: String) -> Bool { favoriteIds.contains(listingId) }

    /// Toggle, updating the UI first and reverting if the server disagrees —
    /// a heart that waits on a round trip feels broken on a slow connection.
    /// Returns false when the user isn't signed in, so the caller can prompt.
    @discardableResult
    func toggleFavorite(_ listing: Listing) async -> Bool {
        guard api.isAuthenticated else { return false }
        let wasFavorite = favoriteIds.contains(listing.id)

        if wasFavorite {
            favoriteIds.remove(listing.id)
            favorites.removeAll { $0.id == listing.id }
        } else {
            favoriteIds.insert(listing.id)
            favorites.insert(listing, at: 0)
        }

        do {
            if wasFavorite {
                try await api.removeFavorite(listingId: listing.id)
            } else {
                try await api.addFavorite(listingId: listing.id)
            }
        } catch {
            // Put it back — the optimistic state was wrong.
            if wasFavorite {
                favoriteIds.insert(listing.id)
                favorites.insert(listing, at: 0)
            } else {
                favoriteIds.remove(listing.id)
                favorites.removeAll { $0.id == listing.id }
            }
        }
        return true
    }

    // MARK: - Notifications

    func loadNotifications() async {
        guard api.isAuthenticated else { return }
        do {
            struct Wrap: Decodable { let items: [NotificationDTO] }
            let w: Wrap = try await api.request("notifications", authorized: true)
            notifications = w.items
            unreadNotifications = w.items.filter { !$0.read }.count
        } catch {}
    }

    func markAllNotificationsRead() async {
        unreadNotifications = 0
        notifications = notifications.map { var n = $0; n.read = true; return n }
        _ = try? await api.request("notifications/read-all", method: "POST",
                                   authorized: true) as EmptyResponse
    }

    // MARK: - Owner

    func loadMyListings() async {
        guard api.isAuthenticated else { return }
        do {
            myListings = try await api.myAnnonces()
        } catch {}
    }
}

struct NotificationDTO: Decodable, Identifiable {
    let id: String
    let title: String
    let body: String?
    /// Server field name: `type`. Kept as `kind` alias for the (older)
    /// callers that already reference it.
    let type: String?
    var kind: String? { type }
    var read: Bool
    let createdAt: Date
}
