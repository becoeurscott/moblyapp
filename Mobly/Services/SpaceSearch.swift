import Foundation

/// The one search behind both search bars — Accueil and Explorer.
///
/// They used to search different things: Explorer matched space names
/// ("kina" → Kina coworking) and Mobly's cities, while Accueil only matched
/// quartiers and, on Entrée, sent whatever was typed to the map as an address —
/// so "Bliss Home" from Accueil landed on a shop in Indiana. Everything here is
/// accent- and case-insensitive.
@MainActor
enum SpaceSearch {

    static func fold(_ s: String) -> String {
        s.folding(options: .diacriticInsensitive, locale: .current).lowercased()
    }

    private static func commonPrefixLen(_ a: String, _ b: String) -> Int {
        zip(a, b).prefix(while: { $0 == $1 }).count
    }

    /// Spaces whose name matches, from the first letters: "kin" finds
    /// "Kinimo Résidence". A match on the start of the title or of any word in
    /// it ranks above one buried in the middle.
    static func spaces(_ query: String, limit: Int = 5) -> [Listing] {
        let q = fold(query.trimmingCharacters(in: .whitespaces))
        guard q.count >= 2 else { return [] }
        func rank(_ l: Listing) -> Int? {
            let t = fold(l.title)
            if t.hasPrefix(q) { return 0 }
            if t.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return 1 }
            if t.contains(q) { return 2 }
            return nil
        }
        return MoblyData.all
            .compactMap { l in rank(l).map { ($0, l) } }
            .sorted { $0.0 < $1.0 }
            .prefix(limit)
            .map { $0.1 }
    }

    /// Cities and quartiers Mobly knows: the curated list first (loose match,
    /// so "yaound" still finds Yaoundé), then every quartier by prefix
    /// ("akw" → Akwa, Douala). Cities carry the region "Cameroun".
    static func places(_ query: String, limit: Int = 6) -> [(name: String, region: String)] {
        let q = fold(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return [] }
        var out: [(name: String, region: String)] = []
        var seen = Set<String>()
        func add(_ name: String, _ region: String) {
            guard seen.insert(fold(name)).inserted else { return }
            out.append((name, region))
        }
        // Ranked: the place itself ("dou" → Douala) before places that are
        // merely *in* it (Akwa, Douala), which used to come first.
        var ranked: [(rank: Int, loc: (name: String, region: String))] = []
        for loc in MoblyData.searchableLocations {
            let name = fold(loc.name)
            let rank: Int?
            if name.hasPrefix(q) { rank = 0 }
            else if name.contains(q) || q.contains(name) || commonPrefixLen(name, q) >= 4 { rank = 1 }
            else if fold(loc.region).contains(q) { rank = 2 }
            else { rank = nil }
            if let rank { ranked.append((rank, loc)) }
        }
        for r in ranked.enumerated().sorted(by: { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }) {
            add(r.element.loc.name, r.element.loc.region)
        }
        for (city, list) in CameroonGeo.quartiers.sorted(by: { $0.key < $1.key }) {
            if fold(city).hasPrefix(q) { add(city, "Cameroun") }
            for qt in list where fold(qt).hasPrefix(q) { add(qt, city) }
        }
        return Array(out.prefix(limit))
    }

    /// What pressing Entrée means for a typed query.
    enum Resolution {
        /// A place Mobly knows — frame the map on it.
        case place(String)
        /// Spaces whose name matched — show them all and let the user pick.
        case spaces([Listing])
        /// Nothing of ours matched — let the map geocode it as an address.
        case address(String)
    }

    /// Exact city first (so "Douala" never turns into "Douala Grand Mall"),
    /// then space names, then a loose city match, then a plain address.
    static func resolve(_ query: String) -> Resolution {
        let q = query.trimmingCharacters(in: .whitespaces)
        let folded = fold(q)
        if let city = MoblyData.searchableLocations.first(where: { fold($0.name) == folded }) {
            return .place("\(city.name), \(city.region)")
        }
        let matches = spaces(q, limit: 50)
        if !matches.isEmpty { return .spaces(matches) }
        if let loose = MoblyData.searchableLocations.first(where: {
            let name = fold($0.name)
            return name.contains(folded) || folded.contains(name) || commonPrefixLen(name, folded) >= 4
        }) {
            return .place("\(loose.name), \(loose.region)")
        }
        return .address(q)
    }
}
