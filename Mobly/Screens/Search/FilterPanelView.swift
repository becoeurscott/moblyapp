import SwiftUI

/// Shared filter state used by both Explore and Search.
///
/// Every field defaults to "no constraint" — an empty set / "Toutes" / empty
/// string all mean the same thing on read: don't filter by this axis.
struct FilterState: Equatable, Codable {
    var activities: Set<String> = []       // À louer, Court séjour, Meublé, Non meublé
    var propertyTypes: Set<String> = []    // Studios, Appartements, Villas, Bureaux…
    var cities: Set<String> = []           // (kept for backward-compat, no UI now)
    var regions: Set<String> = []          // Littoral, Centre, Ouest…
    var amenities: Set<String> = []        // Wifi, Parking, Climatisation…
    var priceBucket: String = "Toutes"
    var minPrice: String = ""
    var maxPrice: String = ""
    var bedrooms: String = "Toutes"
    var bathrooms: String = "Toutes"

    var isEmpty: Bool {
        activities.isEmpty && propertyTypes.isEmpty && cities.isEmpty &&
        regions.isEmpty && amenities.isEmpty &&
        priceBucket == "Toutes" && minPrice.isEmpty && maxPrice.isEmpty &&
        bedrooms == "Toutes" && bathrooms == "Toutes"
    }

    /// Number of active filters, shown as a badge on the filter button.
    var count: Int {
        var n = activities.count + propertyTypes.count + cities.count +
                regions.count + amenities.count
        if priceBucket != "Toutes" { n += 1 }
        if !minPrice.isEmpty || !maxPrice.isEmpty { n += 1 }
        if bedrooms != "Toutes" { n += 1 }
        if bathrooms != "Toutes" { n += 1 }
        return n
    }
}

/// The 10 régions of Cameroon and every city we know how to route into them.
/// Used by the Filtres panel to expose a région axis without asking the
/// backend for another lookup on every open.
enum CameroonRegion {
    static let all = [
        "Littoral", "Centre", "Ouest", "Sud-Ouest", "Nord-Ouest",
        "Sud", "Est", "Adamaoua", "Nord", "Extrême-Nord",
    ]

    private static let cityToRegion: [String: String] = [
        // Littoral
        "douala": "Littoral", "nkongsamba": "Littoral", "édéa": "Littoral",
        "loum": "Littoral", "manjo": "Littoral", "mbanga": "Littoral",
        // Centre
        "yaoundé": "Centre", "yaounde": "Centre", "mbalmayo": "Centre",
        "obala": "Centre", "bafia": "Centre", "nanga-eboko": "Centre",
        "akonolinga": "Centre",
        // Ouest
        "bafoussam": "Ouest", "dschang": "Ouest", "foumban": "Ouest",
        "mbouda": "Ouest", "bandjoun": "Ouest", "bafang": "Ouest",
        // Sud-Ouest
        "buéa": "Sud-Ouest", "buea": "Sud-Ouest", "limbé": "Sud-Ouest",
        "limbe": "Sud-Ouest", "kumba": "Sud-Ouest", "tiko": "Sud-Ouest",
        "mamfe": "Sud-Ouest", "mutengene": "Sud-Ouest",
        // Nord-Ouest
        "bamenda": "Nord-Ouest", "kumbo": "Nord-Ouest", "ndop": "Nord-Ouest",
        "wum": "Nord-Ouest", "fundong": "Nord-Ouest", "bali": "Nord-Ouest",
        // Sud
        "ebolowa": "Sud", "kribi": "Sud", "sangmélima": "Sud",
        "ambam": "Sud", "djoum": "Sud",
        // Est
        "bertoua": "Est", "batouri": "Est", "abong-mbang": "Est",
        "yokadouma": "Est", "bélabo": "Est",
        // Adamaoua
        "ngaoundéré": "Adamaoua", "ngaoundere": "Adamaoua",
        "meiganga": "Adamaoua", "tibati": "Adamaoua", "banyo": "Adamaoua",
        "tignère": "Adamaoua",
        // Nord
        "garoua": "Nord", "guider": "Nord", "figuil": "Nord",
        "poli": "Nord", "lagdo": "Nord",
        // Extrême-Nord
        "maroua": "Extrême-Nord", "kousséri": "Extrême-Nord",
        "mokolo": "Extrême-Nord", "yagoua": "Extrême-Nord",
        "kaélé": "Extrême-Nord",
    ]

    /// Look up the région for a listing based on its `location` string.
    /// Nil when the city isn't in the table (edge cases like typos or an
    /// unknown neighbourhood-only string).
    static func region(for location: String) -> String? {
        let hay = location.lowercased()
        // Prefer the longest key that appears in the string, so
        // "Bonapriso, Douala" hits "douala" before any shorter accidental
        // substring match on the neighbourhood side.
        return cityToRegion
            .sorted { $0.key.count > $1.key.count }
            .first(where: { hay.contains($0.key) })?
            .value
    }
}

/// Filter panel — reworked to reflect what's actually online.
///
/// Every option row is computed from the current listing store: property
/// types, deal chips, cities and price buckets are only shown when they
/// exist in the dataset. Each chip carries a live count so the user knows
/// upfront how many results it would surface. Prices are bucketed on the
/// **actual** min/max of the live data — no more "< 50K" bracket that never
/// matches anything on a market whose median is 12K, or "1M+" that only
/// matches a handful of outliers.
struct FilterPanelView: View {
    @Binding var filters: FilterState
    var onApply: () -> Void = {}
    var onClose: () -> Void = {}

    @ObservedObject private var store = ListingStore.shared
    @ObservedObject private var owner = OwnerListings.shared

    @State private var draft: FilterState

    // Deal chips we consider — the panel only renders the ones that have
    // ≥1 matching listing right now.
    private let candidateActivities: [(label: String, icon: String)] = [
        ("À louer", "key.fill"),
        ("Court séjour", "calendar"),
        ("Meublé", "sofa.fill"),
        ("Non meublé", "cube.box"),
    ]
    private let candidatePropertyTypes: [(label: String, icon: String)] = [
        ("Chambres", "bed.double"),
        ("Studios", "square.grid.2x2"),
        ("Appartements", "building.2"),
        ("Villas", "house"),
        ("Bureaux", "briefcase"),
        ("Boutiques", "bag"),
        ("Coworking", "person.3"),
        ("Commercial", "cart"),
        ("Hôtel", "bed.double.circle"),
    ]

    init(filters: Binding<FilterState>, onApply: @escaping () -> Void = {},
         onClose: @escaping () -> Void = {}) {
        self._filters = filters
        self.onApply = onApply
        self.onClose = onClose
        _draft = State(initialValue: filters.wrappedValue)
    }

    /// Whole database (owner's local unpublished + server list) minus any
    /// annonces the owner made indisponible. Same source Home / Explore /
    /// Search read, so the counts reflect exactly what "Apply" would show.
    @MainActor
    private var allListings: [Listing] { MoblyData.all }

    /// Listings that already match the OTHER active filters — so counts on
    /// each chip reflect how many results tapping that chip would surface.
    /// Without this, a Coworking chip could show "12" then Apply returns 0
    /// because Coworking + your other selections has zero overlap.
    private func scoped(excluding axis: FilterAxis) -> [Listing] {
        allListings.filter { l in
            if axis != .activities, !draft.activities.isEmpty,
               !draft.activities.contains(where: { l.deals.contains($0) }) {
                return false
            }
            if axis != .propertyTypes, !draft.propertyTypes.isEmpty,
               !draft.propertyTypes.contains(l.category) {
                return false
            }
            if axis != .regions, !draft.regions.isEmpty {
                let r = CameroonRegion.region(for: l.location)
                if r == nil || !draft.regions.contains(r!) { return false }
            }
            if axis != .amenities, !draft.amenities.isEmpty,
               !draft.amenities.isSubset(of: Set(l.tags)) {
                return false
            }
            if axis != .price {
                let p = price(of: l)
                if let mn = Int(draft.minPrice), p < mn { return false }
                if let mx = Int(draft.maxPrice), mx > 0, p > mx { return false }
                if let (lo, hi) = bucketRange(draft.priceBucket), p < lo || p > hi { return false }
            }
            if axis != .bedrooms, draft.bedrooms != "Toutes" {
                let n = Int(l.features["Chambres"] ?? "0") ?? 0
                if draft.bedrooms == "4+" ? n < 4 : String(n) != draft.bedrooms { return false }
            }
            if axis != .bathrooms, draft.bathrooms != "Toutes" {
                let n = Int(l.features["Salle de bain"] ?? l.features["Salles de bain"] ?? "0") ?? 0
                if draft.bathrooms == "3+" ? n < 3 : String(n) != draft.bathrooms { return false }
            }
            return true
        }
    }
    private enum FilterAxis { case activities, propertyTypes, regions, amenities, price, bedrooms, bathrooms }

    private func price(of l: Listing) -> Int { Int(l.price.filter(\.isNumber)) ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView(showsIndicators: true) {
                VStack(alignment: .leading, spacing: 26) {
                    matchesBanner
                    activitySection
                    propertyTypeSection
                    regionSection
                    priceSection
                    // Bottom spacer keeps the last section clear of the
                    // sticky footer so nothing important is hidden behind
                    // the "Appliquer" button.
                    Color.clear.frame(height: 120)
                }
                .padding(.horizontal, 22)
                .padding(.top, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color(hex: 0xF4F5F8)))
            }
            Spacer()
            Text("Filtres")
                .font(.moblyHeading(18))
                .foregroundStyle(Color.moblyTextPrimary)
            Spacer()
            Button {
                withAnimation { draft = FilterState() }
            } label: {
                Text("Tout réinitialiser")
                    .font(.moblyBody(12.5, weight: .semibold))
                    .foregroundStyle(Color.moblyPrimary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: Live match count banner

    private var matchesBanner: some View {
        let count = scoped(excluding: .price).filter { l in
            let p = price(of: l)
            if let mn = Int(draft.minPrice), p < mn { return false }
            if let mx = Int(draft.maxPrice), mx > 0, p > mx { return false }
            if let (lo, hi) = bucketRange(draft.priceBucket), p < lo || p > hi { return false }
            return true
        }.count
        return HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.moblyPrimary.opacity(0.15)).frame(width: 36, height: 36)
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.moblyPrimary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("\(count) annonce\(count == 1 ? "" : "s") correspondent")
                    .font(.moblyHeading(14))
                    .foregroundStyle(Color.moblyTextPrimary)
                Text(draft.isEmpty ? "Ajoutez des filtres pour affiner"
                                   : "Résultat mis à jour en temps réel")
                    .font(.moblyBody(11.5))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
            }
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0xF7F8FA)))
    }

    // MARK: Type d'activité

    private struct ChipEntry: Identifiable {
        let label: String
        let icon: String
        let count: Int
        var id: String { label }
    }

    private var activitySection: some View {
        let source = scoped(excluding: .activities)
        // Every candidate is shown — even if the count is 0 — so the user
        // knows the full set of options and sees counts update as they
        // narrow other filters. Selected chips are always rendered.
        let entries: [ChipEntry] = candidateActivities.map { c in
            ChipEntry(label: c.label, icon: c.icon,
                      count: source.filter { $0.deals.contains(c.label) }.count)
        }
        return section(icon: "briefcase.fill", title: "Type d'activité") {
            // Same 2-column grid used by the price section — chips align
            // evenly instead of wrapping unevenly across rows.
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(entries) { entry in
                    let sel = draft.activities.contains(entry.label)
                    Button { toggle(&draft.activities, entry.label) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: sel ? "checkmark" : entry.icon)
                                .font(.system(size: 11, weight: .bold))
                            Text(LT(entry.label))
                                .font(.moblyBody(12.5, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Spacer(minLength: 0)
                            Text("\(entry.count)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(sel ? Color.moblyPrimary : .white)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(sel ? .white : Color.moblyPrimary))
                        }
                        .foregroundStyle(sel ? .white : Color(hex: 0x6B6F80))
                        .padding(.horizontal, 12).frame(height: 40)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 12)
                            .fill(sel ? Color.moblyPrimary : .white))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .stroke(sel ? Color.clear : Color(hex: 0xE2E4EC), lineWidth: 1.2))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Type de bien

    private var propertyTypeSection: some View {
        let source = scoped(excluding: .propertyTypes)
        // Show every property type — including ones with 0 matches under
        // the current filter — so the user sees the full catalog and can
        // adjust filters to reveal them.
        let entries: [ChipEntry] = candidatePropertyTypes.map { c in
            ChipEntry(label: c.label, icon: c.icon,
                      count: source.filter { $0.category == c.label }.count)
        }
        let visible = entries
        return section(icon: "house.fill", title: "Type de bien") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(visible) { entry in
                    let sel = draft.propertyTypes.contains(entry.label)
                    Button { toggle(&draft.propertyTypes, entry.label) } label: {
                        VStack(spacing: 6) {
                            Image(systemName: entry.icon)
                                .font(.system(size: 19, weight: .medium))
                                .foregroundStyle(sel ? Color.moblyPrimary : Color(hex: 0x9A9DAC))
                            Text(LT(entry.label))
                                .font(.moblyBody(11, weight: .semibold))
                                .foregroundStyle(sel ? Color.moblyPrimary : Color(hex: 0x6B6F80))
                                .lineLimit(1)
                            Text("\(entry.count)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(sel ? .white : Color.moblyPrimary)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(sel ? Color.moblyPrimary : Color.moblyPrimary.opacity(0.15)))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(sel ? Color.moblySurfaceTint : .white))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .stroke(sel ? Color.moblyPrimary : Color(hex: 0xE2E4EC),
                                    lineWidth: sel ? 1.6 : 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Région (all 10 régions of Cameroon, always visible)

    private var regionSection: some View {
        let source = scoped(excluding: .regions)
        let entries: [ChipEntry] = CameroonRegion.all.map { r in
            ChipEntry(label: r, icon: "map",
                      count: source.filter { CameroonRegion.region(for: $0.location) == r }.count)
        }
        return section(icon: "map.fill", title: "Région") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(entries) { entry in
                    let sel = draft.regions.contains(entry.label)
                    Button { toggle(&draft.regions, entry.label) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: sel ? "checkmark" : entry.icon)
                                .font(.system(size: 11, weight: .bold))
                            Text(LT(entry.label))
                                .font(.moblyBody(12.5, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Spacer(minLength: 0)
                            Text("\(entry.count)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(sel ? Color.moblyPrimary : .white)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(sel ? .white : Color.moblyPrimary))
                        }
                        .foregroundStyle(sel ? .white : Color(hex: 0x6B6F80))
                        .padding(.horizontal, 12).frame(height: 40)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 12)
                            .fill(sel ? Color.moblyPrimary : .white))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .stroke(sel ? Color.clear : Color(hex: 0xE2E4EC), lineWidth: 1.2))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Équipements (from the current data)

    private var amenitySection: some View {
        let source = scoped(excluding: .amenities)
        // Collect every unique tag across the current dataset. Sorted by
        // frequency so the most common ones (Wifi, Parking…) surface first.
        let tagCounts: [(String, Int)] = {
            var counter: [String: Int] = [:]
            for l in source { for t in l.tags { counter[t, default: 0] += 1 } }
            return counter.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 || ($0.1 == $1.1 && $0.0 < $1.0) }
        }()
        let iconMap: [String: String] = [
            "Wifi": "wifi", "Climatisation": "snowflake", "Parking": "car.fill",
            "Sécurité 24/7": "lock.shield.fill", "Eau chaude": "drop.fill",
            "Eau courante": "drop", "Cuisine équipée": "fork.knife",
            "Réfrigérateur": "refrigerator.fill", "Télévision": "tv.fill",
            "Groupe électrogène": "bolt.fill", "Balcon": "square.fill",
            "Terrasse": "sun.max.fill", "Ménage inclus": "sparkles",
            "Ascenseur": "arrow.up.arrow.down.square.fill",
            "Piscine": "figure.pool.swim", "Salle de sport": "dumbbell.fill",
        ]
        return section(icon: "sparkles", title: "Équipements",
                       hint: tagCounts.isEmpty ? "Aucun équipement dans les annonces" : nil) {
            WrapLayout(spacing: 8, lineSpacing: 8) {
                ForEach(tagCounts, id: \.0) { (tag, n) in
                    countChip(label: tag, icon: iconMap[tag] ?? "checkmark.circle",
                              count: n, selected: draft.amenities.contains(tag)) {
                        toggle(&draft.amenities, tag)
                    }
                }
            }
        }
    }

    // MARK: Salles de bain

    private var bathroomSection: some View {
        let source = scoped(excluding: .bathrooms)
        // Only options that exist in the data + 3+ if any listing has ≥3.
        let counts = Array(Set(source.compactMap { Int($0.features["Salle de bain"] ?? $0.features["Salles de bain"] ?? "") }))
            .filter { $0 > 0 }.sorted()
        var options = ["Toutes"] + counts.map(String.init)
        if counts.contains(where: { $0 >= 3 }) { options.append("3+") }
        return section(icon: "shower.fill", title: "Salles de bain") {
            WrapLayout(spacing: 8, lineSpacing: 8) {
                ForEach(options.uniqued(), id: \.self) { opt in
                    let sel = opt == draft.bathrooms
                    Button { draft.bathrooms = opt } label: {
                        Text(opt)
                            .font(.moblyBody(12.5, weight: .semibold))
                            .foregroundStyle(sel ? .white : Color.moblyTextPrimary)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(Capsule().fill(sel ? Color.moblyPrimary : Color(hex: 0xF4F5F8)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Prix — buckets adapted to the real min/max of the data

    private var priceSection: some View {
        let prices = allListings.map(price(of:)).filter { $0 > 0 }.sorted()
        let buckets = ["Toutes"] + self.buckets(from: prices)
        return section(icon: "banknote.fill", title: "Fourchette de prix",
                       hint: prices.isEmpty ? "Aucun prix connu" : nil) {
            VStack(alignment: .leading, spacing: 14) {
                // 2-column grid so brackets like "150 000 – 250 000" line up
                // instead of wrapping unevenly across rows.
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(buckets, id: \.self) { b in
                        let n = b == "Toutes" ? prices.count
                            : (bucketRange(b).map { r in prices.filter { $0 >= r.0 && $0 <= r.1 }.count } ?? 0)
                        let sel = b == draft.priceBucket
                        Button {
                            draft.priceBucket = b
                            if b != "Toutes" { draft.minPrice = ""; draft.maxPrice = "" }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: sel ? "checkmark" : "banknote")
                                    .font(.system(size: 11, weight: .bold))
                                Text(LT(b))
                                    .font(.moblyBody(12.5, weight: .semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                Spacer(minLength: 0)
                                Text("\(n)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(sel ? Color.moblyPrimary : .white)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Capsule().fill(sel ? .white : Color.moblyPrimary))
                            }
                            .foregroundStyle(sel ? .white : Color(hex: 0x6B6F80))
                            .padding(.horizontal, 12).frame(height: 40)
                            .frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 12)
                                .fill(sel ? Color.moblyPrimary : .white))
                            .overlay(RoundedRectangle(cornerRadius: 12)
                                .stroke(sel ? Color.clear : Color(hex: 0xE2E4EC), lineWidth: 1.2))
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(spacing: 12) {
                    priceField(placeholder: "Min", text: $draft.minPrice)
                    Text("—").foregroundStyle(Color(hex: 0x9A9DAC))
                    priceField(placeholder: "Max", text: $draft.maxPrice)
                }
            }
        }
    }

    /// Return up to five human-friendly price brackets that actually match
    /// the dataset — computed by percentiles of the sorted price list so a
    /// city where the median is 15K doesn't get "< 50K" as its lowest bucket.
    private func buckets(from prices: [Int]) -> [String] {
        guard prices.count >= 3 else {
            // Not enough data to compute — fall back to coarse defaults.
            return ["< 20 000", "20 000 – 50 000", "50 000 – 100 000",
                    "100 000 – 250 000", "250 000+"]
        }
        let q = [0.20, 0.40, 0.60, 0.80].map { p -> Int in
            let idx = Int(Double(prices.count - 1) * p)
            return round(prices[idx])
        }
        return [
            "< \(format(q[0]))",
            "\(format(q[0])) – \(format(q[1]))",
            "\(format(q[1])) – \(format(q[2]))",
            "\(format(q[2])) – \(format(q[3]))",
            "\(format(q[3]))+",
        ]
    }

    private func round(_ n: Int) -> Int {
        if n < 10_000  { return ((n + 500)   / 1_000)  * 1_000 }
        if n < 100_000 { return ((n + 2_500) / 5_000)  * 5_000 }
        return         ((n + 5_000) / 10_000) * 10_000
    }

    private func format(_ n: Int) -> String {
        let s = String(n); var out = ""
        for (i, c) in s.reversed().enumerated() {
            if i > 0 && i % 3 == 0 { out.append(" ") }
            out.append(c)
        }
        return String(out.reversed())
    }

    /// Bucket labels are dynamic now — parse `< X`, `X – Y`, `X+`.
    private func bucketRange(_ b: String) -> (Int, Int)? {
        if b.isEmpty || b == "Toutes" { return nil }
        let digits = b.replacingOccurrences(of: " ", with: "")
        if digits.hasPrefix("<") {
            let n = Int(digits.dropFirst().filter(\.isNumber)) ?? 0
            return (0, max(0, n - 1))
        }
        if digits.hasSuffix("+") {
            let n = Int(digits.dropLast().filter(\.isNumber)) ?? 0
            return (n, .max)
        }
        let parts = b.components(separatedBy: "–").map {
            Int($0.filter(\.isNumber)) ?? 0
        }
        if parts.count == 2 { return (parts[0], parts[1]) }
        return nil
    }

    private func priceField(placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(placeholder)
                .font(.moblyBody(11.5))
                .foregroundStyle(Color(hex: 0x9A9DAC))
            TextField("0", text: text)
                .font(.moblyBody(14, weight: .medium))
                .keyboardType(.numberPad)
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0xF4F5F8)))
                .onChange(of: text.wrappedValue) { _, _ in draft.priceBucket = "Toutes" }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Chambres

    private var bedroomSection: some View {
        // Show only bedroom counts actually present in the data.
        let counts = Array(Set(allListings.compactMap { Int($0.features["Chambres"] ?? "") }))
            .filter { $0 > 0 }.sorted()
        let options = ["Toutes"] + counts.map(String.init) + (counts.contains(where: { $0 >= 4 }) ? ["4+"] : [])
        return section(icon: "bed.double.fill", title: "Chambres",
                       hint: counts.isEmpty ? "Aucune donnée de chambre" : nil) {
            WrapLayout(spacing: 8, lineSpacing: 8) {
                ForEach(options.uniqued(), id: \.self) { b in
                    let sel = b == draft.bedrooms
                    Button { draft.bedrooms = b } label: {
                        Text(LT(b))
                            .font(.moblyBody(12.5, weight: .semibold))
                            .foregroundStyle(sel ? .white : Color.moblyTextPrimary)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(Capsule().fill(sel ? Color.moblyPrimary : Color(hex: 0xF4F5F8)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Section wrapper

    private func section<Content: View>(icon: String, title: String, hint: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.moblyPrimary)
                Text(LT(title))
                    .font(.moblyHeading(16))
                    .foregroundStyle(Color.moblyTextPrimary)
            }
            if let hint {
                Text(LT(hint))
                    .font(.moblyBody(12))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
            } else {
                content()
            }
        }
    }

    // MARK: Count chip (used across sections)

    private func countChip(label: String, icon: String, count: Int, selected: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                } else {
                    Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                }
                Text(LT(label)).font(.moblyBody(12.5, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(selected ? Color.moblyPrimary : .white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(selected ? .white : Color.moblyPrimary))
            }
            .foregroundStyle(selected ? .white : Color(hex: 0x6B6F80))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Capsule().fill(selected ? Color.moblyPrimary : .white))
            .overlay(Capsule().stroke(selected ? Color.clear : Color(hex: 0xE2E4EC),
                                       lineWidth: 1.2))
        }
        .buttonStyle(.plain)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 10) {
            // Save the current draft as a recurring recherche. Only offered
            // when there's actually a filter set — saving "no filters at all"
            // would clutter the Favoris > Recherches tab with junk rows.
            if !draft.isEmpty {
                Button { saveDraftAsRecherche() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: saveConfirm ? "checkmark.circle.fill" : "bookmark.fill")
                            .font(.system(size: 12, weight: .bold))
                        Text(saveConfirm ? "Recherche enregistrée" : "Enregistrer cette recherche")
                            .font(.moblyBody(13, weight: .semibold))
                    }
                    .foregroundStyle(saveConfirm ? Color(hex: 0x1F8A5B) : Color.moblyPrimary)
                    .frame(maxWidth: .infinity).frame(height: 40)
                    .background(Capsule().fill((saveConfirm ? Color(hex: 0x1F8A5B) : Color.moblyPrimary).opacity(0.10)))
                }
                .buttonStyle(.plain)
                .disabled(saveConfirm)
            }
            HStack(spacing: 12) {
                Button {
                    withAnimation { draft = FilterState() }
                } label: {
                    Text("Tout effacer")
                        .font(.moblyHeading(15))
                        .foregroundStyle(Color.moblyPrimary)
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .background(Capsule().stroke(Color(hex: 0xE2E4EC), lineWidth: 1.5))
                }
                .buttonStyle(.plain)

                Button {
                    filters = draft
                    onApply()
                } label: {
                    Text("Appliquer les filtres")
                        .font(.moblyHeading(15))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .background(Capsule().fill(Color.moblyPrimary))
                        .shadow(color: Color.moblyPrimary.opacity(0.3), radius: 12, y: 6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 28)
        .background(
            Color.white.shadow(color: Color(hex: 0x14152A).opacity(0.06), radius: 12, y: -3)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    /// Persist the current draft to `SavedSearchStore`. The label is derived
    /// from whichever axis carries the most weight, so a search for
    /// "Villas / Ouest / 100 000 – 250 000" reads correctly on the Recherches
    /// tab without asking the user to name it.
    @State private var saveConfirm: Bool = false
    private func saveDraftAsRecherche() {
        SavedSearchStore.shared.add(label: bestLabel(for: draft),
                                    query: "", filters: draft)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.easeInOut(duration: 0.25)) { saveConfirm = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.25)) { saveConfirm = false }
        }
    }
    private func bestLabel(for s: FilterState) -> String {
        if !s.propertyTypes.isEmpty { return s.propertyTypes.sorted().joined(separator: " · ") }
        if !s.regions.isEmpty       { return s.regions.sorted().joined(separator: " · ") }
        if !s.activities.isEmpty    { return s.activities.sorted().joined(separator: " · ") }
        return "Recherche personnalisée"
    }

    private func toggle(_ set: inout Set<String>, _ value: String) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

// MARK: - Legacy wrap chip (kept for callers that still reference it)

/// Simple checkbox chip row. Kept for existing callers; the new panel uses
/// `countChip` inside `WrapLayout` directly.
struct FlowChips: View {
    let items: [String]
    let selected: (String) -> Bool
    let onTap: (String) -> Void

    var body: some View {
        WrapLayout(spacing: 9, lineSpacing: 9) {
            ForEach(items, id: \.self) { item in
                let sel = selected(item)
                Button { onTap(item) } label: {
                    HStack(spacing: 5) {
                        if sel { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
                        Text(item).font(.moblyBody(12.5, weight: .semibold))
                    }
                    .foregroundStyle(sel ? Color.moblyPrimary : Color(hex: 0x6B6F80))
                    .padding(.horizontal, 15).padding(.vertical, 9)
                    .background(Capsule().fill(sel ? Color.moblySurfaceTint : .white))
                    .overlay(Capsule().stroke(sel ? Color.moblyPrimary : Color(hex: 0xE2E4EC),
                                              lineWidth: sel ? 1.5 : 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Layout

/// A left-aligned wrapping layout.
struct WrapLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 { x = 0; y += rowHeight + lineSpacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + lineSpacing; rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private extension Array where Element: Hashable {
    /// Drop duplicates while keeping insertion order.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

#Preview {
    FilterPanelView(filters: .constant(FilterState()))
}
