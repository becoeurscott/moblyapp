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
    @ObservedObject private var push = PushService.shared
    @ObservedObject private var callService = CallService.shared
    @State private var showAcceptedCall = false

    private func openListing(_ listing: Listing) {
        ListingStore.shared.prefetchGallery(for: listing)
        selectedListing = listing
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.white.ignoresSafeArea()

            ZStack {
                HomeView(
                    onOpenListing: { openListing($0) },
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
                        tab = .explore
                    },
                    onOpenExplore: { showExplore = true }
                )
                .opacity(tab == .home ? 1 : 0)
                .allowsHitTesting(tab == .home)

                ExploreView(
                    onOpenListing: { openListing($0) },
                    initialLocation: exploreLocation,
                    initialFilters: explorePresetFilters,
                    onLocationConsumed: {
                        exploreLocation = ""
                        explorePresetFilters = nil
                    }
                )
                .opacity(tab == .explore ? 1 : 0)
                .allowsHitTesting(tab == .explore)

                MessagesView()
                    .opacity(tab == .messages ? 1 : 0)
                    .allowsHitTesting(tab == .messages)

                FavoritesView(
                    onOpenListing: { openListing($0) },
                    onOpenSearch: { search in
                        exploreLocation = search.location
                        tab = .explore
                    },
                    onOpenSavedSearch: { item in
                        explorePresetFilters = item.filters
                        exploreLocation = item.label
                        tab = .explore
                    }
                )
                .opacity(tab == .favorites ? 1 : 0)
                .allowsHitTesting(tab == .favorites)

                ProfileView(
                    onOpenFavorites: { tab = .favorites },
                    onLogout: onLogout
                )
                .opacity(tab == .profile ? 1 : 0)
                .allowsHitTesting(tab == .profile)
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
                onClose: { showSearch = false }
            )
        }
        .onChange(of: push.pendingThreadId) { _, threadId in
            guard threadId != nil else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { tab = .messages }
        }
        .fullScreenCover(isPresented: Binding(
            get: { callService.state == .incoming },
            set: { if !$0 { callService.rejectCall() } }
        )) {
            IncomingCallView()
        }
        .onChange(of: callService.state) { old, new in
            if old == .incoming && new == .connected {
                showAcceptedCall = true
            }
            if new == .idle || new == .ended {
                showAcceptedCall = false
            }
        }
        .fullScreenCover(isPresented: $showAcceptedCall) {
            CallView(
                thread: ChatThread(
                    id: callService.threadId ?? "",
                    initial: String(callService.peerName.prefix(1)).uppercased(),
                    color: .moblyPrimary,
                    name: callService.peerName,
                    verified: false, online: true, time: "",
                    listing: "", listingTitle: "", listingPrice: "",
                    listingImage: "ListingGreen",
                    preview: "", unread: 0, fromMe: false,
                    peerId: callService.peerId
                ),
                isVideo: callService.isVideo,
                onEnd: { callService.endCall(); showAcceptedCall = false }
            )
        }
    }
}

struct MoblyTabBar: View {
    @Binding var tab: MoblyTab
    @ObservedObject private var chat = ChatStore.shared
    @Namespace private var pillNS

    private var unreadCount: Int {
        chat.threads.reduce(0) { $0 + $1.unread }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MoblyTab.allCases, id: \.self) { t in
                let active = t == tab
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) { tab = t }
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
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
