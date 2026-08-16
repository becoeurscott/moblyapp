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

    init(label: String, query: String, filters: FilterState,
         id: String = UUID().uuidString, createdAt: Date = Date()) {
        self.id = id
        self.label = label
        self.query = query
        self.filters = filters
        self.createdAt = createdAt
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
        // Dedup by (label + filters) — a user tapping "Save" twice on the
        // same set should not accumulate duplicates.
        if items.contains(where: { $0.label == label && $0.filters == filters }) { return }
        items.insert(SavedSearchItem(label: label, query: query, filters: filters), at: 0)
        persist()
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
