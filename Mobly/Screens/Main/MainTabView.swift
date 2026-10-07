import SwiftUI

enum MoblyTab: Int, CaseIterable {
    case home, explore, messages, favorites, profile

    var title: String {
        switch self {
        case .home: return "Accueil"
        case .explore: return "Explorer"
        case .messages: return "Messages"
        case .favorites: return "Favoris"
        case .profile: return "Profil"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .explore: return "map"
        case .messages: return "bubble.left.and.bubble.right"
        case .favorites: return "heart"
        case .profile: return "person"
        }
    }

    var iconFilled: String {
        switch self {
        case .home: return "house.fill"
        case .explore: return "map.fill"
        case .messages: return "bubble.left.and.bubble.right.fill"
        case .favorites: return "heart.fill"
        case .profile: return "person.fill"
        }
    }

    /// The remote flag that removes this tab from the bar, if any.
    var flag: String? {
        switch self {
        case .explore: return "maps"
        case .messages: return "chat.enabled"
        case .favorites: return "favorites"
        case .home, .profile: return nil
        }
    }

    @MainActor static func visible(_ config: RemoteConfigStore) -> [MoblyTab] {
        allCases.filter { t in t.flag.map { config.isEnabled($0) } ?? true }
    }
}

struct MainTabView: View {
    var onLogout: () -> Void = {}

    // Observe language so a switch re-renders the visible tab live, without the
    // global root `.id(lang.code)` reset (which used to tear down navigation).
    @ObservedObject private var lang = AppLang.shared
    @ObservedObject private var chrome = AppChrome.shared
    @ObservedObject private var config = RemoteConfigStore.shared

    @State private var tab: MoblyTab = {
        if ProcessInfo.processInfo.environment["MAIN_TAB"] == "explore" { return .explore }
        if ProcessInfo.processInfo.environment["MAIN_TAB"] == "messages" { return .messages }
        if ProcessInfo.processInfo.environment["MAIN_TAB"] == "favorites" { return .favorites }
        if ProcessInfo.processInfo.environment["MAIN_TAB"] == "profile" { return .profile }
        return .home
    }()
    @State private var selectedListing: Listing?
    @State private var showNotifications = false
    /// Set when a notification points at a visit; MessagesView opens the hub.
    @State private var showVisitsFromRoute = false
    /// Opened from the "Vous avez un espace à louer ?" notification.
    @State private var showBecomeOwnerFromRoute = false
    @State private var showOwnerDashboardFromRoute = false
    /// Opened from the "Confirmez votre adresse e-mail" notification.
    @State private var showEmailFromRoute = false
    @State private var showSearch = false
    @State private var searchRequest: SearchRequest?
    @State private var searchCategory: String?
    @State private var searchQuery: String = ""
    @State private var showExplore = false
    @State private var exploreLocation = ""
    /// Free text typed in the Accueil bar, for Explorer to resolve.
    @State private var exploreQuery = ""
    /// A space picked from the Accueil suggestions, for Explorer to select.
    @State private var exploreFocusId = ""
    /// FilterState to apply the next time Explore renders. Set when the
    /// user taps a saved recherche in Favoris.
    @State private var explorePresetFilters: FilterState? = nil
    @ObservedObject private var push = PushService.shared
    /// Tabs the user has opened at least once. Explore, Favoris and Profil are
    /// built on first visit instead of at launch: mounted-but-hidden they ran
    /// their own loads (and re-rendered on every store change) behind the
    /// screen the user was actually touching. Home and Messages stay eager —
    /// Messages owns the push deep-link path into a conversation.
    @State private var visitedTabs: Set<MoblyTab> = []

    private func mounted(_ t: MoblyTab) -> Bool { tab == t || visitedTabs.contains(t) }

    /// Where the open came from, reported with the view so the owner's
    /// "Origine des vues" can tell Home, Explore, a boost, a shared link… apart.
    @State private var selectedListingSource = "detail"

    private func openListing(_ listing: Listing, from source: String) {
        ListingStore.shared.prefetchGallery(for: listing)
        // A boosted annonce is shown in these feeds because of its boost, so
        // the view is credited to the boost.
        let feeds: Set = ["home", "explore", "search"]
        selectedListingSource = listing.boosted && feeds.contains(source) ? "boost" : source
        selectedListing = listing
    }

    /// Open an annonce by id, fetching it when it is not in the cached feed.
    private func openListing(id: String, from source: String) {
        if let known = MoblyData.all.first(where: { $0.id == id }) {
            openListing(known, from: source)
        } else {
            Task {
                if let dto = try? await MoblyAPI.shared.listing(id: id) {
                    await MainActor.run { openListing(dto.asListing, from: source) }
                }
            }
        }
    }

    /// Take the user to whatever a notification (or a visit card) refers to.
    ///
    /// Threads reuse the push deep-link channel `MessagesView` already
    /// watches, so there is one path into a conversation rather than two.
    private func route(to target: NotificationTarget) {
        switch target {
        case .thread(let id):
            withAnimation(Motion.quick) { tab = .messages }
            guard config.isEnabled("chat.enabled") else { return }
            PushService.shared.pendingThreadId = id

        case .listing(let id):
            // Not in the cached feed (an archived or filtered annonce) is
            // fetched rather than silently doing nothing.
            openListing(id: id, from: "notification")

        case .visits:
            withAnimation(Motion.quick) { tab = .messages }
            showVisitsFromRoute = true

        case .becomeOwner:
            // Already an owner by the time they tap it: their dashboard.
            if Session.shared.isOwner { showOwnerDashboardFromRoute = true }
            else { showBecomeOwnerFromRoute = true }

        case .verifyEmail:
            showEmailFromRoute = true
        }
    }

    var body: some View {
        // The connection banner sits *above* the tabs in the layout. It used to
        // be a top safe-area inset, which the tab roots honoured but pages
        // pushed inside a tab's NavigationStack (Profil → Adresse e-mail,
        // Modifier le profil…) did not: the banner landed on their back button
        // and title. Stacked like this, every screen simply starts below it.
        VStack(spacing: 0) {
        ConnectionBanner()
        ZStack(alignment: .bottom) {
            Color.white.ignoresSafeArea()

            ZStack {
                HomeView(
                    onOpenListing: { openListing($0, from: "home") },
                    onOpenRecommended: { openListing($0, from: "recommended") },
                    onNotifications: { showNotifications = true },
                    onOpenCategory: { cat in
                        searchCategory = cat
                        searchQuery = ""
                        showSearch = true
                    },
                    onOpenCity: { city in
                        searchCategory = nil
                        searchQuery = city
                        showSearch = true
                    },
                    onOpenCityMap: { city in
                        guard config.isEnabled("maps") else {
                            searchCategory = nil
                            searchQuery = city
                            showSearch = true
                            return
                        }
                        exploreLocation = city
                        tab = .explore
                    },
                    onSearchQuery: { q in
                        guard config.isEnabled("maps") else {
                            searchCategory = nil
                            searchQuery = q
                            showSearch = true
                            return
                        }
                        exploreQuery = q
                        tab = .explore
                    },
                    onPickSpace: { l in
                        guard config.isEnabled("maps") else {
                            openListing(l, from: "search")
                            return
                        }
                        exploreFocusId = l.id
                        tab = .explore
                    },
                    onOpenExplore: { showExplore = true }
                )
                .opacity(tab == .home ? 1 : 0)
                .allowsHitTesting(tab == .home)

                if mounted(.explore) {
                ExploreView(
                    onOpenListing: { openListing($0, from: "explore") },
                    onOpenListingFromSearch: { openListing($0, from: "search") },
                    initialLocation: exploreLocation,
                    initialFilters: explorePresetFilters,
                    initialQuery: exploreQuery,
                    initialFocusId: exploreFocusId,
                    onLocationConsumed: {
                        exploreLocation = ""
                        exploreQuery = ""
                        exploreFocusId = ""
                        explorePresetFilters = nil
                    }
                )
                .opacity(tab == .explore ? 1 : 0)
                // No cross-fade for the map: fading a live Map with its pins
                // forces it to be composited offscreen for every frame of the
                // fade — the stutter on returning to Explorer. It cuts in.
                .animation(nil, value: tab)
                .allowsHitTesting(tab == .explore)
                }

                MessagesView(openVisits: $showVisitsFromRoute)
                    .opacity(tab == .messages ? 1 : 0)
                    .allowsHitTesting(tab == .messages)

                if mounted(.favorites) {
                FavoritesView(
                    onOpenListing: { openListing($0, from: "favorites") },
                    onOpenSearch: { search in
                        guard config.isEnabled("maps") else {
                            searchCategory = nil
                            searchQuery = search.location
                            showSearch = true
                            return
                        }
                        exploreLocation = search.location
                        tab = .explore
                    },
                    onOpenSavedSearch: { item in
                        // A space picked from search: open it, don't re-run
                        // its title as a place search.
                        if let id = item.listingId {
                            openListing(id: id, from: "search")
                            return
                        }
                        guard config.isEnabled("maps") else {
                            searchCategory = nil
                            searchQuery = item.label
                            showSearch = true
                            return
                        }
                        explorePresetFilters = item.filters
                        exploreLocation = item.label
                        tab = .explore
                    }
                )
                .opacity(tab == .favorites ? 1 : 0)
                .allowsHitTesting(tab == .favorites)
                }

                if mounted(.profile) {
                ProfileView(
                    onOpenFavorites: { tab = .favorites },
                    onLogout: onLogout
                )
                .opacity(tab == .profile ? 1 : 0)
                .allowsHitTesting(tab == .profile)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Tabs cross-fade rather than cutting. Short enough that it still
            // reads as instant, long enough that the eye isn't jolted.
            .animation(Motion.instant, value: tab)
            .onChange(of: tab, initial: true) { _, t in visitedTabs.insert(t) }

            if !chrome.hideTabBar {
                // Frosted band under the floating bar, running to the physical
                // bottom edge (behind the home indicator). A full-height
                // container that ignores the bottom safe area guarantees the
                // band touches the screen edge on every device.
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Group {
                        if DeviceTier.reducedEffects {
                            // Same fade, no live blur: a masked material is
                            // re-rendered on every scroll frame.
                            LinearGradient(
                                stops: [
                                    .init(color: Color.white.opacity(0), location: 0),
                                    .init(color: Color.white.opacity(0.94), location: 0.55),
                                    .init(color: Color.white.opacity(0.97), location: 1),
                                ],
                                startPoint: .top, endPoint: .bottom
                            )
                        } else {
                            Rectangle()
                                .fill(.ultraThinMaterial)
                                .mask(
                                    LinearGradient(
                                        stops: [
                                            .init(color: .clear, location: 0),
                                            .init(color: .black, location: 0.55),
                                            .init(color: .black, location: 1),
                                        ],
                                        startPoint: .top, endPoint: .bottom
                                    )
                                )
                        }
                    }
                        // Short enough that the fade happens *behind* the bar
                        // (whose top sits ~104pt above the edge): no white haze
                        // above the nav, frost only beneath it.
                        .frame(height: 96)
                }
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
                .transition(.opacity)

                MoblyTabBar(tab: $tab)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        }
        .animation(Motion.quick, value: chrome.hideTabBar)
        .ignoresSafeArea(.keyboard)
        .onAppear { SessionTracker.shared.log("screen.view", ["screen": "\(tab)"]) }
        .onChange(of: tab) { _, new in
            SessionTracker.shared.log("screen.view", ["screen": "\(new)"])
        }
        .fullScreenCover(isPresented: $showBecomeOwnerFromRoute) {
            BecomeOwnerView(
                onClose: { showBecomeOwnerFromRoute = false },
                onPublished: {
                    showBecomeOwnerFromRoute = false
                    // After the cover finishes dismissing, land on the dashboard.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { showOwnerDashboardFromRoute = true }
                }
            )
            .swipeToDismiss(onDismiss: { showBecomeOwnerFromRoute = false })
        }
        .fullScreenCover(isPresented: $showOwnerDashboardFromRoute) { OwnerDashboardCover() }
        .fullScreenCover(isPresented: $showEmailFromRoute) {
            // Its own stack: the screen's back button dismisses the cover.
            NavigationStack { EmailVerificationView() }
                .swipeToDismiss(onDismiss: { showEmailFromRoute = false })
        }
        .fullScreenCover(item: $selectedListing) { listing in
            ListingDetailView(listing: listing, source: selectedListingSource,
                              onClose: { selectedListing = nil })
        }
        // A shared annonce link opened in the app (moblyapp://annonce/<id>).
        .onReceive(NotificationCenter.default.publisher(for: ListingStore.openSharedListing)) { note in
            guard let id = note.object as? String else { return }
            openListing(id: id, from: "share")
        }
        .fullScreenCover(isPresented: $showNotifications) {
            NotificationsView(
                onOpen: { target in
                    showNotifications = false
                    // Let the cover finish dismissing before presenting the
                    // next screen, or the second one never appears.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        route(to: target)
                    }
                },
                onClose: { showNotifications = false }
            )
            .swipeToDismiss(onDismiss: { showNotifications = false })
        }
        .fullScreenCover(isPresented: $showExplore) {
            ExploreSearchView(
                onClose: { showExplore = false },
                onSelectLocation: { loc in
                    showExplore = false
                    searchCategory = nil
                    searchQuery = loc
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showSearch = true }
                }
            )
            .swipeToDismiss(onDismiss: { showExplore = false })
        }
        // Item-based, not `isPresented:`. With `isPresented:` SwiftUI built
        // the results screen with the *previous* `searchCategory` on the first
        // tap, so a quick-filter opened unfiltered and only worked the second
        // time. The request is captured after the category has been set.
        .onChange(of: showSearch) { _, open in
            searchRequest = open ? SearchRequest(category: searchCategory, query: searchQuery) : nil
        }
        .fullScreenCover(item: $searchRequest, onDismiss: { showSearch = false }) { req in
            SearchResultsView(
                initialCategory: req.category,
                initialQuery: req.query,
                onClose: { showSearch = false }
            )
            .swipeToDismiss(onDismiss: { showSearch = false })
        }
        // A tab switched off while it is on screen falls back to Accueil.
        .onChange(of: MoblyTab.visible(config)) { _, visible in
            if !visible.contains(tab) { tab = .home }
        }
        .onChange(of: push.pendingThreadId) { _, threadId in
            guard threadId != nil, config.isEnabled("chat.enabled") else { return }
            withAnimation(Motion.quick) { tab = .messages }
        }
    }
}

struct MoblyTabBar: View {
    @Binding var tab: MoblyTab
    @ObservedObject private var chat = ChatStore.shared
    @ObservedObject private var config = RemoteConfigStore.shared
    @Namespace private var pillNS

    private var unreadCount: Int {
        // Conversations with something unread, not messages: 20 messages from
        // one person is one badge. Support lives outside the inbox, so it
        // doesn't count here either.
        chat.threads.filter { $0.unread > 0 && $0.participants.first?.isSupport != true }.count
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MoblyTab.visible(config), id: \.self) { t in
                let active = t == tab
                Button {
                    withAnimation(Motion.quick) { tab = t }
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    HStack(spacing: 7) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: active ? t.iconFilled : t.icon)
                                .font(.system(size: 18, weight: active ? .semibold : .regular))
                            if t == .messages && unreadCount > 0 {
                                Text("\(min(unreadCount, 99))")
                                    .font(.moblyBody(10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 20, height: 20)
                                    .background(Color(hex: 0xEF4444), in: Circle())
                                    .offset(x: 8, y: -8)
                                    // The badge now appears on its own, from a
                                    // silent poll or the socket — it pops so
                                    // the change is noticed without a reload.
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                        if active {
                            Text(L(t.title))
                                .font(.moblyBody(12.5, weight: .semibold))
                                .lineLimit(1)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(active ? .white : Color(hex: 0x9A9DAC))
                    .padding(.horizontal, active ? 16 : 0)
                    .padding(.vertical, 12)
                    .background {
                        if active {
                            Capsule(style: .continuous)
                                .fill(Color.moblyPrimary)
                                .matchedGeometryEffect(id: "pill", in: pillNS)
                        }
                    }
                    .frame(maxWidth: active ? nil : .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .animation(Motion.pop, value: unreadCount)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .modifier(LiquidGlassBar(cornerRadius: 30))
        // y matches the radius so the drop shadow falls below and to the
        // sides only — it no longer rises above the bar.
        .shadow(color: Color(hex: 0x14152A).opacity(0.14), radius: 16, y: 16)
        // Soft white glow on the left, right and bottom so content passing
        // behind the floating bar fades into white. Not on top: the glow's
        // upper edge is pushed down past the blur radius, so nothing spills
        // above the bar as a white haze.
        .background {
            // The blurred glow is an offscreen pass every frame; older chips
            // skip it (the band below already fades content into white).
            if !DeviceTier.reducedEffects {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Color.white)
                    .padding(.horizontal, -12)
                    .padding(.bottom, -12)
                    .padding(.top, 18)
                    .blur(radius: 16)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }
}

/// Real Liquid Glass on iOS 26+ (Apple's `.glassEffect`), with a frosted
/// material fallback for older iOS.
private struct LiquidGlassBar: ViewModifier {
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if DeviceTier.reducedEffects {
            // Near-opaque instead of glass: reads the same at a glance, costs
            // nothing per frame.
            content
                .background(shape.fill(Color.white.opacity(0.97)))
                .overlay(shape.stroke(Color(hex: 0xE6E8EF), lineWidth: 1))
                .clipShape(shape)
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content
                .background(shape.fill(.ultraThinMaterial))
                .overlay(
                    shape.stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.9), Color.white.opacity(0.2)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                )
                .clipShape(shape)
        }
    }
}

private struct TabPlaceholder: View {
    let tab: MoblyTab
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: tab.iconFilled)
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Color.moblyPrimary.opacity(0.5))
            Text(tab.title)
                .font(.moblyHeading(20))
                .foregroundStyle(Color.moblyTextPrimary)
            Text("Écran à construire ensemble.")
                .font(.moblyBody(13))
                .foregroundStyle(Color.moblyTextSecondary)
        }
    }
}

#Preview {
    MainTabView()
}


/// One opening of the search results screen, with the filter it was opened for.
private struct SearchRequest: Identifiable {
    let id = UUID()
    let category: String?
    let query: String
}
