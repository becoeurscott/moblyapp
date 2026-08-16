import Foundation

struct Listing: Identifiable, Hashable {
    let id: String
    var title: String
    var location: String
    var price: String          // e.g. "80 000 FCFA"
    var rating: String         // e.g. "4.8"
    var imageName: String      // asset name (fallback / bundled sample)
    /// Remote URL cover (Airbnb CDN or Cloudinary). Rendered before `imageName`.
    var coverUrl: String? = nil
    /// All photos (remote URLs) shown in the detail gallery.
    var photos: [String] = []
    /// Owner's display name, from the server. Nil for locally-built listings.
    var ownerName: String? = nil
    var ownerVerified: Bool = false
    /// Owner-uploaded cover photo. When set, UI renders this instead of `imageName`.
    /// Data is Hashable so `Listing` keeps its synthesized conformances.
    var customImageData: Data? = nil
    /// All owner-uploaded photos, in the order the owner arranged them (index
    /// 0 = cover). Empty for imported/remote listings, which use `photos`
    /// (remote URLs) for the gallery. Kept in-app-only for now — a proper
    /// upload pipeline to Cloudinary happens later.
    var customPhotos: [Data] = []
    var category: String       // "Chambres" | "Appartements" | "Bureaux" | "Boutiques"
    var subtitle: String = ""  // e.g. "Meublé · 2 chambres"
    var about: String = ""     // owner's free-text description of the space
    var verified: Bool = true
    /// Owner marked this space "disponible" or not. The public feed already
    /// excludes unavailable listings server-side, but a user can still reach
    /// one through an existing conversation or a direct link — those surfaces
    /// must say so rather than letting someone chase a space that's gone.
    var available: Bool = true
    var boosted: Bool = false
    var tags: [String] = ["Meublé", "Wifi", "Parking"]
    var reviewCount: Int = 128
    /// Transaction / furnishing filters this listing matches
    /// (e.g. "À louer", "Acheter", "Meublé", "Non meublé", "Court séjour").
    var deals: [String] = ["À louer", "Meublé"]
    /// Category-specific room/feature details shown on the detail page.
    var features: [String: String] = [:]
    /// Precise map position. Set by the location-pin picker in the publish
    /// wizard; nil when the owner never pinned one (older listings, or ones
    /// imported from the Airbnb dataset where we discarded coordinates).
    var lat: Double? = nil
    var lng: Double? = nil

    /// Suffix shown after the price: "/jour" for court séjour, "/mois" for
    /// long-term rentals, empty for sales.
    var priceUnit: String {
        if deals.contains("Acheter") { return "" }
        return deals.contains("Court séjour") ? "/jour" : "/mois"
    }
}

struct Neighborhood: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let region: String
    let imageName: String
}

struct QuickFilter: Identifiable, Hashable {
    let id = UUID()
    let label: String
    let icon: String
}

struct CategoryItem: Identifiable, Hashable {
    let id = UUID()
    let label: String
    let icon: String
    let tint: UInt32
}

enum MoblyData {
    static let filterChips = ["Tous", "Chambres", "Studios", "Appartements", "Villas",
                              "Bureaux", "Boutiques", "Coworking", "Commercial"]

    /// Locations proposed in the Explore search autocomplete.
    static let searchableLocations: [(name: String, region: String)] = [
        ("Akwa", "Douala"), ("Bonapriso", "Douala"), ("Bonanjo", "Douala"),
        ("Bali", "Douala"), ("Deido", "Douala"), ("Bonamoussadi", "Douala"),
        ("Makepe", "Douala"), ("Douala", "Cameroun"),
        ("Bastos", "Yaoundé"), ("Mvan", "Yaoundé"), ("Bonas", "Yaoundé"),
        ("Yaoundé", "Cameroun"),
        ("Kribi", "Sud"), ("Buéa", "Sud-Ouest"), ("Bafoussam", "Ouest"),
        ("Limbé", "Sud-Ouest"),
    ]

    static let popular: [Neighborhood] = [
        Neighborhood(name: "Douala",    region: "Cameroun", imageName: "CityDouala"),
        Neighborhood(name: "Yaoundé",   region: "Cameroun", imageName: "CityYaounde"),
        Neighborhood(name: "Buéa",      region: "Cameroun", imageName: "CityBuea"),
        Neighborhood(name: "Bamenda",   region: "Cameroun", imageName: "CityBamenda"),
        Neighborhood(name: "Kribi",     region: "Cameroun", imageName: "CityKribi"),
        Neighborhood(name: "Garoua",    region: "Cameroun", imageName: "CityGaroua"),
        Neighborhood(name: "Bafoussam", region: "Cameroun", imageName: "CityBafoussam"),
    ]

    static let quickFilters: [QuickFilter] = [
        QuickFilter(label: "À louer", icon: "key.fill"),
        QuickFilter(label: "Meublé", icon: "sofa.fill"),
        QuickFilter(label: "Non meublé", icon: "cube.box"),
        QuickFilter(label: "Court séjour", icon: "calendar"),
    ]

    static let recommended: [Listing] = []

    static let categories: [CategoryItem] = [
        CategoryItem(label: "Chambres", icon: "bed.double.fill", tint: 0xEAF6EF),
        CategoryItem(label: "Studios", icon: "square.split.bottomrightquarter.fill", tint: 0xFFF1EA),
        CategoryItem(label: "Appartements", icon: "building.2.fill", tint: 0xF3EEFB),
        CategoryItem(label: "Villas", icon: "house.fill", tint: 0xEEF0FE),
        CategoryItem(label: "Bureaux", icon: "building.2.fill", tint: 0xFFF1EA),
        CategoryItem(label: "Boutiques", icon: "bag.fill", tint: 0xF3EEFB),
        CategoryItem(label: "Coworking", icon: "person.3.fill", tint: 0xEAF6EF),
        CategoryItem(label: "Commercial", icon: "storefront.fill", tint: 0xFFF1EA),
    ]

    static let nearby: [Listing] = []

    /// All listings — served live from the backend via ListingStore, with any
    /// annonces the current user just published (session-only, no server round
    /// trip yet) prepended so they appear immediately on Explore/Home.
    /// Views that read this must observe **both** `ListingStore.shared` and
    /// `OwnerListings.shared` to re-render when either changes.
    @MainActor
    static var all: [Listing] {
        // Only surface the owner's OWN annonces that are marked disponible —
        // "Rendre indisponible" is expected to pull the listing off the map,
        // home feed and search results, matching what the server does.
        let mine = OwnerListings.shared.annonces
            .filter { $0.available }
            .map(\.listing)
        let server = ListingStore.shared.listings
        let seen = Set(mine.map(\.id))
        return mine + server.filter { !seen.contains($0.id) }
    }

    /// Transaction / furnishing chips used by search + home quick filters.
    /// "Acheter" is intentionally omitted: Mobly is a rental marketplace for
    /// the pilot, and a chip that never matches anything reads as broken.
    static let searchCategories = ["Tous", "À louer",
                                   "Meublé", "Non meublé", "Court séjour"]

    /// Map a property-type label to a canonical listing category.
    static func canonicalCategory(_ label: String) -> String {
        let map: [String: String] = [
            "Studio": "Studios", "Studios": "Studios",
            "Appartement": "Appartements", "Appartements": "Appartements",
            "Chambre": "Chambres", "Chambres": "Chambres",
            "Bureau": "Bureaux", "Bureaux": "Bureaux",
            "Boutique": "Boutiques", "Boutiques": "Boutiques",
            "Villa": "Villas", "Villas": "Villas", "Maison": "Villas",
            "Coworking": "Coworking",
            "Hôtel": "Hôtel", "Hotel": "Hôtel",
            "Commercial": "Commercial",
        ]
        return map[label] ?? label
    }

    /// Filter the full list by a transaction/furnishing label
    /// (nil / "Tous" = all). A listing matches if the label is in its `deals`.
    /// STRICT: an empty result stays empty — the caller is expected to show a
    /// "no matches" state rather than falling back to the full list, which
    /// would make the chip look like it does nothing.
    @MainActor
    static func results(for category: String?) -> [Listing] {
        guard let category, category != "Tous", !category.isEmpty else { return all }
        return all.filter { $0.deals.contains(category) }
    }
}
