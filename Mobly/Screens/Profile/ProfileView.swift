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
    @ObservedObject private var lang = AppLang.shared

    @State private var showBecomeOwner = false

    /// Logout is a three-beat flow: confirm → sign out (spinner) → goodbye
    /// card, then RootView takes over and returns to Welcome.
    @State private var confirmLogout = false
    @State private var loggingOut = false
    @State private var saidGoodbye = false
    /// Snapshot of the user's first name, taken before sign-out wipes it.
    @State private var farewellName = ""

    private let account: [MenuItem] = [
        MenuItem(label: "Modifier le profil", icon: "square.and.pencil", iconBg: 0xEEF0FE, iconColor: 0x3A4FF0, route: .editProfile),
        MenuItem(label: "Vérification d'identité", icon: "checkmark.shield.fill", iconBg: 0xE9F9EF, iconColor: 0x1F8A5B, value: "Vérifié", route: .identity),
        MenuItem(label: "Mes préférés", icon: "heart.fill", iconBg: 0xFDEDED, iconColor: 0xE5484D, value: "5"),
    ]
    /// Computed so the Langue row can show the language the user is actually
    /// on — and so it can be hidden entirely while `selectionEnabled` is off.
    /// The row is gated rather than deleted: the String Catalog and the
    /// locale wiring are still there, so re-enabling is a one-line change.
    private var prefs: [MenuItem] { [
        AppLang.selectionEnabled
            ? MenuItem(label: "Langue", icon: "globe", iconBg: 0xFFF3EC, iconColor: 0xFF6B35,
                       value: lang.code == "en" ? "English" : "Français", route: .language)
            : nil,
        MenuItem(label: "Notifications", icon: "bell.fill", iconBg: 0xEEF0FE, iconColor: 0x3A4FF0, route: .notifications),
        MenuItem(label: "Recherches enregistrées", icon: "magnifyingglass", iconBg: 0xEEF0FE, iconColor: 0x3A4FF0, route: .savedSearches),
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
        .animation(.easeInOut(duration: 0.25), value: loggingOut)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: saidGoodbye)
        .confirmationDialog("Se déconnecter de Mobly ?",
                            isPresented: $confirmLogout,
                            titleVisibility: .visible) {
            Button("Se déconnecter", role: .destructive) { performLogout() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Vous devrez vous reconnecter pour accéder à vos messages et à vos favoris.")
        }
        .fullScreenCover(isPresented: $showBecomeOwner) {
            BecomeOwnerView(onClose: { showBecomeOwner = false })
        }

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

                Group {
                    if session.isOwner { ownerDashboardCTA } else { becomeOwnerCTA }
                }
                .padding(.bottom, 22)


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
        .background(Color.moblySurface)
    }

    // MARK: Identity card

    @ObservedObject private var auth = AuthStore.shared
    @ObservedObject private var userData = UserDataStore.shared

    /// From the server. `verified` only means the phone was confirmed, so the
    /// identity badge reads `identityVerified` — the result of the KYC check.
    private var identityVerified: Bool { auth.user?.identityVerified ?? false }

    private var displayName: String { auth.user?.fullName ?? "Invité" }
    private var displayCity: String { auth.isSignedIn ? Session.shared.phone : "Non connecté" }

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
                        .fill(identityVerified ? Color(hex: 0x34C759) : Color(hex: 0xE5484D))
                        .frame(width: 10, height: 10)
                    Text(LT(identityVerified ? "Identité vérifiée" : "Identité non vérifiée"))
                        .font(.moblyBody(12, weight: .medium)).foregroundStyle(.white)
                    Spacer()
                    if !identityVerified {
                        Text(LT("Vérifier"))
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

    private var becomeOwnerCTA: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showBecomeOwner = true
        } label: {
            ZStack(alignment: .topTrailing) {
                // Decorative floating house — echoes the accent tint without
                // asking for a photo asset. Kept low-opacity so text stays legible.
                Image(systemName: "house.fill")
                    .font(.system(size: 130, weight: .regular))
                    .foregroundStyle(.white.opacity(0.08))
                    .rotationEffect(.degrees(-12))
                    .offset(x: 30, y: -20)

                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .bold))
                        Text("NOUVEAU").font(.moblyBody(10, weight: .bold)).tracking(0.8)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(.white.opacity(0.22)))

                    Text("Devenez propriétaire\nsur Mobly")
                        .font(.moblyHeading(21))
                        .foregroundStyle(.white)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Publiez gratuitement et touchez des milliers de locataires vérifiés au Cameroun.")
                        .font(.moblyBody(12.5))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        Text("Commencer")
                            .font(.moblyHeading(13.5))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(Color.moblyAccent)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Capsule().fill(.white))
                    .padding(.top, 2)
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [Color.moblyAccent, Color(hex: 0xE85A1A)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .shadow(color: Color.moblyAccent.opacity(0.35), radius: 16, y: 8)
        }
        .buttonStyle(.plain)
    }

    // MARK: Owner dashboard CTA (owner)

    private var ownerDashboardCTA: some View {
        NavigationLink(value: ProfileRoute.ownerDashboard) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13).fill(Color(hex: 0xEEF0FE))
                    Image(systemName: "square.grid.2x2.fill").font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.moblyPrimary)
                }.frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mon espace propriétaire").font(.moblyHeading(14.5)).foregroundStyle(Color.moblyTextPrimary)
                    Text("Gérez vos annonces et vos demandes de visite")
                        .font(.moblyBody(11.5)).foregroundStyle(Color(hex: 0x9A9DAC))
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(hex: 0xC4C7D2))
            }
            .padding(15)
            .background(RoundedRectangle(cornerRadius: 18).fill(.white))
            .shadow(color: Color(hex: 0x14152A).opacity(0.06), radius: 10, y: 3)
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
                        Text("À bientôt \(farewellName) 👋")
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
