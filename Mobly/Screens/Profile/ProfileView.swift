import SwiftUI

private struct MenuItem: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    let iconBg: UInt32
    let iconColor: UInt32
    var value: String? = nil
    var chevron: Bool = true
    var danger: Bool = false
    var route: ProfileRoute? = nil
}

struct ProfileView: View {
    var onOpenFavorites: () -> Void = {}
    var onLogout: () -> Void = {}

    @ObservedObject private var session = Session.shared
    @ObservedObject private var identity = IdentityVerificationStore.shared
    @ObservedObject private var lang = AppLang.shared
    @ObservedObject private var config = RemoteConfigStore.shared

    @State private var showBecomeOwner = false
    /// Opened after a first annonce is published from the become-owner flow.
    @State private var goToOwnerDashboard = false
    /// Tapped "Devenir propriétaire" without a verified identity.
    @State private var askIdentityFirst = false
    @State private var goToIdentity = false

    /// Logout is a three-beat flow: confirm → sign out (spinner) → goodbye
    /// card, then RootView takes over and returns to Welcome.
    @State private var confirmLogout = false
    @State private var loggingOut = false
    @State private var saidGoodbye = false
    /// Snapshot of the user's first name, taken before sign-out wipes it.
    @State private var farewellName = ""

    /// Computed, not constant: the identity row used to hard-code the value
    /// "Vérifié", so an account that had never passed the check still showed a
    /// green "Vérifié" next to it — directly contradicting the red "Identité
    /// non vérifiée" badge on the card a few points above it.
    private var account: [MenuItem] { [
        MenuItem(label: "Modifier le profil", icon: "square.and.pencil", iconBg: 0xEEF0FE, iconColor: 0x3A4FF0, route: .editProfile),
        !identityVerified && !config.isEnabled("identity.verification") ? nil : MenuItem(label: "Vérification d'identité",
                 icon: identityVerified ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
                 iconBg: identityVerified ? 0xE9F9EF : 0xFFF4E5,
                 iconColor: identityVerified ? 0x1F8A5B : 0xE5950C,
                 value: identityVerified ? "Vérifié" : "Non vérifié",
                 route: .identity),
        MenuItem(label: "Adresse e-mail",
                 icon: emailVerified ? "envelope.badge.shield.half.filled" : "envelope",
                 iconBg: emailVerified ? 0xE9F9EF : 0xFFF4E5,
                 iconColor: emailVerified ? 0x1F8A5B : 0xE5950C,
                 value: emailVerified ? "Vérifiée" : "À confirmer",
                 route: .email),
    ].compactMap { $0 } }
    private var emailVerified: Bool { auth.user?.emailVerified ?? false }
    /// Computed so the Langue row can show the language the user is actually
    /// on — and so it can be hidden entirely while `selectionEnabled` is off.
    /// The row is gated rather than deleted: the String Catalog and the
    /// locale wiring are still there, so re-enabling is a one-line change.
    private var prefs: [MenuItem] { [
        AppLang.selectionEnabled
            ? MenuItem(label: "Langue", icon: "globe", iconBg: 0xEAF3FF, iconColor: 0x4C9BFF,
                       value: lang.code == "en" ? "English" : "Français", route: .language)
            : nil,
        config.isEnabled("notifications.push")
            ? MenuItem(label: "Notifications", icon: "bell.fill", iconBg: 0xEEF0FE, iconColor: 0x3A4FF0, route: .notifications)
            : nil,
        config.isEnabled("search.savedSearches")
            ? MenuItem(label: "Recherches enregistrées", icon: "magnifyingglass", iconBg: 0xEEF0FE, iconColor: 0x3A4FF0, route: .savedSearches)
            : nil,
    ].compactMap { $0 } }
    private let support: [MenuItem] = [
        MenuItem(label: "Centre d'aide", icon: "questionmark.circle", iconBg: 0xEEF0FE, iconColor: 0x3A4FF0, route: .help),
        MenuItem(label: "Confidentialité & sécurité", icon: "lock.shield", iconBg: 0xEEF0FE, iconColor: 0x3A4FF0, route: .privacy),
        MenuItem(label: "À propos de Mobly", icon: "info.circle", iconBg: 0xEEF0FE, iconColor: 0x3A4FF0, route: .about),
        MenuItem(label: "Déconnexion", icon: "rectangle.portrait.and.arrow.right", iconBg: 0xFDEDED, iconColor: 0xE5484D, chevron: false, danger: true),
    ]

    var body: some View {
        ZStack {
            NavigationStack {
                content
                    .navigationDestination(for: ProfileRoute.self) { route in
                        switch route {
                        case .editProfile:  EditProfileView()
                        case .identity:     IdentityVerificationView()
                        case .email:        EmailVerificationView()
                        case .language:     LanguageView()
                        case .notifications: NotificationsSettingsView()
                        case .savedSearches: SavedSearchesView()
                        case .help:         HelpCenterView()
                        case .privacy:      PrivacySecurityView()
                        case .about:        AboutView()
                        case .becomeOwner:  BecomeOwnerView()   // legacy, unused now
                        case .ownerDashboard: OwnerDashboardView()
                        }
                    }
            }

            if loggingOut || saidGoodbye { logoutOverlay }
        }
        .animation(Motion.quick, value: loggingOut)
        .animation(Motion.panel, value: saidGoodbye)
        // `alert`, not `confirmationDialog`: a confirmation dialog is an action
        // sheet on iPhone, so it slid up from the bottom edge. Every other
        // destructive confirmation in the app is a centred alert, and this one
        // sat apart from them.
        .alert("Se déconnecter de Mobly ?", isPresented: $confirmLogout) {
            Button("Se déconnecter", role: .destructive) { performLogout() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Vous devrez vous reconnecter pour accéder à vos messages et à vos favoris.")
        }
        .alert("Vérifiez votre identité", isPresented: $askIdentityFirst) {
            Button("Vérifier maintenant") { goToIdentity = true }
            Button("Plus tard", role: .cancel) {}
        } message: {
            Text("Pour publier un espace sur Mobly, votre pièce d'identité doit d'abord être vérifiée. Cela protège les visiteurs et rassure vos futurs locataires.")
        }
        .navigationDestination(isPresented: $goToIdentity) { IdentityVerificationView() }
        .fullScreenCover(isPresented: $showBecomeOwner) {
            BecomeOwnerView(
                onClose: { showBecomeOwner = false },
                onPublished: {
                    showBecomeOwner = false
                    // After the cover finishes dismissing, land on the dashboard.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { goToOwnerDashboard = true }
                }
            )
            .swipeToDismiss(onDismiss: { showBecomeOwner = false })
        }
        // Full screen, like Home: pushing it inside this stack left the tab
        // bar showing over the dashboard.
        .fullScreenCover(isPresented: $goToOwnerDashboard) { OwnerDashboardCover() }

        .onAppear {
            if ProcessInfo.processInfo.environment["OPEN_BECOME_OWNER"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    showBecomeOwner = true
                }
            }

        }
    }

    private var content: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Text(L("Profil"))
                    .font(.moblyHeading(26))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 22)

                identityCard
                    .padding(.bottom, 18)

                stats
                    .padding(.bottom, 22)

                if auth.isRestoringSession {
                    restoreSessionCTA.padding(.bottom, 22)
                } else if session.isOwner {
                    ownerDashboardCTA.padding(.bottom, 22)
                } else if config.isEnabled("owners.signup") {
                    becomeOwnerCTA.padding(.bottom, 22)
                }


                menuGroup("COMPTE", account)
                menuGroup("PRÉFÉRENCES", prefs)
                menuGroup("SUPPORT", support)

                Text("Mobly v1.0.0 · Trouvez votre espace.")
                    .font(.moblyBody(11.5))
                    .foregroundStyle(Color(hex: 0xC4C7D2))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 110)
        }
        .refreshable {
            // In parallel. These three touch different endpoints and none reads
            // the others' result, but they used to be awaited one after the
            // next — so the screen cost the SUM of three round trips instead of
            // the slowest one. At Cameroon-to-Oregon latency that is the
            // difference between one wait and three, and against a cold backend
            // it stacked three separate wake-ups.
            async let me: Void = AuthStore.shared.bootstrap()
            async let favs: Void = UserDataStore.shared.loadFavorites(silent: true)
            async let kyc: Void = identity.refresh()
            _ = await (me, favs, kyc)
        }
        // Keep the badge honest when the screen is opened: a decision may have
        // landed while the user was elsewhere in the app.
        .task { await identity.refresh() }
        .background(Color.moblySurface)
    }

    // MARK: Identity card

    @ObservedObject private var auth = AuthStore.shared
    @ObservedObject private var userData = UserDataStore.shared

    /// From the server. `verified` only means the phone was confirmed, so the
    /// identity badge reads `identityVerified` — the result of the KYC check.
    private var identityVerified: Bool { auth.user?.identityVerified ?? false }

    /// How the identity row should read right now.
    ///
    /// It used to be binary — vérifié or non vérifié — so an owner who had
    /// submitted their documents and was waiting on a decision saw a red dot
    /// reading "Identité non vérifiée", which looks like the submission was
    /// lost. The KYC flow has five outcomes and the badge now shows the one
    /// the account is actually in.
    private var identityState: (label: String, dot: Color, cta: String?, spins: Bool) {
        if identityVerified {
            return ("Identité vérifiée", Color(hex: 0x34C759), nil, false)
        }
        switch identity.status {
        case .pending, .inReview:
            return ("Vérification en cours", Color(hex: 0xE5950C), "Suivre", true)
        case .declined:
            return ("Vérification refusée", Color(hex: 0xE5484D), "Réessayer", false)
        case .approved:
            // Approved server-side but the cached user hasn't caught up yet.
            return ("Identité vérifiée", Color(hex: 0x34C759), nil, false)
        case .abandoned, .none:
            return ("Identité non vérifiée", Color(hex: 0xE5484D), "Vérifier", false)
        }
    }

    // "Invité" is a statement of fact about the account, so it waits until the
    // session has actually been checked. While the check is in flight the card
    // stays deliberately neutral rather than asserting either way.
    private var displayName: String {
        if let name = auth.user?.fullName { return name }
        return auth.isRestoringSession ? "…" : "Invité"
    }
    private var displayCity: String {
        if auth.isSignedIn { return Session.shared.phone }
        return auth.isRestoringSession ? "Connexion…" : "Non connecté"
    }

    private var identityCard: some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                ZStack {
                    // Uploaded avatar takes precedence; falls back to the
                    // initials-on-tinted-glass style used before an upload.
                    if let url = auth.user?.avatarUrl, let u = URL(string: url) {
                        AsyncImage(url: u) { phase in
                            switch phase {
                            case .success(let img): img.resizable().scaledToFill()
                            default:
                                Circle().fill(Color.white.opacity(0.18))
                                    .overlay(Text(String(displayName.prefix(2)).uppercased())
                                        .font(.moblyHeading(22))
                                        .foregroundStyle(.white))
                            }
                        }
                        .frame(width: 62, height: 62)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.5), lineWidth: 2))
                    } else {
                        Circle().fill(Color.white.opacity(0.18))
                            .overlay(Circle().stroke(Color.white.opacity(0.5), lineWidth: 2))
                        Text(String(displayName.prefix(2)).uppercased())
                            .font(.moblyHeading(22))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 62, height: 62)

                VStack(alignment: .leading, spacing: 3) {
                    Text(LT(displayName)).font(.moblyHeading(18)).foregroundStyle(.white)
                    Text(LT(displayCity))
                        .font(.moblyBody(12.5))
                        .foregroundStyle(Color.white.opacity(0.75))
                }
                Spacer()
            }

            // Tappable: an unverified account is one step from the badge, and
            // this row is where the user looks when they wonder why it's red.
            NavigationLink(value: ProfileRoute.identity) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(identityState.dot)
                        .frame(width: 10, height: 10)
                    Text(LT(identityState.label))
                        .font(.moblyBody(12, weight: .medium)).foregroundStyle(.white)
                    if identityState.spins {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.white)
                    }
                    Spacer()
                    if let cta = identityState.cta {
                        Text(LT(cta))
                            .font(.moblyBody(12, weight: .semibold))
                            .foregroundStyle(.white)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.8))
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.14)))
                .contentShape(Rectangle())
                .animation(Motion.standard, value: identityState.label)
            }
            .buttonStyle(.plain)
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 22).fill(
                LinearGradient(colors: AvatarPalette.gradient(
                    for: auth.user?.id ?? "self", stored: auth.user?.avatarColor
                ), startPoint: .topLeading, endPoint: .bottomTrailing)
            )
        )
        .shadow(color: AvatarPalette.color(
            for: auth.user?.id ?? "self", stored: auth.user?.avatarColor
        ).opacity(0.28), radius: 22, y: 12)
    }

    // MARK: Stats

    private var stats: some View {
        HStack(spacing: 10) {
            // Real counts. These were "5 / 2 / 8" on every account, including
            // accounts that had never favourited anything.
            statCard("\(userData.favorites.count)", "Préférés")
            statCard("\(FavoritesData.searches.count)", "Recherches")
            statCard("\(userData.notifications.count)", "Notifications")
        }
    }

    private func statCard(_ v: String, _ l: String) -> some View {
        VStack(spacing: 2) {
            Text(LT(v)).font(.moblyHeading(19)).foregroundStyle(Color.moblyTextPrimary)
            Text(LT(l)).font(.moblyBody(10.5)).foregroundStyle(Color(hex: 0x9A9DAC))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 16).fill(.white))
        .shadow(color: Color(hex: 0x14152A).opacity(0.05), radius: 8, y: 2)
    }

    // MARK: Become owner CTA (visitor)

    private var restoreSessionCTA: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(Color.moblyPrimary)
            Text("Connexion en cours…")
                .font(.moblyBody(13.5, weight: .semibold))
                .foregroundStyle(Color.moblyTextPrimary)
            Spacer()
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18).fill(.white))
        .shadow(color: Color(hex: 0x14152A).opacity(0.05), radius: 8, y: 2)
    }

    // Same entry as the Home card: the onboarding flow itself walks the user
    // through the identity check before anything is published.
    private var becomeOwnerCTA: some View {
        promoCard(icon: "sparkles",
                  title: "Devenir propriétaire",
                  subtitle: "Publiez votre espace. 7\u{00A0}jours d'essai gratuit.",
                  cta: "Commencer") {
            showBecomeOwner = true
        }
    }

    // MARK: Owner dashboard CTA (owner)

    private var ownerDashboardCTA: some View {
        promoCard(icon: "square.grid.2x2.fill",
                  title: "Mon espace propriétaire",
                  subtitle: "Annonces, visites et statistiques.",
                  cta: "Ouvrir") {
            goToOwnerDashboard = true
        }
    }

    /// Dark promo card shared by both states, so "become an owner" and "your
    /// owner space" read as the same place: icon, title, one line of value,
    /// and an outlined pill on the right. The whole card is the button.
    private func promoCard(icon: String, title: String, subtitle: String, cta: String,
                           action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x3D7BFF))
                    .frame(width: 34)

                VStack(alignment: .leading, spacing: 5) {
                    Text(LT(title))
                        .font(.moblyHeading(15.5))
                        .foregroundStyle(.white)
                    Text(LT(subtitle))
                        .font(.moblyBody(11.5))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                HStack(spacing: 3) {
                    Text(LT(cta)).font(.moblyBody(11.5, weight: .semibold))
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(Capsule().fill(.white.opacity(0.1)))
                .overlay(Capsule().stroke(.white.opacity(0.3), lineWidth: 1))
                .fixedSize()
            }
            .padding(.horizontal, 18).padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(colors: [Color(hex: 0x111114), Color(hex: 0x34343C)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: Color(hex: 0x14152A).opacity(0.18), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
    }

    // MARK: Menu group

    private func menuGroup(_ title: String, _ items: [MenuItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(LT(title))
                .font(.moblyBody(12, weight: .semibold))
                .foregroundStyle(Color(hex: 0x9A9DAC))
                .tracking(0.3)
                .padding(.horizontal, 4).padding(.bottom, 9)

            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    Group {
                        if let route = item.route {
                            NavigationLink(value: route) { menuRow(item) }
                                .buttonStyle(.plain)
                        } else {
                            Button { handleTap(item) } label: { menuRow(item) }
                                .buttonStyle(.plain)
                        }
                    }
                    if i < items.count - 1 {
                        Rectangle().fill(Color(hex: 0xF1F2F6)).frame(height: 1).padding(.leading, 63)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 18).fill(.white))
            .shadow(color: Color(hex: 0x14152A).opacity(0.05), radius: 8, y: 2)
            .padding(.bottom, 20)
        }
    }

    private func menuRow(_ item: MenuItem) -> some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color(hex: item.iconBg))
                Image(systemName: item.icon).font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(hex: item.iconColor))
            }.frame(width: 34, height: 34)

            Text(LT(item.label))
                .font(.moblyBody(13.5, weight: .medium))
                .foregroundStyle(item.danger ? Color(hex: 0xE5484D) : Color.moblyTextPrimary)
            Spacer()
            if let v = item.value {
                Text(LT(v)).font(.moblyBody(12.5)).foregroundStyle(Color(hex: 0x9A9DAC))
            }
            if item.chevron {
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xC4C7D2))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private func handleTap(_ item: MenuItem) {
        if item.label == "Mes préférés" { onOpenFavorites() }
        // Never sign out on the raw tap — always confirm first.
        if item.label == "Déconnexion" {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            confirmLogout = true
        }
    }

    // MARK: Logout

    /// Sign out for real, then show the goodbye card before handing control
    /// back to RootView.
    ///
    /// The previous implementation only called `onLogout()` — which just
    /// flipped the route to Welcome. The Keychain token, chat cache and
    /// cached user data all survived, so the next launch silently restored
    /// the session and the *next* person on the device could read the
    /// previous user's conversations. `AuthStore.signOut()` is what actually
    /// revokes the token and wipes local state.
    private func performLogout() {
        // Capture the name BEFORE signing out. `signOut()` nils AuthStore.user
        // and calls Session.signOutLocal(), so reading it afterwards always
        // yields the fallback and the personalised farewell would be dead code.
        farewellName = firstName
        loggingOut = true
        // Hide the custom tab bar for the whole flow: it is a sibling of the
        // tab content in MainTabView's ZStack and would otherwise render at
        // full brightness ON TOP of the scrim — and stay tappable, letting a
        // tab switch tear down ProfileView mid-logout and strand the Task.
        AppChrome.shared.hideTabBar = true
        Task {
            // Cap the wait. `signOut()` makes two best-effort network calls
            // (DELETE /devices then POST /auth/logout) at 15s each, so on a
            // stalled connection the spinner could sit for ~30s. Local state
            // is wiped regardless, so racing a timeout is safe: we stop
            // *waiting*, we don't stop the sign-out.
            let signOut = Task { await AuthStore.shared.signOut() }
            let timeout = Task { try? await Task.sleep(nanoseconds: 4_000_000_000) }
            _ = await withTaskGroup(of: Void.self) { group in
                group.addTask { await signOut.value }
                group.addTask { await timeout.value }
                await group.next()      // whichever finishes first
                group.cancelAll()
            }
            await MainActor.run {
                loggingOut = false
                saidGoodbye = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            // Hold the farewell just long enough to read, then let RootView
            // animate back to the Welcome screen.
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            await MainActor.run {
                saidGoodbye = false
                AppChrome.shared.hideTabBar = false
                onLogout()
            }
        }
    }

    private var logoutOverlay: some View {
        ZStack {
            // Opaque, not translucent: signing out flips the identity card to
            // "Invité / Non connecté", zeroes the stats and turns the
            // verification dot red. Behind a see-through scrim the user would
            // watch their profile visibly disassemble while being told
            // goodbye. A solid backdrop keeps the farewell calm.
            Color.moblySurface.ignoresSafeArea()
            VStack(spacing: 14) {
                if saidGoodbye {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [Color.moblyPrimary, Color(hex: 0x2A3ADB)],
                                                 startPoint: .top, endPoint: .bottom))
                            .frame(width: 70, height: 70)
                        Image(systemName: "hand.wave.fill")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .transition(.scale.combined(with: .opacity))
                    VStack(spacing: 4) {
                        Text("À bientôt \(farewellName)")
                            .font(.moblyHeading(17))
                            .foregroundStyle(Color.moblyTextPrimary)
                        Text("Merci d'avoir utilisé Mobly.")
                            .font(.moblyBody(13))
                            .foregroundStyle(Color(hex: 0x9A9DAC))
                    }
                } else {
                    ProgressView()
                        .scaleEffect(1.4)
                        .tint(Color.moblyPrimary)
                    Text("Déconnexion…")
                        .font(.moblyHeading(14))
                        .foregroundStyle(Color.moblyTextPrimary)
                }
            }
            .padding(.horizontal, 34).padding(.vertical, 28)
            .background(RoundedRectangle(cornerRadius: 22).fill(.white)
                .shadow(color: .black.opacity(0.18), radius: 22, y: 10))
        }
        .transition(.opacity)
        // Swallow taps so nothing behind the farewell is interactive.
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    /// First name for the farewell — falls back to a neutral greeting when
    /// the account has no name (or the user was browsing as a guest).
    private var firstName: String {
        let full = AuthStore.shared.user?.fullName ?? Session.shared.fullName
        let first = full.split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? "et à très vite" : first
    }
}

#Preview {
    ProfileView()
}
