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
}

struct MainTabView: View {
    var onLogout: () -> Void = {}

    // Observe language so a switch re-renders the visible tab live, without the
    // global root `.id(lang.code)` reset (which used to tear down navigation).
    @ObservedObject private var lang = AppLang.shared
    @ObservedObject private var chrome = AppChrome.shared

    @State private var tab: MoblyTab = {
        if ProcessInfo.processInfo.environment["MAIN_TAB"] == "explore" { return .explore }
        if ProcessInfo.processInfo.environment["MAIN_TAB"] == "messages" { return .messages }
        if ProcessInfo.processInfo.environment["MAIN_TAB"] == "favorites" { return .favorites }
        if ProcessInfo.processInfo.environment["MAIN_TAB"] == "profile" { return .profile }
        return .home
    }()
    @State private var selectedListing: Listing?
    @State private var showNotifications = false
    @State private var showSearch = false
    @State private var searchCategory: String?
    @State private var searchQuery: String = ""
    @State private var showExplore = false
    @State private var exploreLocation = ""
    /// FilterState to apply the next time Explore renders. Set when the
    /// user taps a saved recherche in Favoris.
    @State private var explorePresetFilters: FilterState? = nil

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.white.ignoresSafeArea()

            Group {
                switch tab {
                case .home:
                    HomeView(
                        onOpenListing: { selectedListing = $0 },
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
                            exploreLocation = city
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { tab = .explore }
                        },
                        onOpenExplore: { showExplore = true }
                    )
                case .explore:
                    ExploreView(
                        onOpenListing: { selectedListing = $0 },
                        initialLocation: exploreLocation,
                        initialFilters: explorePresetFilters,
                        onLocationConsumed: {
                            exploreLocation = ""
                            explorePresetFilters = nil
                        }
                    )
                case .messages:
                    MessagesView()
                case .favorites:
                    FavoritesView(
                        onOpenListing: { selectedListing = $0 },
                        onOpenSearch: { search in
                            exploreLocation = search.location
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { tab = .explore }
                        },
                        onOpenSavedSearch: { item in
                            explorePresetFilters = item.filters
                            // Non-empty string so `onLocationConsumed`
                            // clears both after Explore reads them.
                            exploreLocation = item.label
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { tab = .explore }
                        }
                    )
                case .profile:
                    ProfileView(
                        onOpenFavorites: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { tab = .favorites }
                        },
                        onLogout: onLogout
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !chrome.hideTabBar {
                MoblyTabBar(tab: $tab)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: chrome.hideTabBar)
        .ignoresSafeArea(.keyboard)
        .onAppear { SessionTracker.shared.log("screen.view", ["screen": "\(tab)"]) }
        .onChange(of: tab) { _, new in
            SessionTracker.shared.log("screen.view", ["screen": "\(new)"])
        }
        .fullScreenCover(item: $selectedListing) { listing in
            ListingDetailView(listing: listing, onClose: { selectedListing = nil })
                .transition(.move(edge: .bottom))
        }
        .fullScreenCover(isPresented: $showNotifications) {
            NotificationsView(onClose: { showNotifications = false })
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
        }
        .fullScreenCover(isPresented: $showSearch) {
            SearchResultsView(
                initialCategory: searchCategory,
                initialQuery: searchQuery,
                onClose: { showSearch = false },
                onOpenListing: { listing in
                    showSearch = false
                    // present detail after the search sheet dismisses
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        selectedListing = listing
                    }
                }
            )
        }
    }
}

struct MoblyTabBar: View {
    @Binding var tab: MoblyTab
    @ObservedObject private var chat = ChatStore.shared
    private var hasUnread: Bool { chat.threads.contains { $0.unread > 0 } }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MoblyTab.allCases, id: \.self) { t in
                let active = t == tab
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { tab = t }
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            Image(systemName: active ? t.iconFilled : t.icon)
                                .font(.system(size: 20, weight: .medium))
                                .overlay(alignment: .topTrailing) {
                                    if t == .messages && hasUnread {
                                        Circle().fill(Color.moblyAccent)
                                            .frame(width: 7, height: 7)
                                            .offset(x: 5, y: -2)
                                    }
                                }
                        }
                        Text(L(t.title))
                            .font(.moblyBody(9.5, weight: active ? .semibold : .regular))
                    }
                    .foregroundStyle(active ? Color.moblyPrimary : Color(hex: 0x9A9DAC))
                    // This padding used to sit on the HStack. Moved inside the
                    // button so it belongs to the tap target instead of the bar
                    // — same bar height, but each cell is now ~61pt tall rather
                    // than the ~37pt of glyph+label.
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    // Without this, only the opaque pixels of the icon and text
                    // accept touches, so taps beside the glyph fall through and
                    // the tab appears not to respond.
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .modifier(LiquidGlassBar(cornerRadius: 30))
        .shadow(color: Color(hex: 0x14152A).opacity(0.14), radius: 20, y: 8)
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
        if #available(iOS 26.0, *) {
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
