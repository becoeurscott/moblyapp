import SwiftUI

/// Host home ("Mes annonces"). Gated behind `Session.isOwner`. Aggregate
/// performance, filterable annonce list with per-listing metrics, and actions
/// (disponibilité, boost, modifier, stats).
struct OwnerDashboardView: View {
    @ObservedObject private var store = OwnerListings.shared
    @ObservedObject private var visits = VisitRequestStore.shared
    @ObservedObject private var auth = AuthStore.shared
    /// Aggregate figures + real 30-day deltas from /owner/overview.
    @State private var overview: MoblyAPI.OwnerOverview?
    @State private var showAddListing = false
    @State private var showVisits = false
    @State private var filter: Filter = .all
    @State private var statsAnnonce: OwnerAnnonce?
    @State private var boostAnnonce: OwnerAnnonce?
    @State private var editAnnonce: OwnerAnnonce?
    @State private var showReactivate = false

    /// The free trial ran out and the one-time inscription fee hasn't been paid:
    /// the whole dashboard is locked behind the paywall.
    private var ownerLocked: Bool {
        // Dev hook: `FORCE_OWNER_LOCKED=1` simulates a lapsed trial so the
        // paywall can be demoed without waiting 7 days or touching the server.
        if ProcessInfo.processInfo.environment["FORCE_OWNER_LOCKED"] == "1" { return true }
        return auth.user?.isOwner == true && auth.user?.isOwnerActive == false
    }

    /// Non-nil while the free trial is still running — drives the countdown banner.
    /// Dev hook: `FORCE_TRIAL_DAYS=<n>` simulates a running trial with n days left.
    private var trialDaysLeft: Int? {
        if let s = ProcessInfo.processInfo.environment["FORCE_TRIAL_DAYS"], let i = Int(s) { return i }
        return auth.user?.ownerTrialDaysLeft
    }

    private enum Filter: CaseIterable {
        case all, active, boosted, pending
        var title: String {
            switch self {
            case .all: return "Toutes"; case .active: return "Actives"
            case .boosted: return "Boostées"; case .pending: return "En attente"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if ownerLocked {
                lockedView
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        if let days = trialDaysLeft { trialBanner(days) }
                        performanceCard
                        visitsCard
                        filterBar
                        LazyVStack(spacing: 16) {
                            ForEach(filtered) { annonce in
                                AnnonceCard(
                                    annonce: annonce,
                                    onToggleAvailability: {
                                        await store.toggleAvailabilityAsync(annonce)
                                    },
                                    onBoost: { boostAnnonce = annonce },
                                    onStats: { statsAnnonce = annonce },
                                    onEdit: { editAnnonce = annonce },
                                    onDelete: { store.remove(annonce) },
                                    onRetry: { store.retryPublishing(annonce.id) },
                                    onDiscard: { store.discardPublishing(annonce.id) }
                                )
                            }
                        }
                        if filtered.isEmpty { emptyState }
                    }
                    .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 40)
                }
                .refreshable {
                    await UserDataStore.shared.loadMyListings()
                    OwnerListings.shared.load(from: UserDataStore.shared.myListings)
                    await loadOverview()
                }
            }
        }
        .background(Color.moblySurface)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $statsAnnonce) { OwnerStatsView(annonce: $0) }
        .task {
            await visits.refresh(silent: !visits.items.isEmpty)
            await loadOverview()
        }
        // Coming back to the app: refresh the figures with no sign of it.
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification)) { _ in
            Task {
                await visits.refresh(silent: true)
                await loadOverview()
            }
        }
        .onAppear {
            if ProcessInfo.processInfo.environment["OPEN_VISITS"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showVisits = true }
            }
            if ProcessInfo.processInfo.environment["OPEN_BOOST"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    boostAnnonce = store.annonces.first { !$0.isBoosted }
                }
            }
            if ProcessInfo.processInfo.environment["DEMO_UNAVAILABLE"] == "1",
               let a = store.annonces.first(where: { $0.available && !$0.isBoosted }) {
                store.toggleAvailability(a)
            }
            if ProcessInfo.processInfo.environment["OPEN_EDIT"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    editAnnonce = store.annonces.first
                }
            }
        }
        .fullScreenCover(isPresented: $showAddListing) {
            // The publish sheet inserts the annonce itself (as "Publication…")
            // and hands off to this dashboard; nothing to add here.
            AddListingView { _ in }
                .swipeToDismiss(onDismiss: { showAddListing = false })
        }
        .fullScreenCover(isPresented: $showVisits) {
            OwnerVisitsView()
                .swipeToDismiss(onDismiss: { showVisits = false })
        }
        .fullScreenCover(item: $editAnnonce) { annonce in
            ManageListingView(annonce: annonce) { editAnnonce = nil }
                .swipeToDismiss(onDismiss: { editAnnonce = nil })
        }
        .sheet(item: $boostAnnonce) { annonce in
            BoostSheet(annonce: annonce) { days in
                store.boost(annonce, days: days)
            }
            .presentationDetents([.height(620), .large])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showReactivate) {
            OwnerPaymentView(
                plan: .paid,
                oneTime: true,
                onCancel: { showReactivate = false },
                onPaid: {
                    showReactivate = false
                    Task {
                        await auth.payOwnerInscription()
                        // Bring the (now visible again) listings + figures back.
                        await UserDataStore.shared.loadMyListings()
                        OwnerListings.shared.load(from: UserDataStore.shared.myListings)
                        await loadOverview()
                    }
                }
            )
            .swipeToDismiss(onDismiss: { showReactivate = false })
        }
    }

    // MARK: Trial banner + locked paywall

    private func trialBanner(_ days: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "gift.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.22)))
            VStack(alignment: .leading, spacing: 2) {
                Text(days <= 0 ? "Dernier jour d'essai gratuit"
                               : "Essai gratuit · \(days) jour\(days > 1 ? "s" : "") restant\(days > 1 ? "s" : "")")
                    .font(.moblyHeading(14.5)).foregroundStyle(.white)
                Text("Payez une fois pour garder votre compte actif.")
                    .font(.moblyBody(12)).foregroundStyle(.white.opacity(0.85))
            }
            Spacer(minLength: 6)
            Button { showReactivate = true } label: {
                Text("Payer")
                    .font(.moblyHeading(13))
                    .foregroundStyle(Color.moblyAccent)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(.white))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18)
            .fill(LinearGradient(colors: [Color.moblyAccent, Color(hex: 0xE85A1A)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing)))
        .shadow(color: Color.moblyAccent.opacity(0.25), radius: 14, y: 6)
    }

    private var lockedView: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 22) {
                ZStack {
                    Circle().fill(Color(hex: 0xFFF3EC)).frame(width: 108, height: 108)
                    Image(systemName: "lock.fill")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(Color.moblyAccent)
                }
                .padding(.top, 40)

                VStack(spacing: 10) {
                    Text("Votre essai gratuit est terminé")
                        .font(.moblyHeading(22))
                        .foregroundStyle(Color.moblyTextPrimary)
                        .multilineTextAlignment(.center)
                    Text("Payez les frais d'inscription uniques de 5 000 FCFA pour réactiver votre compte propriétaire.")
                        .font(.moblyBody(14))
                        .foregroundStyle(Color.moblyTextSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 30)

                VStack(alignment: .leading, spacing: 12) {
                    lockedConsequence("eye.slash.fill", "Vos annonces sont masquées", "Elles n'apparaissent plus dans la recherche.")
                    lockedConsequence("bubble.left.slash.fill", "Personne ne peut vous contacter", "Votre profil affiche « Contact désactivé ».")
                    lockedConsequence("bolt.fill", "Réactivation immédiate", "Tout revient dès le paiement effectué.")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 18).fill(.white)
                    .shadow(color: Color(hex: 0x14152A).opacity(0.05), radius: 12, y: 4))
                .padding(.horizontal, 20)

                Button { showReactivate = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.open.fill").font(.system(size: 14, weight: .bold))
                        Text("Payer 5 000 FCFA").font(.moblyHeading(15.5))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 56)
                    .background(LinearGradient(colors: [Color.moblyPrimary, Color(hex: 0x5B6BF5)],
                                               startPoint: .leading, endPoint: .trailing))
                    .clipShape(Capsule())
                    .shadow(color: Color.moblyPrimary.opacity(0.35), radius: 14, y: 8)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.top, 4)

                Spacer(minLength: 30)
            }
        }
    }

    private func lockedConsequence(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.moblyAccent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.moblyHeading(14)).foregroundStyle(Color.moblyTextPrimary)
                Text(subtitle).font(.moblyBody(12.5)).foregroundStyle(Color.moblyTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var filtered: [OwnerAnnonce] {
        switch filter {
        case .all:     return store.annonces
        case .active:  return store.annonces.filter { $0.status == .active && $0.available }
        case .boosted: return store.annonces.filter { $0.isBoosted }
        case .pending: return store.annonces.filter { $0.status == .pending }
        }
    }

    private func count(_ f: Filter) -> Int {
        switch f {
        case .all:     return store.annonces.count
        case .active:  return store.annonces.filter { $0.status == .active && $0.available }.count
        case .boosted: return store.annonces.filter { $0.isBoosted }.count
        case .pending: return store.annonces.filter { $0.status == .pending }.count
        }
    }

    // MARK: Top bar

    @Environment(\.dismiss) private var dismiss

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.moblyTextPrimary)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(.white)
                            .shadow(color: Color(hex: 0x14152A).opacity(0.05), radius: 8, y: 2))
                }
                Spacer()
                Button { showAddListing = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 14, weight: .bold))
                        Text("Publier").font(.moblyHeading(14.5))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 11)
                    .background(Capsule().fill(Color.moblyPrimary))
                    .shadow(color: Color.moblyPrimary.opacity(0.3), radius: 10, y: 5)
                }
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    (Text(greeting).foregroundColor(Color.moblyTextPrimary)
                        + Text("  👋"))
                        .font(.moblyHeading(26))
                    Text("Voici un aperçu de vos annonces et de vos performances.")
                        .font(.moblyBody(13.5))
                        .foregroundStyle(Color.moblyTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                avatarView
            }
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
    }

    /// "Bonjour Alex" — first name only, greeting alone when we have no name.
    private var greeting: String {
        let full = (auth.user?.fullName ?? "").trimmingCharacters(in: .whitespaces)
        let first = full.split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? "Bonjour" : "Bonjour \(first)"
    }

    private var avatarInitials: String {
        let full = (auth.user?.fullName ?? "").trimmingCharacters(in: .whitespaces)
        return full.isEmpty ? "M" : String(full.prefix(2)).uppercased()
    }

    /// Uploaded photo takes precedence; otherwise the deterministic palette
    /// gradient with initials — same treatment as the profile header.
    private var avatarView: some View {
        ZStack {
            if let url = auth.user?.avatarUrl, let u = URL(string: url) {
                AsyncImage(url: u) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default: avatarFallback
                    }
                }
            } else {
                avatarFallback
            }
        }
        .frame(width: 54, height: 54)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white, lineWidth: 2))
        .shadow(color: Color(hex: 0x14152A).opacity(0.12), radius: 8, y: 3)
    }

    private var avatarFallback: some View {
        ZStack {
            LinearGradient(
                colors: AvatarPalette.gradient(for: auth.user?.id ?? "self",
                                               stored: auth.user?.avatarColor),
                startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(avatarInitials).font(.moblyHeading(18)).foregroundStyle(.white)
        }
    }

    /// Best-effort: on failure the card falls back to the listing totals and
    /// simply shows no trend badge, rather than a stale or invented one.
    private func loadOverview() async {
        guard let fresh = try? await MoblyAPI.shared.ownerOverview() else { return }
        // Keep the last-known figures when the call fails, and ease the new
        // ones in when it succeeds.
        withAnimation(Motion.content) { overview = fresh }
    }

    // MARK: Performance card

    private var performanceCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.18)))
                Text("Performances · 30 derniers jours")
                    .font(.moblyHeading(14.5)).foregroundStyle(.white)
                Spacer(minLength: 4)
            }
            HStack(alignment: .top, spacing: 0) {
                // Totals come from the listings; the 30-day window and its
                // deltas come from the raw event tables via /owner/overview.
                perfStat("eye.fill",
                         (overview?.last30d.views ?? store.totalViews).formattedGrouped,
                         "Vues totales", overview?.deltas30d.views)
                perfDivider
                perfStat("bubble.left.fill",
                         "\(overview?.last30d.contacts ?? store.totalContacts)",
                         "Contacts", overview?.deltas30d.contacts)
                perfDivider
                perfStat("bookmark.fill",
                         "\(overview?.last30d.favorites ?? store.totalFavorites)",
                         "Ajouts en préférés", overview?.deltas30d.favorites)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 24)
            .fill(LinearGradient(colors: [Color.moblyPrimary, Color(hex: 0x5B6BF5)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing)))
        .shadow(color: Color.moblyPrimary.opacity(0.28), radius: 20, y: 10)
    }

    private var perfDivider: some View {
        Rectangle().fill(.white.opacity(0.16)).frame(width: 1, height: 58)
    }

    /// `delta` is nil when there is no previous 30-day period to compare
    /// against — a brand-new annonce has no trend, and inventing one is how
    /// the old hardcoded "+18%" ended up sitting next to a metric that had
    /// actually fallen. Nil renders no badge at all.
    private func perfStat(_ icon: String, _ value: String, _ label: String, _ delta: Int?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text(value).font(.moblyHeading(24)).foregroundStyle(.white)
                .contentTransition(.numericText())
                .animation(Motion.content, value: value)
            Text(LT(label)).font(.moblyBody(11)).foregroundStyle(.white.opacity(0.8))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            deltaBadge(delta)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
    }

    @ViewBuilder
    private func deltaBadge(_ delta: Int?) -> some View {
        if let d = delta {
            if d == 0 {
                HStack(spacing: 3) {
                    Image(systemName: "minus").font(.system(size: 9, weight: .bold))
                    Text("0%").font(.moblyBody(11, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.7))
            } else {
                let up = d > 0
                HStack(spacing: 3) {
                    Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 9, weight: .bold))
                    Text("\(up ? "+" : "")\(d)%").font(.moblyBody(11, weight: .semibold))
                }
                .foregroundStyle(up ? Color(hex: 0x9CFFC9) : Color(hex: 0xFFC2C4))
            }
        } else {
            // Keeps the three columns vertically aligned without a badge.
            Color.clear.frame(height: 14)
        }
    }

    // MARK: Visits card

    private var visitsCard: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showVisits = true
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(hex: 0xFFF3EC))
                        .frame(width: 46, height: 46)
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.moblyAccent)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Demandes de visite")
                        .font(.moblyHeading(15.5))
                        .foregroundStyle(Color.moblyTextPrimary)
                    Text(visitsSubtitle)
                        .font(.moblyBody(12.5))
                        .foregroundStyle(Color.moblyTextSecondary)
                }
                Spacer()
                if visits.pendingCount > 0 {
                    Text("\(visits.pendingCount)")
                        .font(.moblyHeading(13))
                        .foregroundStyle(.white)
                        .frame(minWidth: 26, minHeight: 26)
                        .padding(.horizontal, 8)
                        .background(Capsule().fill(Color.moblyAccent))
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xC4C7D2))
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 18).fill(.white)
                .shadow(color: Color(hex: 0x14152A).opacity(0.06), radius: 12, y: 4))
        }
        .buttonStyle(.plain)
    }

    private var visitsSubtitle: String {
        let pending = visits.pendingCount
        if pending == 0 { return "Aucune demande en attente" }
        if pending == 1 { return "1 nouvelle demande" }
        return "\(pending) nouvelles demandes"
    }

    // MARK: Filter bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Filter.allCases, id: \.self) { f in
                    Button {
                        UISelectionFeedbackGenerator().selectionChanged()
                        withAnimation(Motion.instant) { filter = f }
                    } label: {
                        Text("\(f.title) (\(count(f)))")
                            .font(.moblyHeading(13.5))
                            .foregroundStyle(filter == f ? .white : Color.moblyTextSecondary)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(Capsule().fill(filter == f ? Color.moblyPrimary : .white))
                            .overlay(Capsule().stroke(filter == f ? .clear : Color(hex: 0xE2E4EC), lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "house.lodge").font(.system(size: 32, weight: .light))
                .foregroundStyle(Color(hex: 0xC4C7D2))
            Text("Aucune annonce ici").font(.moblyHeading(14.5)).foregroundStyle(Color.moblyTextPrimary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }
}

// MARK: - Annonce card

private struct AnnonceCard: View {
    let annonce: OwnerAnnonce
    var onToggleAvailability: () async -> Void
    var onBoost: () -> Void
    var onStats: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void
    var onRetry: () -> Void = {}
    var onDiscard: () -> Void = {}

    @State private var confirmDelete = false
    @State private var toggling = false

    private var dimmed: Bool { !annonce.available }

    /// Not on the server yet (sending, or the send failed).
    private var local: Bool { annonce.publishState != nil }
    private var failureMessage: String? {
        if case .failed(let m) = annonce.publishState { return m }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().padding(.horizontal, 14)
            if local {
                publishRow.padding(14)
            } else {
                statusRow.padding(14)
                if annonce.isBoosted && annonce.available {
                    boostRow.padding(.horizontal, 14).padding(.bottom, 14)
                }
                Divider().padding(.horizontal, 14)
                actionRow.padding(14)
            }
        }
        .animation(Motion.standard, value: annonce.publishState)
        .background(RoundedRectangle(cornerRadius: 22).fill(dimmed ? Color(hex: 0xF1F2F5) : .white)
            .shadow(color: Color(hex: 0x14152A).opacity(dimmed ? 0.03 : 0.05), radius: 16, y: 6))
        .overlay(RoundedRectangle(cornerRadius: 22)
            .stroke(Color(hex: 0xE2E4EC), lineWidth: dimmed ? 1 : 0))
        .animation(Motion.standard, value: annonce.available)
        .contextMenu {
            if !annonce.isPublishing {
                Button(role: .destructive, action: local ? onDiscard : onDelete) {
                    Label("Supprimer l'annonce", systemImage: "trash")
                }
            }
        }
        .confirmationDialog("Supprimer « \(annonce.listing.title) » ?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Supprimer l'annonce", role: .destructive) {
                withAnimation(Motion.quick) { onDelete() }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Cette action est définitive.")
        }
    }

    private var header: some View {
        Button(action: onStats) {
            HStack(alignment: .top, spacing: 13) {
                ZStack(alignment: .topLeading) {
                    ListingCover(listing: annonce.listing)
                        .frame(width: 84, height: 84).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .saturation(dimmed ? 0 : 1)
                        .opacity(dimmed ? 0.55 : 1)
                        .overlay {
                            if annonce.isPublishing {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 16).fill(.black.opacity(0.35))
                                    ProgressView().tint(.white)
                                }
                            }
                        }
                    if annonce.listing.photos.count > 1 {
                        Text("1/\(annonce.listing.photos.count)")
                            .font(.moblyBody(10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(.black.opacity(0.5)))
                            .padding(6)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 6) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(annonce.listing.title).font(.moblyHeading(17))
                                .foregroundStyle(dimmed ? Color.moblyTextSecondary : Color.moblyTextPrimary)
                                .lineLimit(1)
                            Text(annonce.listing.price + LT(annonce.listing.priceUnit))
                                .font(.moblyHeading(15))
                                .foregroundStyle(dimmed ? Color(hex: 0x9A9DAC) : Color.moblyPrimary)
                        }
                        Spacer(minLength: 6)
                        statusPill
                        if !local {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color(hex: 0xC4C7D2))
                                .padding(.top, 3)
                        }
                    }
                    HStack(spacing: 8) {
                        metricPill("eye.fill", annonce.views.formattedGrouped, 0x9A9DAC, 0xF1F2F6)
                        metricPill("bubble.left.fill", "\(annonce.contacts)", 0x1F8A5B, 0xE9F9EF)
                        metricPill("heart.fill", "\(annonce.favorites)", 0xE5484D, 0xFDEDED)
                    }
                    .opacity(dimmed ? 0.5 : 1)
                }
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // No stats page for an annonce the server hasn't created yet. Blocks the
        // tap without `.disabled`'s dimming, which would grey the whole card.
        .allowsHitTesting(!local)
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            if annonce.isPublishing {
                ProgressView().controlSize(.mini).tint(Color.moblyPrimary)
            } else {
                Circle().fill(pillColor).frame(width: 6, height: 6)
            }
            Text(pillLabel)
                .font(.moblyBody(10.5, weight: .bold))
                .foregroundStyle(pillColor)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Capsule().fill(pillColor.opacity(0.12)))
    }

    private var pillLabel: String {
        switch annonce.publishState {
        case .uploading: return "ENVOI…"
        case .failed:    return "ÉCHEC"
        case nil:        return annonce.status.label
        }
    }

    private var pillColor: Color {
        switch annonce.publishState {
        case .uploading: return Color.moblyPrimary
        case .failed:    return Color(hex: 0xE5484D)
        case nil:        return statusColor
        }
    }

    /// Replaces the availability + action rows while the annonce isn't on the
    /// server yet: a progress line while sending, the reason + retry on failure.
    @ViewBuilder
    private var publishRow: some View {
        if let message = failureMessage {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(hex: 0xE5484D))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("La publication a échoué")
                            .font(.moblyHeading(13.5)).foregroundStyle(Color.moblyTextPrimary)
                        Text(LT(message))
                            .font(.moblyBody(12)).foregroundStyle(Color.moblyTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    actionButton("Réessayer", "arrow.clockwise", fg: 0x3A4FF0, bg: 0xEEF0FE, action: onRetry)
                    actionButton("Supprimer", "trash.fill", fg: 0xE5484D, bg: 0xFDEDED, action: onDiscard)
                }
            }
        } else {
            HStack(spacing: 10) {
                ProgressView().tint(Color.moblyPrimary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Publication en cours…")
                        .font(.moblyHeading(13.5)).foregroundStyle(Color.moblyTextPrimary)
                    Text("Votre annonce sera active dès que l'envoi sera terminé.")
                        .font(.moblyBody(12)).foregroundStyle(Color.moblyTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
        }
    }

    private var statusColor: Color {
        switch annonce.status {
        case .boosted:  return Color.moblyAccent
        case .active:   return Color(hex: 0x1F8A5B)
        case .pending:  return Color(hex: 0x9A6B00)
        case .inactive: return Color(hex: 0x9A9DAC)
        }
    }

    private func metricPill(_ icon: String, _ value: String, _ color: UInt32, _ bg: UInt32) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(LT(value)).font(.moblyBody(12, weight: .semibold))
        }
        .foregroundStyle(Color(hex: color))
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Capsule().fill(Color(hex: bg)))
    }

    private var statusRow: some View {
        HStack {
            HStack(spacing: 7) {
                Circle().fill(annonce.available ? Color(hex: 0x1F8A5B) : Color(hex: 0xC4C7D2))
                    .frame(width: 8, height: 8)
                Text(annonce.available ? "Disponible" : "Indisponible")
                    .font(.moblyHeading(13.5))
                    .foregroundStyle(annonce.available ? Color(hex: 0x1F8A5B) : Color.moblyTextSecondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 11)
                .fill(annonce.available ? Color(hex: 0xE9F9EF) : Color(hex: 0xF1F2F6)))
            Spacer()
            Button {
                guard !toggling else { return }
                Task {
                    toggling = true
                    await onToggleAvailability()
                    toggling = false
                }
            } label: {
                HStack(spacing: 6) {
                    if toggling {
                        ProgressView().controlSize(.mini).tint(Color.moblyPrimary)
                    } else {
                        Image(systemName: annonce.available ? "eye.slash" : "eye")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Text(toggling
                         ? "Mise à jour…"
                         : (annonce.available ? "Rendre indisponible" : "Rendre disponible"))
                        .font(.moblyHeading(13))
                }
                .foregroundStyle(toggling ? Color.moblyTextSecondary : Color.moblyPrimary)
            }
            .disabled(toggling)
            .animation(Motion.quick, value: toggling)
        }
    }

    private var boostRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill").font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.moblyAccent)
            Text("Boost actif · \(annonce.boostDaysLeft ?? 0) j restants")
                .font(.moblyHeading(13)).foregroundStyle(Color(hex: 0xC24E10))
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color(hex: 0xFFF3EC)))
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            if annonce.available {
                // Boosting only makes sense for an available annonce.
                if !annonce.isBoosted {
                    actionButton("Booster", "bolt.fill", fg: 0xC24E10, bg: 0xFFF3EC, action: onBoost)
                }
                actionButton("Modifier", "pencil", fg: 0x3A4FF0, bg: 0xEEF0FE, action: onEdit)
                actionButton("Stats", "chart.bar.fill", fg: 0x666F80, bg: 0xF1F2F6, action: onStats)
            } else {
                actionButton("Supprimer", "trash.fill", fg: 0xE5484D, bg: 0xFDEDED) {
                    confirmDelete = true
                }
                actionButton("Modifier", "pencil", fg: 0x3A4FF0, bg: 0xEEF0FE, action: onEdit)
            }
        }
    }

    private func actionButton(_ title: String, _ icon: String, fg: UInt32, bg: UInt32, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(LT(title)).font(.moblyHeading(13.5))
            }
            .foregroundStyle(Color(hex: fg))
            .frame(maxWidth: .infinity).frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: bg)))
        }
        .buttonStyle(.plain)
    }
}

extension Int {
    /// "1204" → "1 204" (space grouping, FR style).
    var formattedGrouped: String {
        let f = NumberFormatter()
        f.groupingSeparator = " "; f.numberStyle = .decimal
        return f.string(from: NSNumber(value: self)) ?? "\(self)"
    }
}
