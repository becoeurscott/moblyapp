import Foundation
import Combine
import SwiftUI

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
        // Paint the owner dashboard from the last known annonces before the
        // network is consulted. Without this `myListings` began every launch
        // empty, so the dashboard showed nothing at all until /listings/mine
        // returned — a wait the owner reads as the app losing their property.
        loadFromDisk()
        NotificationCenter.default.addObserver(
            forName: MoblyAPI.sessionExpired, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.clear() }
        }
    }

    // MARK: Disk cache

    /// Scoped to the signed-in user id: on a shared handset — common in this
    /// market — an unscoped file would show the previous owner's annonces to
    /// whoever signs in next, before the network could correct it.
    private var cacheURL: URL? {
        guard let uid = Session.shared.userId else { return nil }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("owner-listings-\(uid).json")
    }

    private func saveToDisk() {
        guard let url = cacheURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(myListings) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func loadFromDisk() {
        guard let url = cacheURL, let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let cached = try? decoder.decode([ListingDTO].self, from: data) else { return }
        myListings = cached
    }

    /// Drop the file too — `clear()` runs on sign-out, and a cache that
    /// outlived the session would hand the next user the previous one's
    /// annonces on the very first frame.
    private func clearDisk() {
        guard let url = cacheURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Wipe everything. Called on sign-out so the next person on this device
    /// doesn't inherit the previous user's data.
    func clear() {
        favorites = []
        favoriteIds = []
        notifications = []
        unreadNotifications = 0
        myListings = []
        clearDisk()
    }

    func loadAll(silent: Bool = false) async {
        guard api.isAuthenticated else { return clear() }
        async let f: Void = loadFavorites(silent: silent)
        async let n: Void = loadNotifications()
        _ = await (f, n)
    }

    // MARK: - Favourites

    /// `silent` = a background poll: no spinner, no offline banner, and the
    /// list only re-publishes when it actually changed.
    func loadFavorites(silent: Bool = false) async {
        guard api.isAuthenticated else { return }
        if !silent { loadingFavorites = true }
        defer { if !silent { loadingFavorites = false } }
        do {
            let dtos = try await api.favorites()
            let fresh = dtos.map { $0.asListing }
            let ids = Set(dtos.map(\.id))
            if fresh != favorites || ids != favoriteIds {
                withAnimation(Motion.content) {
                    favorites = fresh
                    favoriteIds = ids
                }
            }
            isOffline = false
        } catch let e as MoblyAPI.APIError {
            if e.isOffline && !silent { isOffline = true }
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

    /// A notification pushed over the socket. Prepended in place so the bell
    /// and the list update the moment it is raised — previously the row only
    /// appeared once something re-fetched `GET /notifications`, which is why an
    /// admin broadcast looked like it had done nothing until a pull-to-refresh.
    func receive(_ n: NotificationDTO) {
        guard !notifications.contains(where: { $0.id == n.id }) else { return }
        withAnimation(Motion.content) {
            notifications.insert(n, at: 0)
            if !n.read { unreadNotifications += 1 }
        }
    }

    func loadNotifications() async {
        guard api.isAuthenticated else { return }
        do {
            struct Wrap: Decodable { let items: [NotificationDTO] }
            let w: Wrap = try await api.request("notifications", authorized: true)
            let unread = w.items.filter { !$0.read }.count
            // Only animate when something really arrived — a poll that returns
            // the same list must leave the screen untouched.
            if w.items.map(\.id) != notifications.map(\.id) || unread != unreadNotifications {
                withAnimation(Motion.content) {
                    notifications = w.items
                    unreadNotifications = unread
                }
            }
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
            let fresh = try await api.myAnnonces()
            if fresh.map(\.id) != myListings.map(\.id) {
                withAnimation(Motion.content) { myListings = fresh }
            } else {
                myListings = fresh
            }
            saveToDisk()
        } catch {
            // Keep whatever is already on screen. A failed refresh must not
            // empty a dashboard that is showing perfectly good cached annonces.
        }
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
    /// Deep-link target the server attaches (`listingId`, `threadId`,
    /// `visitId`…). The column has existed since the table was created and is
    /// documented as "deep-link target", but the client never decoded it — so
    /// every notification was a dead end that went nowhere when tapped.
    let payload: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id, title, body, type, read, createdAt, payload
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        body = try c.decodeIfPresent(String.self, forKey: .body)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        read = try c.decode(Bool.self, forKey: .read)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        // Payload values are ids, but a stray number or bool must not fail the
        // whole notification — coerce what we can and drop the rest.
        payload = (try? c.decode([String: LooseString].self, forKey: .payload))
            .map { $0.compactMapValues(\.value) }
    }

    /// Accepts a string, number or bool and yields a string.
    struct LooseString: Decodable {
        let value: String?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { value = s }
            else if let i = try? c.decode(Int.self) { value = String(i) }
            else if let d = try? c.decode(Double.self) { value = String(d) }
            else if let b = try? c.decode(Bool.self) { value = String(b) }
            else { value = nil }
        }
    }
}
