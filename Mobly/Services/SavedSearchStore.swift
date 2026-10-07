import Foundation
import Combine

/// A search the user chose to remember (from the Explore filter panel or
/// Search results). Local-only until the backend grows `/me/searches`.
struct SavedSearchItem: Identifiable, Codable, Equatable {
    let id: String
    var label: String
    var query: String
    var filters: FilterState
    var createdAt: Date
    /// Set when the user picked a specific space rather than searching a
    /// place or a phrase: tapping the recent search opens that space again
    /// instead of re-running its title as a map search. Optional, so lists
    /// saved before this existed still decode.
    var listingId: String?
    /// "Akwa, Douala" for a space — the row's second line.
    var listingLocation: String?

    init(label: String, query: String, filters: FilterState,
         id: String = UUID().uuidString, createdAt: Date = Date(),
         listingId: String? = nil, listingLocation: String? = nil) {
        self.id = id
        self.label = label
        self.query = query
        self.filters = filters
        self.createdAt = createdAt
        self.listingId = listingId
        self.listingLocation = listingLocation
    }
}

/// Persistent list of saved searches. Backed by UserDefaults today; when the
/// backend adds `/me/searches`, swap the load/save paths without touching
/// any of the callers.
@MainActor
final class SavedSearchStore: ObservableObject {
    static let shared = SavedSearchStore()
    @Published private(set) var items: [SavedSearchItem] = []
    private let key = "savedSearches.v1"

    private init() { load() }

    var count: Int { items.count }

    func add(label: String, query: String, filters: FilterState) {
        guard RemoteConfigStore.shared.isEnabled("search.savedSearches") else { return }
        // Dedup by (label + filters) — a user tapping "Save" twice on the
        // same set should not accumulate duplicates.
        if items.contains(where: { $0.label == label && $0.filters == filters }) { return }
        items.insert(SavedSearchItem(label: label, query: query, filters: filters), at: 0)
        persist()
    }

    /// Remember a space the user opened from search. One entry per space,
    /// moved back to the top when it's opened again.
    func addListing(_ listing: Listing) {
        guard RemoteConfigStore.shared.isEnabled("search.savedSearches") else { return }
        let title = listing.title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Also drop the plain-text entry older builds saved for this same
        // space (its title, trimmed), so it doesn't sit there as a duplicate
        // that still runs a map search.
        items.removeAll {
            $0.listingId == listing.id
                || ($0.listingId == nil
                    && $0.label.trimmingCharacters(in: .whitespacesAndNewlines)
                        .caseInsensitiveCompare(title) == .orderedSame)
        }
        items.insert(SavedSearchItem(label: title, query: title, filters: FilterState(),
                                     listingId: listing.id, listingLocation: listing.location), at: 0)
        persist()
    }

    /// The space behind a "recent search" entry: from the loaded feed when
    /// it's there, otherwise fetched — it may sit beyond the first page.
    /// Nil when it no longer exists.
    func listing(for item: SavedSearchItem) async -> Listing? {
        guard let id = item.listingId else { return nil }
        if let l = MoblyData.all.first(where: { $0.id == id }) { return l }
        return try? await MoblyAPI.shared.listing(id: id).asListing
    }

    func remove(_ item: SavedSearchItem) {
        items.removeAll { $0.id == item.id }
        persist()
    }

    func clear() {
        items = []
        persist()
    }

    // MARK: Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let arr = try? dec.decode([SavedSearchItem].self, from: data) { items = arr }
    }

    private func persist() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(items) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

extension SavedSearchItem {
    /// Human summary of what this search looks for — shown on the row.
    var subtitle: String {
        if listingId != nil { return listingLocation ?? "Espace" }
        var bits: [String] = []
        if !filters.propertyTypes.isEmpty {
            bits.append(filters.propertyTypes.sorted().joined(separator: " · "))
        }
        if !filters.regions.isEmpty {
            bits.append(filters.regions.sorted().joined(separator: " · "))
        }
        if !filters.activities.isEmpty {
            bits.append(filters.activities.sorted().joined(separator: " · "))
        }
        if filters.priceBucket != "Toutes" && !filters.priceBucket.isEmpty {
            bits.append(filters.priceBucket + " FCFA")
        } else if !filters.minPrice.isEmpty || !filters.maxPrice.isEmpty {
            let range = "\(filters.minPrice.isEmpty ? "0" : filters.minPrice) – \(filters.maxPrice.isEmpty ? "∞" : filters.maxPrice) FCFA"
            bits.append(range)
        }
        if bits.isEmpty { return query.isEmpty ? "Toutes les annonces" : query }
        return bits.joined(separator: " · ")
    }
}
