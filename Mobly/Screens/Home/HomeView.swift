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
    @ObservedObject private var savedSearches = SavedSearchStore.shared
    @ObservedObject private var session = Session.shared

    @State private var appeared = false
    @State private var selectedQuickFilter: String? = nil
    @State private var searchText = ""
    @State private var showBecomeOwner = false
    @State private var showOwnerDashboard = false
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
                .padding(.top, 10)
                .padding(.bottom, 6)
                .zIndex(1)

            ZStack(alignment: .top) {
                ScrollView(showsIndicators: false) {
                    feed
                        .padding(.bottom, 100)
                        // Listings arriving from a silent poll cross-fade into
                        // place instead of snapping.
                        .animation(Motion.content, value: store.listings)
                        .animation(Motion.standard, value: store.isOffline)
                        .animation(Motion.standard, value: store.lastError)
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
                        .transition(.opacity)
                }
            }
            .animation(Motion.instant, value: searching)
        }
        .background(Color.white)
        .opacity(appeared ? 1 : 0)
        .onAppear { withAnimation(Motion.standard) { appeared = true } }
        .onReceive(NotificationCenter.default.publisher(for: NetworkMonitor.didReconnect)) { _ in
            // Silent: the feed is already on screen from cache. Catching up
            // must not swap it for skeletons.
            Task { await store.fetch(silent: true) }
        }
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
        let pool: [Listing]
        if let city = userCity {
            let local = liveListings.filter { $0.location.lowercased().contains(city) }
            pool = local.isEmpty ? liveListings : local
        } else {
            pool = liveListings
        }
        let boosted = pool.filter { $0.boosted }
        let rest    = pool.filter { !$0.boosted }
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
                    .transition(.moblyAppear)
            } else if let err = store.lastError {
                // A server-side failure is not a connectivity problem — telling
                // the user to check their network would send them chasing the
                // wrong thing.
                statusBanner(icon: "exclamationmark.triangle.fill", text: err)
                    .padding(.horizontal, 22)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                    .transition(.moblyAppear)
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

            sectionHeader(L("Villes populaires"), actionLabel: "Explorer plus",
                          action: { onOpenCityMap("") })
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
                // Recent searches first — the same list as Profil → Recherches
                // enregistrées, so what you searched is where you expect it in
                // both places. Tapping one runs it again.
                if !savedSearches.items.isEmpty {
                    HStack {
                        Text("Recherches récentes")
                            .font(.moblyBody(11, weight: .semibold))
                            .foregroundStyle(Color(hex: 0x9A9DAC))
                        Spacer()
                        Button {
                            withAnimation(Motion.quick) { savedSearches.clear() }
                        } label: {
                            Text("Effacer")
                                .font(.moblyBody(11, weight: .semibold))
                                .foregroundStyle(Color.moblyPrimary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)

                    ForEach(Array(savedSearches.items.prefix(4))) { item in
                        Button {
                            dismissSearch()
                            onOpenCityMap(item.query.isEmpty ? item.label : item.query)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Color.moblyPrimary)
                                    .frame(width: 34, height: 34)
                                    .background(Circle().fill(Color.moblySurfaceTint))
                                Text(item.label)
                                    .font(.moblyBody(14, weight: .medium))
                                    .foregroundStyle(Color.moblyTextPrimary)
                                Spacer()
                                Image(systemName: "arrow.up.left")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color(hex: 0xC4C7D2))
                            }
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
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
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(hex: 0xF4F5F8))
        )
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

    /// Record what was searched so it shows up under the bar next time — and
    /// in Profil → Recherches enregistrées, which reads the same store.
    private func rememberSearch(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return }
        savedSearches.add(label: q, query: q, filters: FilterState())
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
                        if !q.isEmpty {
                            rememberSearch(q)
                            dismissSearch()
                            onOpenCityMap(q)
                        }
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
            .contentShape(Rectangle())
            .onTapGesture { searchActive = true }

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
                        withAnimation(Motion.quick) {
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
            Image("OwnerBanner")
                .resizable()
                .aspectRatio(contentMode: .fill)

            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    // An existing owner has nothing to "become" — the banner
                    // becomes a shortcut back to their dashboard instead.
                    Text(session.isOwner ? L("Gérer mes\nannonces") : L("Devenir propriétaire\navec Mobly"))
                        .font(.moblyHeading(19))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(session.isOwner
                         ? L("Suivez vos espaces et vos\ndemandes de visite")
                         : L("Publiez votre espace, touchez\ndes milliers de locataires"))
                        .font(.moblyBody(12.5))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(action: {
                        if session.isOwner { showOwnerDashboard = true }
                        else { showBecomeOwner = true }
                    }) {
                        Text(session.isOwner ? L("Ouvrir") : L("Commencer"))
                            .font(.moblyBody(12.5, weight: .semibold))
                            .foregroundStyle(Color.moblyPrimary)
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(Capsule().fill(.white))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
                Spacer(minLength: 8)
            }
            .padding(20)
        }
        .frame(height: 184)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Color.moblyPrimary.opacity(0.25), radius: 16, y: 10)
        .fullScreenCover(isPresented: $showBecomeOwner) {
            BecomeOwnerView(onClose: { showBecomeOwner = false })
                .swipeToDismiss(onDismiss: { showBecomeOwner = false })
        }
        .fullScreenCover(isPresented: $showOwnerDashboard) {
            NavigationStack { OwnerDashboardView() }
        }
    }

    // MARK: Recommended row

    /// City the recommendations should prioritise — device location wins
    /// (freshest), falling back to what's stored on the account.
    private var userCity: String? {
        let c = location.city ?? auth.user?.city
        let trimmed = c?.trimmingCharacters(in: .whitespaces)
            // Fold accents: the geocoder says "Yaoundé" and an annonce may be
            // stored as "Yaounde" (or the reverse), and an unfolded compare
            // silently matched nothing — which looked like no filter at all.
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
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
        // Best-rated first, always — "Recommandé" should mean recommended, and
        // the row was previously in whatever order the API returned.
        let ranked = base.sorted { score($0) > score($1) }

        // Someone outside Cameroon has no useful "near me": their city will
        // never match a listing, so they get the best-rated spaces nationwide
        // rather than an empty or arbitrary row.
        guard let city = userCity, isInCameroon else { return ranked }

        let near = ranked.filter {
            $0.location
                .folding(options: .diacriticInsensitive, locale: .current)
                .lowercased()
                .contains(city)
        }
        // A city with nothing in it falls back to the national ranking too.
        return near.isEmpty ? ranked : near
    }

    /// Sort key: the rating, with the number of avis breaking ties so a lone
    /// 5★ doesn't outrank a 4.8 with forty reviews. Unrated listings sort last
    /// instead of being treated as zero-star.
    private func score(_ l: Listing) -> Double {
        let rating = Double(l.rating) ?? 0
        guard rating > 0 else { return -1 }
        return rating + min(Double(l.reviewCount), 50) / 1000
    }

    /// Whether the user is somewhere our inventory can serve.
    ///
    /// The device's country wins when we have it. Otherwise we fall back to
    /// whether the city we resolved is one Mobly actually covers — a user in
    /// Paris has a city, it just never matches a listing, and without this
    /// check they would get an empty "Recommandé" instead of the best spaces
    /// in the country.
    private var isInCameroon: Bool {
        if let code = location.countryCode { return code.uppercased() == "CM" }
        guard let city = userCity else { return true }   // unknown: assume in-market
        return MoblyData.searchableLocations.contains {
            $0.name.folding(options: .diacriticInsensitive, locale: .current)
                .lowercased() == city
        }
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
        .animation(Motion.quick, value: selectedQuickFilter)
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
        VStack(alignment: .leading, spacing: 20) {
            FeaturedCardSkeleton()
            RecommendedRowSkeleton()
        }
    }

    // MARK: Section header

    private func sectionHeader(_ title: String,
                               actionLabel: String = "Voir tout",
                               action: @escaping () -> Void = {}) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(LT(title))
                .font(.moblyHeading(17))
                .foregroundStyle(Color.moblyTextPrimary)
            Spacer()
            Button(action: action) {
                Text(LT(actionLabel))
                    .font(.moblyBody(12.5, weight: .semibold))
                    .foregroundStyle(Color.moblyPrimary)
            }
        }
    }
}

#Preview {
    HomeView()
}
