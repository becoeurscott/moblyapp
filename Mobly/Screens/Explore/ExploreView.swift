import SwiftUI
import MapKit

struct ExploreView: View {
    var onOpenListing: (Listing) -> Void = { _ in }
    /// Opens a space the user found by typing its name, credited to
    /// "search" rather than "explore".
    var onOpenListingFromSearch: ((Listing) -> Void)? = nil
    var initialLocation: String = ""
    /// Preloaded filter state (typically from a saved recherche the user
    /// tapped on Favoris). Nil means keep the current in-memory filters.
    var initialFilters: FilterState? = nil
    /// Free text typed in the Accueil bar, run exactly as if it had been
    /// typed here (space names, then places, then an address).
    var initialQuery: String = ""
    /// A space picked from the Accueil suggestions: select it on the map,
    /// exactly like picking it from this bar's own suggestions.
    var initialFocusId: String = ""
    var onLocationConsumed: () -> Void = {}

    private let center = CLLocationCoordinate2D(latitude: 4.0511, longitude: 9.7679)
    private let chips = MoblyData.filterChips   // Tous, Chambres, Villas, Bureaux…

    @ObservedObject private var listingStore = ListingStore.shared
    @ObservedObject private var ownerListings = OwnerListings.shared
    @ObservedObject private var placeCompleter = LocationSearchCompleter.shared
    @ObservedObject private var savedSearches = SavedSearchStore.shared
    @ObservedObject private var config = RemoteConfigStore.shared
    @State private var activeChip = "Tous"
    /// Mirrors `searchActive` through an explicit animation (focus changes
    /// carry no animation, so the dropdown popped instead of sliding).
    @State private var showDropdown = false
    /// What the dropdown renders; frozen while it closes (see Home).
    @State private var panelText = ""
    /// The space picked from the name search, until the user moves on.
    @State private var searchedListingId: String?
    /// Set when the user runs a name search without picking a suggestion:
    /// the map shows only the spaces whose name matched, and the user picks
    /// the one they want. Nil means no name filter.
    @State private var nameMatchIds: Set<String>?
    /// Where the searched place is and how far around it counts as "in" it.
    /// Most annonces don't name their quartier (only the city), but nearly all
    /// have exact coordinates — so "Akwa" is matched by position, not text.
    @State private var searchCenter: CLLocationCoordinate2D?
    @State private var searchRadiusMeters: CLLocationDistance = 0
    @State private var locatingUser = false

    /// All listings that pass the current category / filter panel. NO city
    /// filter and NO cap — the whole database goes on the map so a user
    /// browsing the country sees every annonce; the map itself does the
    /// spatial filtering as they pan and zoom.
    ///
    /// The chip filter is STRICT: if nothing matches (e.g. no Coworking
    /// listings exist), the map/carousel stay empty and the empty state
    /// takes over. Falling back to the full list was hiding the fact that
    /// the chip was applied at all.
    private var listings: [Listing] {
        let byCategory: [Listing]
        if activeChip == "Tous" {
            byCategory = MoblyData.all
        } else {
            let target = MoblyData.canonicalCategory(activeChip)
            byCategory = MoblyData.all.filter { $0.category == target }
        }
        var filtered = byCategory.filter { passesFilters($0) }

        if let ids = nameMatchIds {
            return filtered.filter { ids.contains($0.id) }
        }

        if !committedLocation.isEmpty {
            let place = committedLocation
                .split(separator: ",").first
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                ?? committedLocation
            let placeFolded = Self.fold(place)
            let origin = searchCenter.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
            // In the place = its address names it, OR it physically sits
            // inside the searched area.
            filtered = filtered.filter { l in
                if Self.fold(l.location).contains(placeFolded) { return true }
                guard let origin, let lat = l.lat, let lng = l.lng, lat != 0 || lng != 0 else { return false }
                return CLLocation(latitude: lat, longitude: lng).distance(from: origin) <= searchRadiusMeters
            }
            let target = searchCenter ?? locationCoordinate(committedLocation)
            filtered.sort { a, b in
                distSq(target, baseCoord(for: a)) < distSq(target, baseCoord(for: b))
            }
        }

        return filtered
    }

    /// Cameroon's bounding box, with a margin.
    ///
    /// A stored coordinate is only trusted when it falls inside it. Listings do
    /// get saved with nonsense: the publish wizard's pin picker takes whatever
    /// the device reports, so an annonce created on a simulator (or a phone
    /// with location spoofing) lands somewhere like Arlington, Texas while its
    /// city still says "Douala". One such row is enough to stretch the map's
    /// bounding box across the Atlantic and put every real pin off-screen, so
    /// an implausible coordinate is discarded in favour of the declared city.
    private static func isInCameroon(lat: Double, lng: Double) -> Bool {
        (1.5...13.5).contains(lat) && (8.0...16.5).contains(lng)
    }

    private func baseCoord(for l: Listing) -> CLLocationCoordinate2D {
        if let lat = l.lat, let lng = l.lng, Self.isInCameroon(lat: lat, lng: lng) {
            return CLLocationCoordinate2D(latitude: lat, longitude: lng)
        }
        let city = l.location.split(separator: ",").last.map {
            String($0).trimmingCharacters(in: .whitespaces)
        } ?? l.location
        return locationCoordinate(city)
    }

    private func distSq(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let dlat = a.latitude - b.latitude
        let dlon = a.longitude - b.longitude
        return dlat * dlat + dlon * dlon
    }

    /// Where to fly the camera on first appear / after "recentrer".
    private var pinCenter: CLLocationCoordinate2D {
        committedLocation.isEmpty ? center : locationCoordinate(committedLocation)
    }

    private func passesFilters(_ l: Listing) -> Bool {
        if !filters.activities.isEmpty {
            let ok = filters.activities.contains { l.deals.contains($0) || ($0 == "Commercial" && l.category == "Commercial") }
            if !ok { return false }
        }
        if !filters.propertyTypes.isEmpty {
            let targets = Set(filters.propertyTypes.map(MoblyData.canonicalCategory))
            if !targets.contains(l.category) { return false }
        }
        if !filters.cities.isEmpty {
            let hay = l.location.lowercased()
            if !filters.cities.contains(where: { hay.contains($0.lowercased()) }) { return false }
        }
        if !filters.regions.isEmpty {
            let r = CameroonRegion.region(for: l.location)
            if r == nil || !filters.regions.contains(r!) { return false }
        }
        if !filters.amenities.isEmpty,
           !filters.amenities.isSubset(of: Set(l.tags)) { return false }
        let price = Int(l.price.filter(\.isNumber)) ?? 0
        if let (lo, hi) = parseBucket(filters.priceBucket), price < lo || price > hi { return false }
        if let mn = Int(filters.minPrice), price < mn { return false }
        if let mx = Int(filters.maxPrice), mx > 0, price > mx { return false }
        if filters.bedrooms != "Toutes" {
            let n = Int(l.features["Chambres"] ?? "0") ?? 0
            if filters.bedrooms == "4+" ? n < 4 : String(n) != filters.bedrooms { return false }
        }
        if filters.bathrooms != "Toutes" {
            let n = Int(l.features["Salle de bain"] ?? l.features["Salles de bain"] ?? "0") ?? 0
            if filters.bathrooms == "3+" ? n < 3 : String(n) != filters.bathrooms { return false }
        }
        return true
    }

    /// Dynamic bucket parser: "< 20 000", "20 000 – 50 000", "250 000+".
    /// Matches the shape produced by the reworked FilterPanelView.
    private func parseBucket(_ b: String) -> (Int, Int)? {
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

    @State private var position: MapCameraPosition = .region(
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 4.0511, longitude: 9.7679),
                           span: MKCoordinateSpan(latitudeDelta: 0.06, longitudeDelta: 0.06))
    )
    @State private var selected: String?
    @State private var searchText = ""
    @State private var committedLocation = ""
    @FocusState private var searchActive: Bool
    @State private var showFilters = false
    @State private var filters = FilterState()
    @State private var chatListing: Listing?
    @ObservedObject private var auth = AuthStore.shared
    @State private var needsSignIn = false

    private static func fold(_ s: String) -> String {
        s.folding(options: .diacriticInsensitive, locale: .current).lowercased()
    }

    /// Open a space's detail, crediting the view to "search" when the user
    /// found it through the name search.
    private func openListing(_ l: Listing) {
        let fromNameSearch = l.id == searchedListingId || (nameMatchIds?.contains(l.id) ?? false)
        if fromNameSearch, let fromSearch = onOpenListingFromSearch {
            fromSearch(l)
        } else {
            onOpenListing(l)
        }
    }

    /// Run a typed search — the same resolution the Accueil bar hands over.
    private func runSearch(_ raw: String) {
        let q = raw.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        switch SpaceSearch.resolve(q) {
        case .spaces(let matches):
            // "kina" with two Kina annonces shows both and lets the user pick.
            showNameMatches(matches, query: q)   // records the search itself
            return
        case .place(let place):
            goTo(place)
        case .address(let text):
            goTo(text)
        }
        SavedSearchStore.shared.add(label: q, query: q, filters: filters)
    }

    /// Keep only the spaces whose name matched, frame them on the map, and
    /// leave the choice to the user (no pin is auto-selected).
    private func showNameMatches(_ spaces: [Listing], query: String) {
        searchedListingId = nil
        searchCenter = nil
        nameMatchIds = Set(spaces.map(\.id))
        committedLocation = ""
        selected = nil
        searchActive = false
        searchText = query
        SavedSearchStore.shared.add(label: query, query: query, filters: filters)
        // `listings` now holds only the matches; fit the camera on them.
        DispatchQueue.main.async { fitAllListings() }
    }

    private func focusListing(id: String) {
        if let l = MoblyData.all.first(where: { $0.id == id }) { focusListing(l) }
    }

    /// Put one space front and centre: clear any city filter (the space may
    /// be anywhere), select its pin and zoom the map onto it.
    private func focusListing(_ l: Listing) {
        searchedListingId = l.id
        nameMatchIds = nil
        searchActive = false
        searchText = l.title
        committedLocation = ""
        SavedSearchStore.shared.add(label: l.title, query: l.title, filters: filters)
        // `listings` is recomputed without the city filter above, so the
        // pin index is looked up after that change.
        DispatchQueue.main.async {
            withAnimation(Motion.panel) { selected = l.id }
            let items = listings
            if let i = items.firstIndex(where: { $0.id == l.id }) {
                zoomTo(coord(items[i], i), span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012))
            }
        }
    }

    /// Real GPS coordinates for every Cameroonian city / quartier the app
    /// picks from. Verified against MapKit — dropping a pin at each value
    /// puts the pin on the correct place and the corresponding city label
    /// shows up when zoomed to `citySpan`.
    ///
    /// Longer keys go first so a "yaoundé" search doesn't accidentally match
    /// the shorter "aounde"-like fragments (the loop uses `contains`).
    private static let cityTable: [(key: String, lat: Double, lon: Double)] = [
        // Douala + its quartiers
        ("bonamoussadi", 4.0933, 9.7451), ("bonapriso", 4.0300, 9.7060),
        ("bonanjo", 4.0463, 9.6884), ("bonabéri", 4.0742, 9.6669),
        ("bonaberi", 4.0742, 9.6669), ("bonabery", 4.0742, 9.6669),
        ("bonaloka", 4.0603, 9.7062), ("logbessou", 4.0842, 9.7742),
        ("logpom", 4.0870, 9.7683), ("makepé", 4.0800, 9.7550),
        ("makepe", 4.0800, 9.7550), ("ndokotti", 4.0480, 9.7413),
        ("new bell", 4.0450, 9.7420), ("akwa", 4.0520, 9.7020),
        ("deido", 4.0620, 9.7020), ("bali", 4.0450, 9.7000),
        ("kotto", 4.0888, 9.7605), ("pk 14", 4.1400, 9.8000),
        ("douala", 4.0511, 9.7679),
        // Yaoundé + its quartiers
        ("bastos", 3.8880, 11.5160), ("nlongkak", 3.8880, 11.5230),
        ("essos", 3.8620, 11.5350), ("nsam", 3.8480, 11.5100),
        ("mvog-mbi", 3.8560, 11.5220), ("nsimeyong", 3.8280, 11.4930),
        ("biyem-assi", 3.8352, 11.4820), ("biyemassi", 3.8352, 11.4820),
        ("mendong", 3.8290, 11.4650), ("odza", 3.8020, 11.5450),
        ("ekounou", 3.8330, 11.5480), ("mvan", 3.8220, 11.5160),
        ("yaoundé", 3.8480, 11.5021), ("yaounde", 3.8480, 11.5021),
        // Other regional capitals + coastal
        ("bafoussam", 5.4780, 10.4180), ("dschang", 5.4460, 10.0630),
        ("foumban", 5.7250, 10.9010), ("bamenda", 5.9630, 10.1590),
        ("kumbo", 6.2010, 10.6740), ("buéa", 4.1540, 9.2920),
        ("buea", 4.1540, 9.2920), ("limbé", 4.0190, 9.2150),
        ("limbe", 4.0190, 9.2150), ("kumba", 4.6390, 9.4470),
        ("tiko", 4.0750, 9.3600), ("mutengene", 4.1000, 9.3160),
        ("kribi", 2.9390, 9.9070), ("ebolowa", 2.9010, 11.1500),
        ("sangmélima", 2.9330, 11.9840), ("bertoua", 4.5780, 13.6810),
        ("garoua", 9.3020, 13.4000), ("ngaoundéré", 7.3200, 13.5800),
        ("ngaoundere", 7.3200, 13.5800), ("maroua", 10.5910, 14.3150),
        ("kousséri", 12.0770, 15.0300), ("koussé", 12.0770, 15.0300),
        // Cameroon default (used when nothing matches)
        ("cameroun", 5.7, 12.35), ("cameroon", 5.7, 12.35),
    ]

    private func locationCoordinate(_ name: String) -> CLLocationCoordinate2D {
        let key = name.lowercased()
        for entry in Self.cityTable where key.contains(entry.key) {
            return CLLocationCoordinate2D(latitude: entry.lat, longitude: entry.lon)
        }
        return center
    }

    /// Wide enough that MapKit paints the city name label; narrow enough that
    /// price pins inside the city stay distinguishable. Used whenever the
    /// user picks a city from Home or the search dropdown.
    private static let citySpan = MKCoordinateSpan(latitudeDelta: 0.28, longitudeDelta: 0.28)
    /// Tighter span for named quartiers (Akwa, Bonapriso…) — MapKit still
    /// shows the quartier label at this zoom.
    private static let quartierSpan = MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)

    /// Return true when the searched name is a quartier of a bigger city
    /// (contains a comma, e.g. "Bonapriso, Douala").
    private func isQuartier(_ location: String) -> Bool {
        if location.contains(",") { return true }
        let name = Self.fold(location.trimmingCharacters(in: .whitespaces))
        return CameroonGeo.quartiers.values.contains { list in
            list.contains { Self.fold($0) == name }
        }
    }

    /// Whether `locationCoordinate` has a real entry for this place, rather
    /// than falling back to the default map centre.
    private func knowsCoordinate(_ name: String) -> Bool {
        let key = name.lowercased()
        return Self.cityTable.contains { key.contains($0.key) }
    }

    private func goTo(_ location: String) {
        nameMatchIds = nil
        let coord = locationCoordinate(location)
        let quartier = isQuartier(location)
        let span = quartier ? Self.quartierSpan : Self.citySpan
        // A known place gets a geographic area; an unknown name falls back
        // to matching the address text only.
        if knowsCoordinate(location) {
            searchCenter = coord
            searchRadiusMeters = quartier ? 2_500 : 20_000
        } else {
            searchCenter = nil
        }
        searchActive = false
        searchText = location       // keep the searched location in the bar
        committedLocation = location
        selected = nil
        // Track the new camera so the +/– buttons zoom from here.
        currentCenter = coord
        currentSpan = span
        withAnimation(Motion.gentle) {
            position = .region(MKCoordinateRegion(center: coord, span: span))
        }
    }

    /// The "x" inside the search field. It only empties the text box: it does
    /// NOT drop `committedLocation`, so the map keeps showing the city the user
    /// already searched instead of silently snapping back to every listing in
    /// the country. Focus is kept so they can type a new query straight away.
    private func clearSearchTextOnly() {
        searchText = ""
    }

    /// Cancel the search entirely: empty the field, drop the committed city so
    /// every listing comes back, and — the part that was missing — put the
    /// camera back over all of them. Without the re-fit the map stayed zoomed
    /// on the city that was just cancelled, so "annuler" widened the data
    /// underneath a viewport that still showed one quartier.
    private func clearSearch() {
        searchedListingId = nil
        nameMatchIds = nil
        searchCenter = nil
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        searchText = ""
        committedLocation = ""
        selected = nil
        withAnimation(Motion.instant) { searchActive = false }
        DispatchQueue.main.async { fitAllListings() }
    }

    /// Coordinate for a listing on the map.
    ///
    /// Priority: real DB `lat/lng` when present → the listing's OWN declared
    /// city (never the currently-viewed one, so a Yaoundé annonce cannot
    /// appear over Douala) → a small spiral offset around that city so
    /// several listings sharing a city don't stack on the exact same point.
    ///
    /// Takes the listing rather than re-reading `listings`: that property
    /// filters and sorts the whole feed, and calling it once per pin made every
    /// render and every map tap quadratic.
    private func coord(_ l: Listing, _ i: Int) -> CLLocationCoordinate2D {
        if let lat = l.lat, let lng = l.lng, Self.isInCameroon(lat: lat, lng: lng) {
            return CLLocationCoordinate2D(latitude: lat, longitude: lng)
        }
        // Fall back to the listing's declared city. `location` looks like
        // "Bonapriso, Douala" or "Douala"; take the last segment as city.
        let city = l.location.split(separator: ",").last.map {
            String($0).trimmingCharacters(in: .whitespaces)
        } ?? l.location
        let cityCoord = locationCoordinate(city)
        // Golden-angle spiral just for stacking: tiny (~500 m) offset so
        // several listings in the same city fan out instead of overlapping.
        let angle = Double(i) * 2.399963
        let r = 0.004 + 0.002 * Double(i % 4)
        return CLLocationCoordinate2D(latitude: cityCoord.latitude + r * cos(angle),
                                      longitude: cityCoord.longitude + r * sin(angle))
    }

    /// Nearest pin to a tap, in screen space. `nil` when the tap landed on
    /// bare map, which is what clears the selection.
    private func listingID(atScreenPoint pt: CGPoint, proxy: MapProxy) -> String? {
        let hitRadius: CGFloat = 34
        var best: (id: String, dist: CGFloat)?
        for (i, l) in listings.enumerated() {
            guard let p = proxy.convert(coord(l, i), to: .local) else { continue }
            let d = hypot(p.x - pt.x, p.y - pt.y)
            if d <= hitRadius, d < (best?.dist ?? .greatestFiniteMagnitude) {
                best = (l.id, d)
            }
        }
        return best?.id
    }

    var body: some View {
        // Filtered once per render. `listings` filters (and may sort) the
        // whole feed; it was evaluated five times per render plus a full-array
        // compare for the animation, which is the hitch you felt coming back
        // to this tab.
        let items = listings
        return MapReader { proxy in
        Map(position: $position) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, l in
                Annotation("", coordinate: coord(l, i)) {
                    PricePin(price: shortPrice(l.price), selected: selected == l.id)
                        .allowsHitTesting(false)
                }
            }
            UserAnnotation()
        }
        .mapStyle(.standard(elevation: .realistic,
                            pointsOfInterest: .including([.publicTransport, .park, .school, .hospital, .airport, .restaurant, .cafe, .foodMarket, .store])))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        // One tap handler for the whole map: hitting a pin selects it,
        // hitting anywhere else clears the selection.
        .onTapGesture { pt in
            if searchActive {
                searchActive = false
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
            withAnimation(Motion.panel) {
                selected = listingID(atScreenPoint: pt, proxy: proxy)
            }
        }
        .onMapCameraChange { ctx in
            currentSpan = ctx.region.span
            currentCenter = ctx.region.center
        }
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                topBar
                if showDropdown {
                    searchDropdown
                        .padding(.horizontal, 18)
                        .padding(.top, 6)
                        .transition(SearchDropdown.transition)
                }
                if !showDropdown {
                    chipRow.padding(.top, 10)
                        .transition(.opacity)
                }
            }
            .onChange(of: searchActive) { _, open in
                if open { panelText = searchText }
                withAnimation(open ? SearchDropdown.animation : SearchDropdown.closeAnimation) { showDropdown = open }
            }
            .onChange(of: searchText) { _, t in if searchActive { panelText = t } }
        }
        .overlay(alignment: .bottom) {
            if !searchActive {
                Group {
                    if let sel = items.first(where: { $0.id == selected }) {
                        selectedPreview(sel)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else if items.isEmpty {
                        emptyFilterState
                    } else {
                        carousel(items)
                    }
                }
                .padding(.bottom, 112)
            }
        }
        // Filter changes and silently-refreshed listings restack the pins and
        // the carousel together instead of both cutting.
        // Keyed on ids: comparing whole Listing values cost a deep compare of
        // every field of every listing on each render.
        .animation(Motion.content, value: items.map(\.id))
        .sheet(isPresented: $showFilters) {
            FilterPanelView(filters: $filters,
                            onApply: { showFilters = false },
                            onClose: { showFilters = false })
                .presentationDetents([.large])
        }
        .onAppear {
            if let preset = initialFilters { filters = preset }
            if !initialLocation.isEmpty {
                goTo(initialLocation)
                onLocationConsumed()
            } else if !initialQuery.isEmpty {
                runSearch(initialQuery)
                onLocationConsumed()
            } else if !initialFocusId.isEmpty {
                focusListing(id: initialFocusId)
                onLocationConsumed()
            }
        }
        .onChange(of: initialFocusId) { _, id in
            guard !id.isEmpty else { return }
            focusListing(id: id)
            onLocationConsumed()
        }
        .onChange(of: initialQuery) { _, q in
            guard !q.isEmpty else { return }
            runSearch(q)
            onLocationConsumed()
        }
        .onChange(of: initialLocation) { _, loc in
            guard !loc.isEmpty else { return }
            if let preset = initialFilters { filters = preset }
            goTo(loc)
            onLocationConsumed()
        }
        .fullScreenCover(item: $chatListing) { listing in
            ChatOpeningView(listing: listing, onBack: { chatListing = nil })
        }
        .alert("Connexion requise", isPresented: $needsSignIn) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Connectez-vous pour contacter le propriétaire.")
        }
        }
    }

    // MARK: Empty state (no listing matches the current filter)

    private var emptyFilterState: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(hex: 0x9A9DAC))
            VStack(alignment: .leading, spacing: 2) {
                Text("Aucune annonce")
                    .font(.moblyHeading(14))
                    .foregroundStyle(Color.moblyTextPrimary)
                Text("Aucune annonce ne correspond à \(activeChip == "Tous" ? "vos filtres" : "\"\(activeChip)\"").")
                    .font(.moblyBody(11.5))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                    .lineLimit(2)
            }
            Spacer()
            Button {
                withAnimation(Motion.quick) {
                    activeChip = "Tous"
                    filters = FilterState()
                }
            } label: {
                Text("Réinitialiser")
                    .font(.moblyBody(11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(Color.moblyPrimary))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(.white))
        .shadow(color: Color(hex: 0x14152A).opacity(0.10), radius: 10, y: 4)
        .padding(.horizontal, 16)
    }

    // MARK: Zoom controls

    /// Cameroon-scoped span limits.
    /// The country roughly fits in 12° lat × 8° lon around (5.7, 12.35),
    /// so the max zoom-out shows the entire country and its neighbours.
    private let cameroonCenter = CLLocationCoordinate2D(latitude: 5.7, longitude: 12.35)
    private let minSpan: MKCoordinateSpan = .init(latitudeDelta: 0.004, longitudeDelta: 0.004)
    private let maxSpan: MKCoordinateSpan = .init(latitudeDelta: 12,    longitudeDelta: 12)

    /// Current visible region (best-effort — MapCameraPosition doesn't expose
    /// it directly, so approximate by tracking the last committed one).
    @State private var currentSpan = MKCoordinateSpan(latitudeDelta: 0.06, longitudeDelta: 0.06)
    @State private var currentCenter = CLLocationCoordinate2D(latitude: 4.0511, longitude: 9.7679)

    private var zoomControls: some View {
        VStack(spacing: 10) {
            zoomButton("plus")  { zoom(factor: 0.5) }        // in
            zoomButton("minus") { zoom(factor: 2.0) }        // out
            zoomButton("mappin.and.ellipse.circle.fill") { recenterUser() }
            zoomButton("map") { fitAllListings() }
        }
        .padding(.trailing, 14)
        .padding(.bottom, 200)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    private func zoomButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.moblyTextPrimary)
                .frame(width: 44, height: 44)
                .background(Circle().fill(.white))
                .shadow(color: Color(hex: 0x14152A).opacity(0.15), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
    }

    private func zoom(factor: Double) {
        let latDelta = min(max(currentSpan.latitudeDelta * factor,
                               minSpan.latitudeDelta), maxSpan.latitudeDelta)
        let lonDelta = min(max(currentSpan.longitudeDelta * factor,
                               minSpan.longitudeDelta), maxSpan.longitudeDelta)
        let span = MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        currentSpan = span
        withAnimation(Motion.standard) {
            position = .region(MKCoordinateRegion(center: currentCenter, span: span))
        }
    }

    private func recenterUser() {
        // Fall back to the city coordinate table — device coord isn't
        // retained (privacy), so we can't jump to a precise GPS fix.
        currentCenter = committedLocation.isEmpty
            ? (LocationService.shared.city.map(locationCoordinate) ?? center)
            : locationCoordinate(committedLocation)
        currentSpan = MKCoordinateSpan(latitudeDelta: 0.06, longitudeDelta: 0.06)
        withAnimation(Motion.standard) {
            position = .region(MKCoordinateRegion(center: currentCenter, span: currentSpan))
        }
    }

    /// Frame every listing currently on the map — the real "voir tout".
    ///
    /// Preferred over `fitCountry()` because a fixed 12° box over Cameroon is
    /// mostly empty space: with the pilot in Douala it puts every pin in one
    /// small cluster. This fits the actual bounding box of what is displayed,
    /// so cancelling a search lands on the annonces rather than on the country.
    private func fitAllListings() {
        let coords = listings.enumerated().map { coord($0.element, $0.offset) }
        guard !coords.isEmpty else { return fitCountry() }

        let lats = coords.map(\.latitude)
        let lngs = coords.map(\.longitude)
        let minLat = lats.min()!, maxLat = lats.max()!
        let minLng = lngs.min()!, maxLng = lngs.max()!

        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                            longitude: (minLng + maxLng) / 2)
        // 1.4× padding so pins never sit on the edge, and a floor so a single
        // listing (or several at one address) doesn't zoom to street level.
        let span = MKCoordinateSpan(
            latitudeDelta: min(max((maxLat - minLat) * 1.4, 0.08), maxSpan.latitudeDelta),
            longitudeDelta: min(max((maxLng - minLng) * 1.4, 0.08), maxSpan.longitudeDelta)
        )
        currentCenter = center
        currentSpan = span
        withAnimation(Motion.gentle) {
            position = .region(MKCoordinateRegion(center: center, span: span))
        }
    }

    private func fitCountry() {
        currentCenter = cameroonCenter
        currentSpan = maxSpan
        withAnimation(Motion.gentle) {
            position = .region(MKCoordinateRegion(center: cameroonCenter, span: maxSpan))
        }
    }

    // MARK: Search dropdown — MKLocalSearchCompleter live suggestions
    //
    // Sits directly under the search bar and grows to fit its own content
    // (no reserved 380pt whitespace). When the user picks a suggestion, the
    // completion is resolved to a real coordinate via MKLocalSearch and the
    // camera zooms to that point.

    private var searchDropdown: some View {
        CappedScroll(maxHeight: SearchDropdown.maxHeight) {
        VStack(spacing: 0) {
            if panelText.isEmpty {
                // Recent searches on top — the same store Profil → Recherches
                // enregistrées reads, so the two never disagree.
                if config.isEnabled("search.savedSearches"), !savedSearches.items.isEmpty {
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
                    .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 2)

                    ForEach(Array(savedSearches.items.prefix(4))) { item in
                        suggestionRow(title: item.label,
                                      subtitle: "Recherche récente",
                                      icon: "clock.arrow.circlepath",
                                      action: {
                                          if !item.filters.isEmpty { filters = item.filters }
                                          goTo(item.query.isEmpty ? item.label : item.query)
                                      })
                    }
                }
            } else {
                let spaces = SpaceSearch.spaces(panelText)
                if !spaces.isEmpty {
                    Text("Espaces")
                        .font(.moblyBody(11, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x9A9DAC))
                        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 2)
                    ForEach(spaces) { l in
                        suggestionRow(title: l.title,
                                      subtitle: "\(l.location) · \(l.price)",
                                      icon: "house.fill",
                                      action: { focusListing(l) })
                    }
                }
                let local = SpaceSearch.places(panelText)
                if !local.isEmpty {
                    if !spaces.isEmpty {
                        Text("Lieux")
                            .font(.moblyBody(11, weight: .semibold))
                            .foregroundStyle(Color(hex: 0x9A9DAC))
                            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 2)
                    }
                    ForEach(local, id: \.name) { s in
                        suggestionRow(title: s.name,
                                      subtitle: s.region == "Cameroun" ? "Cameroun" : "\(s.region), Cameroun",
                                      action: { goTo("\(s.name), \(s.region)") })
                    }
                }
                let localNames = Set(local.map { $0.name.lowercased() })
                ForEach(placeCompleter.suggestions.filter { !localNames.contains($0.title.lowercased()) }) { s in
                    suggestionRow(title: s.title,
                                  subtitle: s.subtitle.isEmpty ? "Cameroun" : s.subtitle,
                                  action: { pickPlaceSuggestion(s) })
                }
                if spaces.isEmpty && local.isEmpty && placeCompleter.suggestions.isEmpty && !placeCompleter.isSearching {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Color(hex: 0x9A9DAC))
                        Text("Aucun résultat pour \"\(panelText)\"")
                            .font(.moblyBody(13))
                            .foregroundStyle(Color(hex: 0x9A9DAC))
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                }
            }
        }
        .padding(.vertical, 4)
        // Always full width: a short state ("Aucun lieu trouvé") no
        // longer shrinks the panel to its text and snaps it back.
        .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color(hex: 0x14152A).opacity(0.14), radius: 16, y: 8)
        // Follows the frozen panel text, so closing never clears the rows
        // out from under the fade.
        .onChange(of: panelText) { _, q in placeCompleter.update(query: q) }
    }

    private func suggestionRow(title: String, subtitle: String,
                               icon: String = "mappin.and.ellipse",
                               action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.moblySurfaceTint).frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.moblyPrimary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(LT(title)).font(.moblyHeading(13.5))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .lineLimit(1)
                Text(LT(subtitle)).font(.moblyBody(11.5))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "arrow.up.left")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(hex: 0xC4C7D2))
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { action() }
    }

    /// Resolve the user's picked place to a coordinate and zoom the map to
    /// that exact point. Falls back to a name-based lookup if MKLocalSearch
    /// returns nothing (rare, e.g. very generic completions).
    private func pickPlaceSuggestion(_ s: LocationSearchCompleter.Suggestion) {
        let label = s.subtitle.isEmpty ? s.title : "\(s.title), \(s.subtitle)"
        searchText = s.title
        committedLocation = label
        searchActive = false
        selected = nil
        // Recognise the picked place as a real search so Favoris > Recherches
        // reflects the count.
        SavedSearchStore.shared.add(label: label, query: s.title, filters: filters)
        Task {
            if let coord = await placeCompleter.resolve(s) {
                await MainActor.run {
                    searchCenter = coord
                    searchRadiusMeters = 2_500
                    zoomTo(coord)
                }
            } else {
                await MainActor.run { goTo(s.title) }
            }
        }
    }

    /// Request a fresh GPS fix and zoom the map onto the user's exact spot.
    /// If permission is denied or the device can't get a fix in time, fall
    /// back to the account's stored city, then Douala centre — the button
    /// never leaves the user stuck without any movement.
    private func recenterOnDevice() {
        locatingUser = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            let coord = await LocationService.shared.requestOneShotCoordinate()
            await MainActor.run {
                locatingUser = false
                if let coord {
                    zoomTo(coord, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
                } else if let city = LocationService.shared.city
                    ?? AuthStore.shared.user?.city,
                          let fallback = CityCoordinates.coordinate(for: city) {
                    zoomTo(fallback)
                } else {
                    zoomTo(center)
                }
            }
        }
    }

    /// Zoom to a specific coordinate with a tight span so the picked place
    /// dominates the map (matches the Google Maps "point-zoom" behaviour).
    private func zoomTo(_ coord: CLLocationCoordinate2D,
                        span: MKCoordinateSpan = MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)) {
        currentCenter = coord
        currentSpan = span
        withAnimation(Motion.gentle) {
            position = .region(MKCoordinateRegion(center: coord, span: span))
        }
    }

    // MARK: Top floating bar

    private var topBar: some View {
        HStack(spacing: 12) {
            if searchActive {
                Button {
                    // One cancel path. This used to clear only the text field,
                    // leaving `committedLocation` set and the camera parked on
                    // the previous city.
                    clearSearch()
                } label: {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.moblyTextPrimary)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(.white))
                        .shadow(color: .black.opacity(0.1), radius: 8, y: 3)
                }
            }

            HStack(spacing: 10) {
                ZStack {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color(hex: 0x9A9DAC))
                        TextField("Explorer sur la carte", text: $searchText)
                            .font(.moblyBody(13.5))
                            .foregroundStyle(Color.moblyTextPrimary)
                            .focused($searchActive)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .onSubmit { runSearch(searchText) }
                        if !searchText.isEmpty {
                            Button(action: clearSearchTextOnly) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 15))
                                    .foregroundStyle(Color(hex: 0xC4C7D2))
                            }
                        }
                    }
                    if !searchActive {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { searchActive = true }
                    }
                }
                Button { showFilters = true } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.moblyPrimary)
                        .overlay(alignment: .topTrailing) {
                            if filters.count > 0 {
                                Circle().fill(Color.moblyAccent)
                                    .frame(width: 7, height: 7).offset(x: 5, y: -5)
                            }
                        }
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(Capsule().fill(.white))
            .shadow(color: .black.opacity(0.1), radius: 10, y: 4)

            if !searchActive {
                Button { recenterOnDevice() } label: {
                    ZStack {
                        Circle().fill(.white).frame(width: 48, height: 48)
                        Image(systemName: locatingUser ? "location.circle" : "location.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.moblyPrimary)
                            .rotationEffect(.degrees(locatingUser ? 360 : 0))
                            .animation(locatingUser
                                       ? .linear(duration: 1.2).repeatForever(autoreverses: false)
                                       : .default, value: locatingUser)
                    }
                    .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
    }

    // MARK: Category chips (below search)

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips, id: \.self) { chip in
                    let active = chip == activeChip
                    Button {
                        withAnimation(Motion.quick) {
                            activeChip = chip
                            selected = nil
                        }
                        UISelectionFeedbackGenerator().selectionChanged()
                    } label: {
                        Text(chip)
                            .font(.moblyBody(12.5, weight: .semibold))
                            .foregroundStyle(active ? .white : Color.moblyTextPrimary)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 9)
                            .background(Capsule().fill(active ? Color.moblyPrimary : .white))
                            .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
        }
    }

    // MARK: Selected pin preview (mini detail)

    private func previewCategoryLine(_ l: Listing) -> String {
        let furnished = l.deals.contains("Meublé") ? "Meublé" : (l.deals.contains("Non meublé") ? "Non meublé" : nil)
        if let f = furnished {
            return "\(LT(l.category)) - \(f)"
        }
        return LT(l.category)
    }

    private func selectedPreview(_ l: Listing) -> some View {
        ZStack(alignment: .topTrailing) {
        VStack(spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                ListingCover(listing: l, width: ImageSlot.thumb)
                    .frame(width: 56, height: 56)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(l.title)
                        .font(.moblyHeading(14))
                        .foregroundStyle(Color.moblyTextPrimary)
                        .lineLimit(1)
                        .padding(.trailing, 28)
                    Text(l.location)
                        .font(.moblyBody(11))
                        .foregroundStyle(Color(hex: 0x9A9DAC))
                        .lineLimit(1)
                    // Same rule as every other card: no avis, no star.
                    if l.rating.isEmpty {
                        Text("Nouveau")
                            .font(.moblyBody(11, weight: .semibold))
                            .foregroundStyle(Color.moblyPrimary)
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.moblyAccent)
                            Text(l.rating)
                                .font(.moblyBody(11, weight: .semibold))
                                .foregroundStyle(Color.moblyTextPrimary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(previewCategoryLine(l))
                    .font(.moblyBody(11))
                    .foregroundStyle(Color(hex: 0x6B6F80))
                    .lineLimit(1)
                HStack(spacing: 3) {
                    Text(l.price)
                        .font(.moblyHeading(13))
                        .foregroundStyle(Color.moblyPrimary)
                    Text(LT(l.priceUnit))
                        .font(.moblyBody(10))
                        .foregroundStyle(Color(hex: 0x9A9DAC))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(hex: 0xF4F5F8)))

            HStack(spacing: 8) {
                Button {
                    guard config.can("chat.enabled") else { return }
                    if auth.isSignedIn {
                        chatListing = l
                    } else {
                        needsSignIn = true
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "bubble.left.fill")
                            .font(.system(size: 10))
                        Text("Message")
                            .font(.moblyBody(12, weight: .semibold))
                    }
                    .foregroundStyle(Color(hex: 0x3A4FF0))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color(hex: 0xDDE1FC)))
                }
                .buttonStyle(.plain)

                Button { openListing(l) } label: {
                    Text(L("Détails"))
                        .font(.moblyBody(12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Color.moblyPrimary))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)

            Button {
                withAnimation(Motion.panel) { selected = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(hex: 0x6B6F80))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color(hex: 0xF1F2F5)))
            }
            .buttonStyle(.plain)
            .padding(10)
        }
        // Same surface as the floating tab bar: near-white frosted glass with
        // a bright edge and a soft drop shadow. The old ultra-thin material
        // let the map show through and the text lost its contrast.
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.white.opacity(0.72))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.95), Color.white.opacity(0.35)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Color(hex: 0x14152A).opacity(0.14), radius: 16, y: 16)
        .padding(.horizontal, 18)
    }

    // MARK: Bottom carousel

    private func carousel(_ listings: [Listing]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                // Lazy: one card (and one photo download) per listing on the
                // map was built up front.
                LazyHStack(spacing: 14) {
                    ForEach(listings) { l in
                        ExploreCard(listing: l, highlighted: selected == l.id) {
                            openListing(l)
                        }
                        .id(l.id)
                        .onTapGesture {
                            withAnimation(Motion.panel) {
                                selected = l.id
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                // Room for the cards' drop shadow, which the ScrollView clips.
                .padding(.vertical, 14)
            }
            // A ScrollView takes every point it is offered, so without this the
            // strip filled the whole map and the cards floated in the middle of
            // the screen instead of sitting above the tab bar. ExploreCard is a
            // fixed 112 tall; the 28 is the shadow padding above.
            .frame(height: 140)
            .onChange(of: selected) { _, new in
                guard let new else { return }
                withAnimation(Motion.panel) {
                    proxy.scrollTo(new, anchor: .center)
                }
            }
        }
    }

    private func shortPrice(_ s: String) -> String {
        let digits = s.filter(\.isNumber)
        guard let n = Int(digits) else { return s }
        if n >= 1_000_000 { return "\(n / 1_000_000)M" }
        return "\(n / 1000)k"
    }
}

// MARK: - Price pin

private struct PricePin: View {
    let price: String
    let selected: Bool
    var body: some View {
        Text(price)
            .font(.moblyHeading(12))
            .foregroundStyle(selected ? .white : Color.moblyTextPrimary)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Capsule().fill(selected ? Color.moblyPrimary : .white))
            .overlay(Capsule().stroke(selected ? Color.clear : Color(hex: 0xE2E4EC), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
            .scaleEffect(selected ? 1.1 : 1)
    }
}

// MARK: - Explore card

private struct ExploreCard: View {
    let listing: Listing
    let highlighted: Bool
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                ListingCover(listing: listing, width: ImageSlot.thumb)
                    .frame(width: 92, height: 92)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(listing.title)
                        .font(.moblyHeading(14))
                        .foregroundStyle(Color.moblyTextPrimary)
                        .lineLimit(1)
                    Text(listing.location)
                        .font(.moblyBody(11))
                        .foregroundStyle(Color(hex: 0x9A9DAC))
                        .lineLimit(1)
                    if listing.rating.isEmpty {
                        Text("Nouveau")
                            .font(.moblyBody(10, weight: .semibold))
                            .foregroundStyle(Color.moblyPrimary)
                    } else {
                        HStack(spacing: 3) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9)).foregroundStyle(Color.moblyAccent)
                            Text(listing.rating)
                                .font(.moblyBody(10.5, weight: .semibold))
                                .foregroundStyle(Color.moblyTextPrimary)
                        }
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 2) {
                        Text(listing.price)
                            .font(.moblyHeading(13))
                            .foregroundStyle(Color.moblyPrimary)
                        Text(LT(listing.priceUnit))
                            .font(.moblyBody(10))
                            .foregroundStyle(Color(hex: 0x9A9DAC))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .frame(width: 290, height: 112)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 18)
                .stroke(highlighted ? Color.moblyPrimary : Color.clear, lineWidth: 2))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ExploreView()
}
