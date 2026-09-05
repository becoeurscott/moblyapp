import SwiftUI

struct HomeView: View {
    /// Falls back to a neutral greeting rather than inventing a name for
    /// someone who hasn't signed in.
    var userName: String = ""
    var onOpenListing: (Listing) -> Void = { _ in }
    var onSearch: () -> Void = {}
    var onProfile: () -> Void = {}
    var onNotifications: () -> Void = {}
    var onOpenCategory: (String?) -> Void = { _ in }
    var onOpenCity: (String) -> Void = { _ in }
    var onOpenCityMap: (String) -> Void = { _ in }
    var onOpenExplore: () -> Void = {}

    @ObservedObject private var store = ListingStore.shared
    @ObservedObject private var auth = AuthStore.shared
    @ObservedObject private var location = LocationService.shared
    @ObservedObject private var placeCompleter = LocationSearchCompleter.shared
    @ObservedObject private var userData = UserDataStore.shared

    @State private var appeared = false
    @State private var selectedQuickFilter: String? = nil
    @State private var searchText = ""
    @FocusState private var searchActive: Bool

    private var searching: Bool { searchActive || !searchText.isEmpty }

    private var suggestions: [(name: String, region: String)] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
            .folding(options: .diacriticInsensitive, locale: .current).lowercased()
        guard !q.isEmpty else { return [] }
        return MoblyData.searchableLocations.filter {
            let name = $0.name.folding(options: .diacriticInsensitive, locale: .current).lowercased()
            let region = $0.region.folding(options: .diacriticInsensitive, locale: .current).lowercased()
            return name.contains(q) || q.contains(name)
                || region.contains(q)
                || Self.commonPrefixLen(name, q) >= 4
        }
    }

    private static func commonPrefixLen(_ a: String, _ b: String) -> Int {
        zip(a, b).prefix(while: { $0 == $1 }).count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 22)
                .padding(.top, 8)

            searchBar
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 20)

            ZStack(alignment: .top) {
                ScrollView(showsIndicators: false) {
                    feed
                        .padding(.bottom, 100)
                }
                .refreshable {
                    await store.refresh()
                    await UserDataStore.shared.loadFavorites()
                }

                if searching {
                    Color.black.opacity(0.06)
                        .ignoresSafeArea()
                        .onTapGesture { dismissSearch() }
                        .transition(.opacity)

                    suggestionsCard
                        .padding(.horizontal, 22)
                        .padding(.top, 6)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .background(Color.white)
        .opacity(appeared ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: searching)
        .onAppear { withAnimation(.easeOut(duration: 0.4)) { appeared = true } }
    }

    // MARK: Feed helpers

    private var liveListings: [Listing] {
        // MoblyData.all merges the server list with anything the current
        // owner has just published (session-only or freshly POSTed).
        // Reading `store.listings` directly hid brand-new annonces from
        // Home entirely — a Non meublé listing the user just added never
        // reached the Recommandé row nor its filter chip.
        let all = MoblyData.all
        return all.isEmpty ? MoblyData.recommended + MoblyData.nearby : all
    }

    private var featuredListings: [Listing] {
        let boosted = liveListings.filter { $0.boosted }
        let rest    = liveListings.filter { !$0.boosted }
        return Array((boosted + rest).prefix(6))
    }

    // MARK: Feed (scrolls under the pinned search bar)

    private var feed: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.isOffline {
                statusBanner(icon: "wifi.slash",
                             text: "Pas de connexion · données en cache")
                    .padding(.horizontal, 22)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
            } else if let err = store.lastError {
                // A server-side failure is not a connectivity problem — telling
                // the user to check their network would send them chasing the
                // wrong thing.
                statusBanner(icon: "exclamationmark.triangle.fill", text: err)
                    .padding(.horizontal, 22)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
            }

            if store.isLoading && store.listings.isEmpty {
                skeletonCarousel
                    .padding(.top, 4)
                    .padding(.bottom, 24)
            } else {
                FeaturedHeroCarousel(listings: featuredListings, onOpen: onOpenListing)
                    .padding(.top, 4)
                    .padding(.bottom, 24)
            }

            sectionHeader(L("Villes populaires"), action: { onOpenCityMap("") })
                .padding(.horizontal, 22)
                .padding(.bottom, 14)
            popularRow
                .padding(.bottom, 24)

            promoBanner
                .padding(.horizontal, 22)
                .padding(.bottom, 24)

            sectionHeader(L("Recommandé"), action: { onOpenCategory("Tous") })
                .padding(.horizontal, 22)
                .padding(.bottom, 14)

            quickFilters
                .padding(.bottom, 22)

            recommendedRow
                .padding(.bottom, 24)

            AdBannerView()
                .padding(.bottom, 24)

            Text(L("Filtre rapide"))
                .font(.moblyHeading(17))
                .foregroundStyle(Color.moblyTextPrimary)
                .padding(.horizontal, 22)
                .padding(.bottom, 14)
            categoriesRow
                .padding(.bottom, 24)
        }
    }

    // MARK: Search suggestions overlay (same bar, expands in place)

    private var suggestionsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if searchText.isEmpty {
                Text("Quartiers populaires")
                    .font(.moblyBody(11, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                    .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
                ForEach(Array(MoblyData.searchableLocations.prefix(6)), id: \.name) { s in
                    suggestionRow(s.name, s.region, action: {
                        dismissSearch()
                        onOpenCityMap("\(s.name), \(s.region)")
                    })
                }
            } else if placeCompleter.suggestions.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "mappin.slash")
                        .foregroundStyle(Color(hex: 0xC4C7D2))
                    Text("Aucun lieu trouvé")
                        .font(.moblyBody(13))
                        .foregroundStyle(Color(hex: 0x9A9DAC))
                }
                .padding(.horizontal, 18).padding(.vertical, 16)
            } else {
                ForEach(placeCompleter.suggestions) { s in
                    suggestionRow(s.title,
                                  s.subtitle.isEmpty ? "Cameroun" : s.subtitle,
                                  action: {
                        let label = s.subtitle.isEmpty ? s.title : "\(s.title), \(s.subtitle)"
                        dismissSearch()
                        onOpenCityMap(label)
                    })
                }
            }
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white)
        )
        .shadow(color: Color(hex: 0x14152A).opacity(0.12), radius: 16, y: 8)
        // Sizes to the number of rows shown — no whitespace below the last one.
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: searchText) { _, q in placeCompleter.update(query: q) }
    }

    private func suggestionRow(_ name: String, _ region: String,
                               action: (() -> Void)? = nil) -> some View {
        Button {
            if let action { action() } else {
                dismissSearch()
                onOpenCityMap("\(name), \(region)")
            }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.moblySurfaceTint).frame(width: 32, height: 32)
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.moblyPrimary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.moblyHeading(13.5)).foregroundStyle(Color.moblyTextPrimary)
                        .lineLimit(1)
                    Text(region).font(.moblyBody(11.5)).foregroundStyle(Color(hex: 0x9A9DAC))
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "arrow.up.left")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(hex: 0xC4C7D2))
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func dismissSearch() {
        searchActive = false
        searchText = ""
    }

    // MARK: Header (greeting + bell)

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(L("Bonjour")), \(userName)")
                    .font(.moblyHeading(20))
                    .foregroundStyle(Color.moblyTextPrimary)
                Text(L("Où cherchez-vous un espace ?"))
                    .font(.moblyBody(13.5))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
            }
            Spacer()
            Button(action: onNotifications) {
                ZStack(alignment: .topTrailing) {
                    Circle().fill(Color(hex: 0xF4F5F8)).frame(width: 42, height: 42)
                    Image(systemName: userData.unreadNotifications > 0 ? "bell.fill" : "bell")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color.moblyTextPrimary)
                        .frame(width: 42, height: 42)
                    // Dot only when there IS at least one unread notification.
                    if userData.unreadNotifications > 0 {
                        Circle().fill(Color.moblyAccent)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().stroke(.white, lineWidth: 1.5))
                            .offset(x: -10, y: 9)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Search (same bar; activates in place)

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                TextField(L("Rechercher un espace, un quartier…"), text: $searchText)
                    .font(.moblyBody(13.5))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .focused($searchActive)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit {
                        let q = searchText.trimmingCharacters(in: .whitespaces)
                        if !q.isEmpty { dismissSearch(); onOpenCityMap(q) }
                    }
                if searching {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Color(hex: 0xC4C7D2))
                    }
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 14)
            .frame(height: 52)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(hex: 0xF4F5F8)))

            if searching {
                Button("Annuler") { dismissSearch() }
                    .font(.moblyBody(14, weight: .semibold))
                    .foregroundStyle(Color.moblyPrimary)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    // MARK: Popular neighborhoods row

    private var popularRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(MoblyData.popular) { n in
                    Button(action: { onOpenCityMap(n.name) }) {
                        VStack(alignment: .leading, spacing: 7) {
                            Image(n.imageName)
                                .resizable().scaledToFill()
                                .frame(width: 104, height: 104)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            Text(n.name)
                                .font(.moblyHeading(13.5))
                                .foregroundStyle(Color.moblyTextPrimary)
                            Text(LT(n.region))
                                .font(.moblyBody(11))
                                .foregroundStyle(Color(hex: 0x9A9DAC))
                        }
                        .frame(width: 104, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 22)
        }
    }

    // MARK: Quick filters (data-driven — reflect what's actually online)

    /// Chip definition + a `matches` closure so we can compute counts once
    /// per render and drop any chip whose count is zero. Order below is
    /// intentional: transaction/type first, then furnishing, then property
    /// categories (only the ones present in the current dataset).
    private struct QuickChip: Identifiable {
        let id: String
        let label: String
        let icon: String
        let match: (Listing) -> Bool
    }

    private var availableQuickChips: [(chip: QuickChip, count: Int)] {
        let source = liveListings
        // The four fundamental deal chips ALWAYS appear — À louer, Court
        // séjour, Meublé, Non meublé — even when their count is 0. The user
        // expects the full transaction set to be visible so they can see the
        // options exist and adjust other filters to reveal listings.
        let dealCandidates: [QuickChip] = [
            .init(id: "À louer",      label: "À louer",      icon: "key.fill",
                  match: { $0.deals.contains("À louer") }),
            .init(id: "Court séjour", label: "Court séjour", icon: "calendar",
                  match: { $0.deals.contains("Court séjour") }),
            .init(id: "Meublé",       label: "Meublé",       icon: "sofa.fill",
                  match: { $0.deals.contains("Meublé") }),
            .init(id: "Non meublé",   label: "Non meublé",   icon: "cube.box",
                  match: { $0.deals.contains("Non meublé") }),
        ]
        // Category chips remain dynamic — only categories with ≥1 live
        // listing show up so the row doesn't grow indefinitely.
        let categoryLabels = Array(Set(source.map(\.category))).sorted()
        let categoryChips: [QuickChip] = categoryLabels.map { cat in
            QuickChip(id: "cat:\(cat)", label: cat, icon: iconForCategory(cat),
                      match: { $0.category == cat })
        }
        let dealEntries = dealCandidates.map { ($0, source.filter($0.match).count) }
        let categoryEntries = categoryChips
            .map { ($0, source.filter($0.match).count) }
            .filter { $0.1 > 0 }
        return dealEntries + categoryEntries
    }

    private func iconForCategory(_ c: String) -> String {
        switch c {
        case "Chambres":     return "bed.double.fill"
        case "Studios":      return "square.grid.2x2.fill"
        case "Appartements": return "building.2.fill"
        case "Villas":       return "house.fill"
        case "Bureaux":      return "briefcase.fill"
        case "Boutiques":    return "bag.fill"
        case "Coworking":    return "person.3.fill"
        case "Commercial":   return "cart.fill"
        case "Hôtel":        return "bed.double.circle.fill"
        default:             return "tag.fill"
        }
    }

    private var quickFilters: some View {
        let chips = availableQuickChips
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if chips.isEmpty {
                    Text("Aucune annonce disponible")
                        .font(.moblyBody(12))
                        .foregroundStyle(Color(hex: 0x9A9DAC))
                        .padding(.horizontal, 22)
                }
                ForEach(chips, id: \.chip.id) { entry in
                    let sel = selectedQuickFilter == entry.chip.id
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            selectedQuickFilter = sel ? nil : entry.chip.id
                        }
                        UISelectionFeedbackGenerator().selectionChanged()
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: entry.chip.icon)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(sel ? .white : Color.moblyPrimary)
                            Text(LT(entry.chip.label))
                                .font(.moblyBody(12.5, weight: .semibold))
                                .foregroundStyle(sel ? .white : Color.moblyTextPrimary)
                            // Count badge — tells the user at a glance how
                            // many annonces the chip will surface.
                            Text("\(entry.count)")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(sel ? Color.moblyPrimary : .white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(sel ? .white : Color.moblyPrimary))
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 12)
                            .fill(sel ? Color.moblyPrimary : .white))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .stroke(sel ? Color.clear : Color(hex: 0xE2E4EC), lineWidth: 1.2))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 22)
        }
        .onChange(of: chips.map(\.chip.id)) { _, ids in
            // If the current selection no longer matches any live listing
            // (owner un-published the last matching annonce, filter chip
            // vanished), clear it rather than leaving a "ghost" selection.
            if let cur = selectedQuickFilter, !ids.contains(cur) {
                selectedQuickFilter = nil
            }
        }
    }

    // MARK: Promo banner (boosted-listings monetization)

    private var promoBanner: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(colors: [Color(hex: 0x3A4FF0), Color(hex: 0x5B6CF5)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )

            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Visitez en toute confiance"))
                        .font(.moblyHeading(19))
                        .foregroundStyle(.white)
                    Text(L("Discutez et planifiez vos visites,\ndirectement dans Mobly"))
                        .font(.moblyBody(12.5))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineSpacing(2)
                    Button(action: onSearch) {
                        Text(L("Découvrir"))
                            .font(.moblyBody(12.5, weight: .semibold))
                            .foregroundStyle(Color.moblyPrimary)
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(Capsule().fill(.white))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
                Spacer()
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.25))
            }
            .padding(20)
        }
        .frame(height: 150)
        .shadow(color: Color.moblyPrimary.opacity(0.25), radius: 16, y: 10)
    }

    // MARK: Recommended row

    /// City the recommendations should prioritise — device location wins
    /// (freshest), falling back to what's stored on the account.
    private var userCity: String? {
        let c = location.city ?? auth.user?.city
        let trimmed = c?.trimmingCharacters(in: .whitespaces).lowercased()
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    private var filteredRecommended: [Listing] {
        let base: [Listing]
        if let filter = selectedQuickFilter {
            // Chip ids prefixed with "cat:" are category filters; everything
            // else matches on `deals`. Strict — no fallback to full list.
            if filter.hasPrefix("cat:") {
                let cat = String(filter.dropFirst(4))
                base = liveListings.filter { $0.category == cat }
            } else {
                base = liveListings.filter { $0.deals.contains(filter) }
            }
        } else {
            base = liveListings
        }
        // Sort near-user listings to the top — any listing whose `location`
        // string contains the user's city ranks 0, everything else keeps its
        // original order via a stable partition.
        guard let city = userCity else { return base }
        let near = base.filter { $0.location.lowercased().contains(city) }
        let far  = base.filter { !$0.location.lowercased().contains(city) }
        return near + far
    }

    private var recommendedRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                if filteredRecommended.isEmpty {
                    Text("Aucun résultat pour ce filtre")
                        .font(.moblyBody(13)).foregroundStyle(Color(hex: 0x9A9DAC))
                        .padding(.horizontal, 22).padding(.vertical, 30)
                } else {
                    ForEach(filteredRecommended) { l in
                        RecommendedCard(listing: l) { onOpenListing(l) }
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 4)
        }
        .animation(.easeInOut(duration: 0.25), value: selectedQuickFilter)
    }

    // MARK: Categories row (circular icons)

    private var categoriesRow: some View {
        // 2-column grid of horizontal cards: tint tile flush-left + label right.
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
            ForEach(MoblyData.categories) { c in
                Button(action: { onOpenCategory(c.label) }) {
                    HStack(spacing: 0) {
                        ZStack {
                            Rectangle().fill(Color(hex: c.tint))
                            Image(systemName: c.icon)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(Color.moblyPrimary)
                        }
                        .frame(width: 54, height: 54)

                        Text(LT(c.label))
                            .font(.moblyHeading(13))
                            .foregroundStyle(Color.moblyTextPrimary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 11)

                        Spacer(minLength: 0)
                    }
                    .frame(height: 54)
                    .background(Color(hex: 0xF4F5F8))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 22)
    }

    // MARK: Offline banner

    /// Shared banner for "we couldn't load fresh data" states.
    private func statusBanner(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(hex: 0xFF6B35))
            Text(LT(text))
                .font(.moblyBody(13, weight: .medium))
                .foregroundStyle(Color.moblyTextPrimary)
                .lineLimit(2)
            Spacer()
            Button {
                Task { await store.refresh() }
            } label: {
                Text("Réessayer")
                    .font(.moblyBody(12, weight: .semibold))
                    .foregroundStyle(Color.moblyPrimary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0xFFF4EE)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(hex: 0xFF6B35).opacity(0.3), lineWidth: 1))
    }

    // MARK: Loading skeleton (placeholder before first fetch)

    private var skeletonCarousel: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(Color(hex: 0xF4F5F8))
            .frame(height: 210)
            .padding(.horizontal, 22)
            .overlay(
                ProgressView()
                    .tint(Color(hex: 0xC4C7D2))
            )
    }

    // MARK: Section header

    private func sectionHeader(_ title: String, action: @escaping () -> Void = {}) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(LT(title))
                .font(.moblyHeading(17))
                .foregroundStyle(Color.moblyTextPrimary)
            Spacer()
            Button(action: action) {
                Text("Voir tout")
                    .font(.moblyBody(12.5, weight: .semibold))
                    .foregroundStyle(Color.moblyPrimary)
            }
        }
    }
}

#Preview {
    HomeView()
}
