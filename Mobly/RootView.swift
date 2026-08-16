import SwiftUI
import UIKit

enum AppRoute: Hashable {
    case splash
    case onboarding
    case welcome
    case signup
    case connexion
    case detail
    case notifications
    case search
    case filters
    case explore
    case exploreMap
    case chatThread
    case call
    case profileScreen
    case ownerDashboard
    case addListing
    case ownerStats
    case placeholder
}

struct RootView: View {
    @ObservedObject private var lang = AppLang.shared
    @ObservedObject private var listingStore = ListingStore.shared
    @State private var route: AppRoute = {
        // Allow launch arg to skip splash for screenshotting: -skipSplash 1
        if ProcessInfo.processInfo.environment["START_AT"] == "welcome" {
            return .welcome
        }
        if ProcessInfo.processInfo.environment["START_AT"] == "signup" {
            return .signup
        }
        if ProcessInfo.processInfo.environment["START_AT"] == "connexion" {
            return .connexion
        }
        if ProcessInfo.processInfo.environment["START_AT"] == "home" {
            return .placeholder
        }
        if ProcessInfo.processInfo.environment["START_AT"] == "detail" {
            return .detail
        }
        if ProcessInfo.processInfo.environment["START_AT"] == "notifications" {
            return .notifications
        }
        if ProcessInfo.processInfo.environment["START_AT"] == "search" {
            return .search
        }
        if ProcessInfo.processInfo.environment["START_AT"] == "filters" {
            return .filters
        }
        if ProcessInfo.processInfo.environment["START_AT"] == "explore" {
            return .explore
        }
        if ProcessInfo.processInfo.environment["START_AT"] == "exploremap" {
            return .exploreMap
        }
        if ProcessInfo.processInfo.environment["START_AT"] == "thread" {
            return .chatThread
        }
        if ProcessInfo.processInfo.environment["START_AT"] == "call" {
            return .call
        }
        if ProcessInfo.processInfo.environment["START_AT"] == "profilescreen" {
            return .profileScreen
        }
        if ProcessInfo.processInfo.environment["START_AT"] == "owner" {
            return .ownerDashboard
        }
        if ProcessInfo.processInfo.environment["START_AT"] == "addlisting" {
            return .addListing
        }
        if ProcessInfo.processInfo.environment["START_AT"] == "ownerstats" {
            return .ownerStats
        }
        if ProcessInfo.processInfo.environment["SKIP_SPLASH"] == "1" {
            return .onboarding
        }
        return .splash
    }()

    var body: some View {
        ZStack {
            switch route {
            case .splash:
                SplashView {
                    withAnimation(.easeInOut(duration: 0.45)) {
                        route = .onboarding
                    }
                }
                .transition(.opacity)

            case .onboarding:
                OnboardingView {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        route = .welcome
                    }
                }
                .transition(.opacity)

            case .welcome:
                WelcomeView(
                    onSignUp: {
                        withAnimation(.easeInOut(duration: 0.4)) { route = .signup }
                    },
                    onSignIn: {
                        withAnimation(.easeInOut(duration: 0.4)) { route = .connexion }
                    }
                )
                .transition(.opacity)

            case .signup:
                // `.id` is load-bearing: both auth routes render ConnexionView,
                // so without distinct identities SwiftUI reuses the same view —
                // and its @State `mode` — meaning "J'ai déjà un compte" landed
                // on Inscription if the user had visited signup first.
                ConnexionView(
                    initialMode: .signup,
                    onExit: {
                        withAnimation(.easeInOut(duration: 0.4)) { route = .welcome }
                    },
                    onFinish: {
                        withAnimation(.easeInOut(duration: 0.4)) { route = .placeholder }
                    }
                )
                .id("auth-signup")
                .transition(.move(edge: .trailing).combined(with: .opacity))

            case .connexion:
                ConnexionView(
                    initialMode: .signin,
                    onExit: {
                        withAnimation(.easeInOut(duration: 0.4)) { route = .welcome }
                    },
                    onFinish: {
                        withAnimation(.easeInOut(duration: 0.4)) { route = .placeholder }
                    }
                )
                .id("auth-signin")
                .transition(.move(edge: .trailing).combined(with: .opacity))

            case .detail:
                // Debug route: show either a synthetic owner-photos listing
                // (when the DEBUG_OWNER_PHOTOS hook is set) or the first live
                // one from the store.
                if ProcessInfo.processInfo.environment["DEBUG_OWNER_PHOTOS"] == "1" {
                    ListingDetailView(listing: Self.debugOwnerListing())
                        .transition(.opacity)
                } else if let first = ListingStore.shared.listings.first {
                    ListingDetailView(listing: first)
                        .transition(.opacity)
                } else {
                    ProgressView().tint(Color.moblyPrimary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

            case .notifications:
                NotificationsView()
                    .transition(.opacity)

            case .search:
                // SEARCH_CAT=<catégorie> mimics a Home category tap; otherwise a plain query.
                if let cat = ProcessInfo.processInfo.environment["SEARCH_CAT"], !cat.isEmpty {
                    SearchResultsView(initialCategory: cat)
                        .transition(.opacity)
                } else {
                    SearchResultsView(initialQuery: "Yaoundé")
                        .transition(.opacity)
                }

            case .filters:
                FilterPanelView(filters: .constant(FilterState()))
                    .transition(.opacity)

            case .explore:
                ExploreSearchView()
                    .transition(.opacity)

            case .exploreMap:
                ExploreView()
                    .transition(.opacity)

            case .chatThread:
                PreviewChatWrapper()
                    .transition(.opacity)

            case .call:
                CallView(thread: ChatThread.preview, isVideo: false)
                    .transition(.opacity)

            case .profileScreen:
                NavigationStack {
                    Group {
                        switch ProcessInfo.processInfo.environment["PROFILE_SCREEN"] {
                        case "edit": EditProfileView()
                        case "notif": NotificationsSettingsView()
                        case "privacy": PrivacySecurityView()
                        case "about": AboutView()
                        case "legal": LegalHubView()
                        case "legaldoc":
                            LegalDocumentView(doc: LegalLibrary.doc(ProcessInfo.processInfo.environment["LEGAL_DOC"] ?? "cgu") ?? LegalLibrary.cgu)
                        case "identity": IdentityVerificationView()
                        case "language": LanguageView()
                        default: BecomeOwnerView()
                        }
                    }
                }
                .transition(.opacity)

            case .ownerDashboard:
                NavigationStack { OwnerDashboardView() }
                    .transition(.opacity)

            case .addListing:
                AddListingView { _ in }
                    .transition(.opacity)

            case .ownerStats:
                NavigationStack { OwnerStatsView(annonce: OwnerListings.shared.annonces[0]) }
                    .transition(.opacity)

            case .placeholder:
                MainTabView(onLogout: {
                    withAnimation(.easeInOut(duration: 0.4)) { route = .welcome }
                })
                .transition(.opacity)
            }
        }
        // Drive SwiftUI's own localisation from the in-app picker.
        //
        // `Text("…")`, `Button("…")`, `navigationTitle("…")` etc. all take a
        // LocalizedStringKey and resolve it against the String Catalog using
        // THIS environment locale — so setting it here translates every
        // built-in call site in the app without touching a single one of them.
        // Without it the catalog would follow the iOS system language and the
        // in-app picker would do nothing.
        .environment(\.locale, Locale(identifier: lang.code))
        // Belt-and-braces full rebuild so anything reading AppLang directly
        // (the legacy `L(...)` helper) re-evaluates in the same beat.
        .id(lang.code)
        .overlay {
            if AppLang.shared.switching { languageSwitchingOverlay }
        }
        // A refresh the server refuses (revoked family, reuse detection, or a
        // 30-day-old token) posts `sessionExpired`. AuthStore nils the user
        // and ChatStore stops, but nothing moved the UI — the user was left
        // sitting in the signed-in tab bar where every request 401s. Bounce
        // them to Welcome so they can sign in again.
        .onReceive(NotificationCenter.default.publisher(for: MoblyAPI.sessionExpired)) { _ in
            guard route == .placeholder else { return }
            withAnimation(.easeInOut(duration: 0.4)) { route = .welcome }
        }
    }

    /// Full-screen scrim shown while `AppLang.switching == true` so the
    /// user sees the switch is in progress across the whole app, not just
    /// on the Language screen.
    private var languageSwitchingOverlay: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().scaleEffect(1.3).tint(Color.moblyPrimary)
                Text(L("Changement de langue…"))
                    .font(.moblyBody(14, weight: .medium))
                    .foregroundStyle(Color.moblyTextPrimary)
            }
            .padding(26)
            .background(RoundedRectangle(cornerRadius: 20).fill(.white)
                .shadow(color: Color(hex: 0x14152A).opacity(0.15), radius: 20, y: 8))
        }
        .transition(.opacity)
    }

    /// Build a synthetic owner-published listing with 5 sample photos saved
    /// to disk via `OwnerPhotoStore`. Used by the `DEBUG_OWNER_PHOTOS=1`
    /// debug hook to verify the customPhotos → file:// → gallery pipeline
    /// without walking through the publish wizard by hand.
    private static func debugOwnerListing() -> Listing {
        let cover = ["ListingGreen","ListingPink","ListingYellow","ListingTwilight","ListingLoft"]
        let datas: [Data] = cover.compactMap { UIImage(named: $0)?.jpegData(compressionQuality: 0.85) }
        var listing = Listing(
            id: "debug-owner-photos",
            title: "Studio Akwa — photos owner",
            location: "Akwa, Douala",
            price: "80 000 FCFA",
            rating: "4.7",
            imageName: "ListingGreen",
            category: "Studios",
            subtitle: "Meublé · 1 ch",
            about: "Studio moderne au cœur d'Akwa. Toutes les photos ci-dessous sont des photos que le propriétaire a téléversées."
        )
        listing.customPhotos = datas
        listing.customImageData = datas.first
        let urls = OwnerPhotoStore.save(datas, id: listing.id)
        listing.photos = urls.map { $0.absoluteString }
        return listing
    }
}

private struct PostSplashPlaceholder: View {
    var body: some View {
        ZStack {
            Color.moblySurface.ignoresSafeArea()
            VStack(spacing: 12) {
                Text("mobly")
                    .font(.moblyWordmark(size: 40))
                    .foregroundStyle(Color.moblyPrimary)
                Text("Prochain écran à valider ensemble.")
                    .font(.moblyBody())
                    .foregroundStyle(Color.moblyTextSecondary)
            }
        }
    }
}

#Preview {
    RootView()
}

/// Wrapper for the `START_AT=thread` debug route. Seeds the auth user and a
/// small set of demo messages synchronously in `init()` so the first render of
/// `ChatThreadView` already sees `auth.user` set and `chat.messages` populated
/// — otherwise the first frame would compute `fromMe = false` for every bubble
/// and the subsequent auth update would leave stale inner-view state.
private struct PreviewChatWrapper: View {
    init() {
        #if DEBUG
        let id = ChatThread.preview.id
        let me = "me"
        let peer = "peer"
        let now = Date()
        AuthStore.shared.debugSetUser(id: me, name: "Moi")
        ChatStore.shared.debugSeed(threadId: id, messages: [
            MessageDTO(id: "d1", threadId: id, senderId: peer, clientId: nil,
                       kind: "TEXT", text: "Bonjour, l'appartement est-il disponible ?",
                       mediaUrl: nil, durationSec: nil, replyToId: nil, visitId: nil,
                       visitAction: nil, read: true, readAt: nil,
                       createdAt: now.addingTimeInterval(-600)),
            MessageDTO(id: "d2", threadId: id, senderId: me, clientId: nil,
                       kind: "TEXT", text: "Oui, il l'est. Je vous envoie une note vocale.",
                       mediaUrl: nil, durationSec: nil, replyToId: nil, visitId: nil,
                       visitAction: nil, read: true, readAt: nil,
                       createdAt: now.addingTimeInterval(-540)),
            MessageDTO(id: "d3", threadId: id, senderId: me, clientId: nil,
                       kind: "TEXT", text: "🎤 Note vocale (0:18)",
                       mediaUrl: nil, durationSec: 18, replyToId: nil, visitId: nil,
                       visitAction: nil, read: true, readAt: nil,
                       createdAt: now.addingTimeInterval(-500)),
            MessageDTO(id: "d4", threadId: id, senderId: peer, clientId: nil,
                       kind: "TEXT", text: "🎤 Note vocale (0:07)",
                       mediaUrl: nil, durationSec: 7, replyToId: nil, visitId: nil,
                       visitAction: nil, read: true, readAt: nil,
                       createdAt: now.addingTimeInterval(-400)),
            MessageDTO(id: "d5", threadId: id, senderId: me, clientId: nil,
                       kind: "TEXT",
                       text: "📍 Ma position: https://www.google.com/maps?q=4.048200,9.703700",
                       mediaUrl: nil, durationSec: nil, replyToId: nil, visitId: nil,
                       visitAction: nil, read: true, readAt: nil,
                       createdAt: now.addingTimeInterval(-120)),
        ])
        #endif
    }
    var body: some View { ChatThreadView(thread: ChatThread.preview) }
}
