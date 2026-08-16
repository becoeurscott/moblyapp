import SwiftUI

/// Host home ("Mes annonces"). Gated behind `Session.isOwner`. Aggregate
/// performance, filterable annonce list with per-listing metrics, and actions
/// (disponibilité, boost, modifier, stats).
struct OwnerDashboardView: View {
    @ObservedObject private var store = OwnerListings.shared
    @ObservedObject private var visits = VisitRequestStore.shared
    /// Aggregate figures + real 30-day deltas from /owner/overview.
    @State private var overview: MoblyAPI.OwnerOverview?
    @State private var showAddListing = false
    @State private var showVisits = false
    @State private var filter: Filter = .all
    @State private var statsAnnonce: OwnerAnnonce?
    @State private var boostAnnonce: OwnerAnnonce?
    @State private var editAnnonce: OwnerAnnonce?

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
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    performanceCard
                    visitsCard
                    filterBar
                    LazyVStack(spacing: 16) {
                        ForEach(filtered) { annonce in
                            AnnonceCard(
                                annonce: annonce,
                                onToggleAvailability: {
                                    withAnimation(.easeInOut(duration: 0.4)) { store.toggleAvailability(annonce) }
                                },
                                onBoost: { boostAnnonce = annonce },
                                onStats: { statsAnnonce = annonce },
                                onEdit: { editAnnonce = annonce },
                                onDelete: { store.remove(annonce) }
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
        .background(Color.moblySurface)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $statsAnnonce) { OwnerStatsView(annonce: $0) }
        .task {
            await visits.refresh()
            await loadOverview()
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
            AddListingView { store.add($0) }
        }
        .fullScreenCover(isPresented: $showVisits) {
            OwnerVisitsView()
        }
        .fullScreenCover(item: $editAnnonce) { annonce in
            ManageListingView(annonce: annonce) { editAnnonce = nil }
        }
        .sheet(item: $boostAnnonce) { annonce in
            BoostSheet(annonce: annonce) { days in
                store.boost(annonce, days: days)
            }
            .presentationDetents([.height(620), .large])
            .presentationDragIndicator(.visible)
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
        VStack(spacing: 14) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.moblyTextPrimary)
                        .frame(width: 42, height: 42)
                        .background(RoundedRectangle(cornerRadius: 14).fill(.white)
                            .shadow(color: Color(hex: 0x14152A).opacity(0.06), radius: 8, y: 2))
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
            HStack {
                Text("Mes annonces")
                    .font(.moblyHeading(26)).foregroundStyle(Color.moblyTextPrimary)
                Spacer()
            }
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 10)
    }

    /// Best-effort: on failure the card falls back to the listing totals and
    /// simply shows no trend badge, rather than a stale or invented one.
    private func loadOverview() async {
        overview = try? await MoblyAPI.shared.ownerOverview()
    }

    // MARK: Performance card

    private var performanceCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Performances · 30 derniers jours")
                .font(.moblyBody(12.5)).foregroundStyle(.white.opacity(0.8))
            HStack(alignment: .top, spacing: 8) {
                // Totals come from the listings; the 30-day window and its
                // deltas come from the raw event tables via /owner/overview.
                perfStat((overview?.last30d.views ?? store.totalViews).formattedGrouped,
                         "Vues totales", overview?.deltas30d.views)
                perfStat("\(overview?.last30d.contacts ?? store.totalContacts)",
                         "Contacts", overview?.deltas30d.contacts)
                perfStat("\(overview?.last30d.favorites ?? store.totalFavorites)",
                         "Ajouts en préférés", overview?.deltas30d.favorites)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 22)
            .fill(LinearGradient(colors: [Color.moblyPrimary, Color(hex: 0x5B6BF5)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing)))
        .shadow(color: Color.moblyPrimary.opacity(0.25), radius: 16, y: 8)
    }

    /// `delta` is nil when there is no previous 30-day period to compare
    /// against — a brand-new annonce has no trend, and inventing one is how
    /// the old hardcoded "+18%" ended up sitting next to a metric that had
    /// actually fallen. Nil renders no badge at all.
    private func perfStat(_ value: String, _ label: String, _ delta: Int?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.moblyHeading(27)).foregroundStyle(.white)
            Text(LT(label)).font(.moblyBody(11.5)).foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            if let d = delta {
                let up = d >= 0
                HStack(spacing: 3) {
                    Image(systemName: up ? "arrow.up" : "arrow.down")
                        .font(.system(size: 9, weight: .bold))
                    Text("\(up ? "+" : "")\(d)%").font(.moblyBody(11, weight: .semibold))
                }
                .foregroundStyle(up ? Color(hex: 0x9CFFC9) : Color(hex: 0xFFC2C4))
            } else {
                // Keeps the three columns vertically aligned without a badge.
                Color.clear.frame(height: 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                        withAnimation(.easeInOut(duration: 0.2)) { filter = f }
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
    var onToggleAvailability: () -> Void
    var onBoost: () -> Void
    var onStats: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void

    @State private var confirmDelete = false

    private var dimmed: Bool { !annonce.available }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().padding(.horizontal, 14)
            statusRow.padding(14)
            if annonce.isBoosted && annonce.available {
                boostRow.padding(.horizontal, 14).padding(.bottom, 14)
            }
            Divider().padding(.horizontal, 14)
            actionRow.padding(14)
        }
        .background(RoundedRectangle(cornerRadius: 20).fill(dimmed ? Color(hex: 0xF1F2F5) : .white)
            .shadow(color: Color(hex: 0x14152A).opacity(dimmed ? 0.03 : 0.06), radius: 12, y: 4))
        .overlay(RoundedRectangle(cornerRadius: 20)
            .stroke(Color(hex: 0xE2E4EC), lineWidth: dimmed ? 1 : 0))
        .animation(.easeInOut(duration: 0.4), value: annonce.available)
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label("Supprimer l'annonce", systemImage: "trash")
            }
        }
        .confirmationDialog("Supprimer « \(annonce.listing.title) » ?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Supprimer l'annonce", role: .destructive) {
                withAnimation(.easeInOut(duration: 0.3)) { onDelete() }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Cette action est définitive.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 13) {
            ListingCover(listing: annonce.listing)
                .frame(width: 76, height: 76).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 15))
                .saturation(dimmed ? 0 : 1)
                .opacity(dimmed ? 0.55 : 1)
                .overlay(alignment: .topLeading) { badge.padding(6) }
            VStack(alignment: .leading, spacing: 6) {
                Text(annonce.listing.title).font(.moblyHeading(16.5))
                    .foregroundStyle(dimmed ? Color.moblyTextSecondary : Color.moblyTextPrimary)
                    .lineLimit(1)
                Text(annonce.listing.price + LT(annonce.listing.priceUnit))
                    .font(.moblyHeading(15))
                    .foregroundStyle(dimmed ? Color(hex: 0x9A9DAC) : Color.moblyPrimary)
                HStack(spacing: 8) {
                    metricPill("eye.fill", annonce.views.formattedGrouped, 0x9A9DAC, 0xF1F2F6)
                    metricPill("bubble.left.fill", "\(annonce.contacts)", 0x1F8A5B, 0xE9F9EF)
                    metricPill("heart.fill", "\(annonce.favorites)", 0xE5484D, 0xFDEDED)
                }
                .opacity(dimmed ? 0.5 : 1)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private var badge: some View {
        Text(annonce.status.label)
            .font(.moblyBody(9, weight: .bold))
            .foregroundStyle(badgeColor)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(Capsule().fill(.white.opacity(0.95)))
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }
    private var badgeColor: Color {
        switch annonce.status {
        case .boosted:  return Color.moblyAccent
        case .active:   return Color(hex: 0x1F8A5B)
        case .pending:  return Color(hex: 0x9A6B00)
        case .inactive: return Color(hex: 0x9A9DAC)   // paused / rejected / archived
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
            Button(action: onToggleAvailability) {
                Text(annonce.available ? "Rendre indisponible" : "Rendre disponible")
                    .font(.moblyHeading(13)).foregroundStyle(Color.moblyPrimary)
            }
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
