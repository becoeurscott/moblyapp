import SwiftUI

struct SearchResultsView: View {
    var initialCategory: String?
    var initialQuery: String = ""
    var onClose: () -> Void = {}

    @ObservedObject private var listingStore = ListingStore.shared
    @State private var query: String
    @State private var activeChip: String
    @State private var filters = FilterState()
    @State private var showFilters = false
    @State private var selectedListing: Listing?
    @FocusState private var searchFocused: Bool

    private let chips = MoblyData.searchCategories

    init(initialCategory: String? = nil,
         initialQuery: String = "",
         onClose: @escaping () -> Void = {}) {
        self.initialCategory = initialCategory
        self.initialQuery = initialQuery
        self.onClose = onClose
        // Only preselect a chip if it's one of the transaction filters;
        // space categories (Villas, Bureaux…) just open the full list.
        let preset = initialCategory.flatMap { MoblyData.searchCategories.contains($0) ? $0 : nil }
        _activeChip = State(initialValue: preset ?? "Tous")
        // A space category (Villas, Bureaux…) isn't a transaction chip, so surface
        // it in the search bar — the user sees what they tapped and can clear it.
        let spaceCategory = initialCategory.flatMap {
            ($0 == "Tous" || MoblyData.searchCategories.contains($0)) ? nil : $0
        }
        _query = State(initialValue: initialQuery.isEmpty ? (spaceCategory ?? "") : initialQuery)
    }

    private var results: [Listing] {
        var base = MoblyData.results(for: activeChip)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty, q != activeChip.lowercased() {
            let canon = MoblyData.canonicalCategory(query.trimmingCharacters(in: .whitespaces))
            base = base.filter {
                $0.category == canon
                    || $0.title.lowercased().contains(q)
                    || $0.location.lowercased().contains(q)
            }
        }
        return base.filter { passesFilters($0) }
    }

    private func passesFilters(_ l: Listing) -> Bool {
        // Type d'activité
        if !filters.activities.isEmpty {
            let matchesActivity = filters.activities.contains { act in
                l.deals.contains(act) || (act == "Commercial" && l.category == "Commercial")
            }
            if !matchesActivity { return false }
        }
        // Type de bien
        if !filters.propertyTypes.isEmpty {
            let targets = Set(filters.propertyTypes.map(MoblyData.canonicalCategory))
            if !targets.contains(l.category) { return false }
        }
        // Ville (kept for back-compat with any code that still sets it)
        if !filters.cities.isEmpty {
            let hay = l.location.lowercased()
            if !filters.cities.contains(where: { hay.contains($0.lowercased()) }) {
                return false
            }
        }
        // Région
        if !filters.regions.isEmpty {
            let r = CameroonRegion.region(for: l.location)
            if r == nil || !filters.regions.contains(r!) { return false }
        }
        // Équipements
        if !filters.amenities.isEmpty,
           !filters.amenities.isSubset(of: Set(l.tags)) { return false }
        // Prix
        let price = priceValue(l.price)
        if let (lo, hi) = bucketRange(filters.priceBucket) {
            if price < lo || price > hi { return false }
        }
        if let mn = Int(filters.minPrice), price < mn { return false }
        if let mx = Int(filters.maxPrice), mx > 0, price > mx { return false }
        // Chambres
        if filters.bedrooms != "Toutes" {
            let n = Int(l.features["Chambres"] ?? "0") ?? 0
            if filters.bedrooms == "4+" ? n < 4 : String(n) != filters.bedrooms { return false }
        }
        // Salles de bain
        if filters.bathrooms != "Toutes" {
            let n = Int(l.features["Salle de bain"] ?? l.features["Salles de bain"] ?? "0") ?? 0
            if filters.bathrooms == "3+" ? n < 3 : String(n) != filters.bathrooms { return false }
        }
        return true
    }

    private func priceValue(_ s: String) -> Int {
        Int(s.filter(\.isNumber)) ?? 0
    }

    /// Buckets are dynamic now (built by FilterPanelView from real data),
    /// so parse them from the label instead of a fixed switch.
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
        let parts = b.components(separatedBy: "–").map { Int($0.filter(\.isNumber)) ?? 0 }
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            chipRow
                .padding(.top, 4)
                .padding(.bottom, 6)

            ScrollView(.vertical, showsIndicators: true) {
                HStack {
                    Text(headerLabel)
                        .font(.moblyHeading(16))
                        .foregroundStyle(Color.moblyTextPrimary)
                    Spacer()
                    Text("\(results.count) résultats")
                        .font(.moblyBody(12))
                        .foregroundStyle(Color(hex: 0x9A9DAC))
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)
                .padding(.bottom, 6)

                LazyVStack(spacing: 16) {
                    ForEach(results) { listing in
                        ResultCard(listing: listing) {
                            ListingStore.shared.prefetchGallery(for: listing)
                            selectedListing = listing
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)
                .padding(.bottom, 120)
            }
        }
        .background(Color.white)
        .sheet(isPresented: $showFilters) {
            FilterPanelView(filters: $filters,
                            onApply: { showFilters = false },
                            onClose: { showFilters = false })
                .presentationDetents([.large])
        }
        .fullScreenCover(item: $selectedListing) { listing in
            ListingDetailView(listing: listing, onClose: { selectedListing = nil })
                .transition(.move(edge: .bottom))
        }
    }

    private var headerLabel: String {
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { return q }
        return activeChip == "Tous" ? L("Tous les espaces") : LT(activeChip)
    }

    private var searchHeader: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .frame(width: 40, height: 40)
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                TextField("Rechercher…", text: $query)
                    .font(.moblyBody(14))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .focused($searchFocused)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Color(hex: 0xC4C7D2))
                    }
                }
                Button { showFilters = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.moblyPrimary)
                        .overlay(alignment: .topTrailing) {
                            if filters.count > 0 {
                                Text("\(filters.count)")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 14, height: 14)
                                    .background(Circle().fill(Color.moblyAccent))
                                    .offset(x: 8, y: -8)
                            }
                        }
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0xF4F5F8)))
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                ForEach(chips, id: \.self) { chip in
                    let active = chip == activeChip
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            activeChip = chip
                        }
                        UISelectionFeedbackGenerator().selectionChanged()
                    } label: {
                        Text(LT(chip))
                            .font(.moblyBody(12.5, weight: .semibold))
                            .foregroundStyle(active ? .white : Color(hex: 0x6B6F80))
                            .padding(.horizontal, 15)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(active ? Color.moblyPrimary : Color(hex: 0xF4F5F8)))
                    }
                }
            }
            .padding(.horizontal, 22)
        }
    }
}

// MARK: - Result card (yacht-app list row)

struct ResultCard: View {
    let listing: Listing
    var onOpen: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            ZStack(alignment: .topLeading) {
                ListingCover(listing: listing, width: ImageSlot.thumb)
                    .frame(width: 108, height: 108)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                HeartButton(listing: listing)
                    .padding(7)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top) {
                    Text(listing.title)
                        .font(.moblyHeading(15))
                        .foregroundStyle(Color.moblyTextPrimary)
                        .lineLimit(1)
                    Spacer()
                    if listing.rating.isEmpty {
                        Text("Nouveau")
                            .font(.moblyBody(11, weight: .semibold))
                            .foregroundStyle(Color.moblyPrimary)
                    } else {
                        HStack(spacing: 3) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 10)).foregroundStyle(Color.moblyPrimary)
                            Text(listing.rating)
                                .font(.moblyBody(11.5, weight: .semibold))
                                .foregroundStyle(Color.moblyTextPrimary)
                        }
                    }
                }

                Text(listing.reviewCount > 0
                     ? "\(listing.location) · \(listing.reviewCount) avis"
                     : listing.location)
                    .font(.moblyBody(11.5))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                    .lineLimit(1)

                Text("Équipements")
                    .font(.moblyBody(11, weight: .semibold))
                    .foregroundStyle(Color.moblyPrimary)
                    .padding(.top, 3)
                Text(listing.tags.joined(separator: "  ·  "))
                    .font(.moblyBody(11))
                    .foregroundStyle(Color(hex: 0x6B6F80))
                    .lineLimit(1)

                Spacer(minLength: 2)

                HStack(spacing: 3) {
                    Text(listing.price)
                        .font(.moblyHeading(14))
                        .foregroundStyle(Color.moblyPrimary)
                    Text(LT(listing.priceUnit))
                        .font(.moblyBody(11))
                        .foregroundStyle(Color(hex: 0x9A9DAC))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(hex: 0xEFF0F4), lineWidth: 1))
        .shadow(color: Color(hex: 0x14152A).opacity(0.05), radius: 10, y: 5)
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
    }
}

#Preview {
    SearchResultsView(initialCategory: "Studios")
}
