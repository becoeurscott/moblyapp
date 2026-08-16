import SwiftUI

/// Per-annonce performance detail. Reached from the dashboard "Stats" action.
struct OwnerStatsView: View {
    let annonce: OwnerAnnonce
    @Environment(\.dismiss) private var dismiss

    @State private var stats: MoblyAPI.OwnerListingStats?
    @State private var loading = false
    @State private var pollTimer: Timer?

    /// Live counts if the server responded, otherwise the local snapshot from
    /// `OwnerListings` so the screen has something the moment it opens.
    private var totalViews: Int    { stats?.metrics.views    ?? annonce.views }
    private var totalContacts: Int { stats?.metrics.contacts ?? annonce.contacts }
    private var totalFavorites: Int { stats?.metrics.favorites ?? annonce.favorites }
    private var totalVisits: Int   { stats?.metrics.visits   ?? 0 }
    private var contactRate: Double {
        if let r = stats?.metrics.contactRate { return r / 100.0 }
        return annonce.contactRate
    }

    /// 7-day series from the server (falls back to seven zero-bars while the
    /// first fetch is in flight — never fabricate a shape from the total).
    private var series: [(String, Int)] {
        if let d = stats?.daily, !d.isEmpty { return d.map { ($0.label, $0.views) } }
        return ["Lun","Mar","Mer","Jeu","Ven","Sam","Dim"].map { ($0, 0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    summaryCard
                    statGrid
                    viewsChart
                    if annonce.isBoosted { boostCard }
                    sourcesCard
                }
                .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 40)
            }
        }
        .background(Color.moblySurface)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task { await refresh() }
        .refreshable { await refresh() }
        .onAppear { startPolling() }
        .onDisappear { stopPolling() }
    }

    // MARK: Live refresh

    /// Poll every 15s so a new view/contact/favorite lands in the chart
    /// without the owner having to swipe-refresh. Cheap: single endpoint,
    /// only when the screen is on top.
    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            Task { await refresh() }
        }
    }
    private func stopPolling() {
        pollTimer?.invalidate(); pollTimer = nil
    }
    private func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let s = try await MoblyAPI.shared.ownerListingStats(id: annonce.listing.id)
            await MainActor.run { self.stats = s }
        } catch {
            // Keep the last-known values on screen; a failure here is
            // usually offline / auth expiring, not a hard error.
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .frame(width: 42, height: 42)
                    .background(RoundedRectangle(cornerRadius: 14).fill(.white)
                        .shadow(color: Color(hex: 0x14152A).opacity(0.06), radius: 8, y: 2))
            }
            Spacer()
            Text("Statistiques").font(.moblyHeading(19)).foregroundStyle(Color.moblyTextPrimary)
            Spacer()
            Color.clear.frame(width: 42, height: 42)
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 10)
    }

    // MARK: Summary

    private var summaryCard: some View {
        HStack(spacing: 13) {
            ListingCover(listing: annonce.listing)
                .frame(width: 56, height: 56).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 3) {
                Text(annonce.listing.title).font(.moblyHeading(15.5)).foregroundStyle(Color.moblyTextPrimary)
                Text(annonce.listing.price + LT(annonce.listing.priceUnit)).font(.moblyHeading(13.5)).foregroundStyle(Color.moblyPrimary)
            }
            Spacer()
            if annonce.isBoosted {
                Text("BOOSTÉE").font(.moblyBody(10, weight: .bold)).foregroundStyle(Color.moblyAccent)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Capsule().fill(Color(hex: 0xFFF3EC)))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18).fill(.white)
            .shadow(color: Color(hex: 0x14152A).opacity(0.05), radius: 9, y: 3))
    }

    // MARK: Stat grid

    private var statGrid: some View {
        let rate = String(format: "%.1f%%", contactRate * 100)
        let d = stats?.metrics.deltas7d
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            statCard("eye.fill", 0x3A4FF0, 0xEEF0FE, totalViews.formattedGrouped, "Vues totales", d?.views)
            statCard("bubble.left.fill", 0x1F8A5B, 0xE9F9EF, "\(totalContacts)", "Contacts", d?.contacts)
            statCard("heart.fill", 0xFF6B35, 0xFFF3EC, "\(totalFavorites)", "Ajouts en préférés", d?.favorites)
            statCard("chart.line.uptrend.xyaxis", 0x6B5BF5, 0xEDEBFE, rate, "Taux de contact", nil)
        }
    }

    private func statCard(_ icon: String, _ fg: UInt32, _ bg: UInt32, _ value: String, _ label: String, _ deltaPct: Int?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Color(hex: bg)).frame(width: 42, height: 42)
                    Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(Color(hex: fg))
                }
                Spacer()
                if let d = deltaPct {
                    let up = d >= 0
                    HStack(spacing: 3) {
                        Image(systemName: up ? "arrow.up" : "arrow.down")
                            .font(.system(size: 9, weight: .bold))
                        Text("\(up ? "+" : "")\(d)%")
                            .font(.moblyBody(11.5, weight: .semibold))
                    }.foregroundStyle(up ? Color(hex: 0x1F8A5B) : Color(hex: 0xE5484D))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(LT(value)).font(.moblyHeading(24)).foregroundStyle(Color.moblyTextPrimary)
                Text(LT(label)).font(.moblyBody(11.5)).foregroundStyle(Color(hex: 0x9A9DAC))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(RoundedRectangle(cornerRadius: 18).fill(.white)
            .shadow(color: Color(hex: 0x14152A).opacity(0.05), radius: 9, y: 3))
    }

    // MARK: Views chart

    private var viewsChart: some View {
        let maxVal = max(series.map(\.1).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Vues par jour").font(.moblyHeading(16)).foregroundStyle(Color.moblyTextPrimary)
                Spacer()
                Text("7 derniers jours").font(.moblyBody(12.5, weight: .medium)).foregroundStyle(Color.moblyPrimary)
            }
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(Array(series.enumerated()), id: \.offset) { _, item in
                    let isMax = item.1 == maxVal
                    VStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(isMax ? Color.moblyPrimary : Color(hex: 0xC9CFFB))
                            .frame(height: 120 * CGFloat(item.1) / CGFloat(maxVal))
                        Text(item.0).font(.moblyBody(11)).foregroundStyle(Color(hex: 0x9A9DAC))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 150, alignment: .bottom)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18).fill(.white)
            .shadow(color: Color(hex: 0x14152A).opacity(0.05), radius: 9, y: 3))
    }

    // MARK: Boost card

    private var boostCard: some View {
        let days = annonce.boostDaysLeft ?? 0
        let frac = CGFloat(days) / 30.0
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                Text("Boost Premium actif").font(.moblyHeading(16)).foregroundStyle(.white)
            }
            HStack {
                Text("Expire dans \(days) jours").font(.moblyBody(12.5)).foregroundStyle(.white.opacity(0.9))
                Spacer()
                Text("\(days) jours restants").font(.moblyHeading(13)).foregroundStyle(.white)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.3))
                    Capsule().fill(.white).frame(width: geo.size.width * frac)
                }
            }.frame(height: 7)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 20)
            .fill(LinearGradient(colors: [Color.moblyAccent, Color(hex: 0xFF8A5B)],
                                 startPoint: .leading, endPoint: .trailing)))
        .shadow(color: Color.moblyAccent.opacity(0.3), radius: 14, y: 6)
    }

    // MARK: Sources

    private var sourcesCard: some View {
        // Palette per source key, cycled deterministically so the same source
        // always gets the same colour across renders.
        let palette: [UInt32] = [0x3A4FF0, 0x1F8A5B, 0xFF6B35, 0x8B5CF6, 0x2A6FDB, 0xF5B301]
        let raw = stats?.sources ?? []
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Origine des vues").font(.moblyHeading(16)).foregroundStyle(Color.moblyTextPrimary)
                Spacer()
                Text("7 derniers jours").font(.moblyBody(12, weight: .medium))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
            }
            if raw.isEmpty {
                Text("Aucune vue enregistrée sur les 7 derniers jours.")
                    .font(.moblyBody(12.5))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                    .padding(.vertical, 6)
            } else {
                ForEach(Array(raw.enumerated()), id: \.offset) { i, s in
                    VStack(spacing: 7) {
                        HStack {
                            Text(sourceLabel(s.source)).font(.moblyBody(13.5, weight: .medium)).foregroundStyle(Color.moblyTextPrimary)
                            Spacer()
                            Text("\(s.percent)%").font(.moblyHeading(13.5)).foregroundStyle(Color.moblyTextPrimary)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color(hex: 0xF1F2F6))
                                Capsule().fill(Color(hex: palette[i % palette.count]))
                                    .frame(width: geo.size.width * CGFloat(s.percent) / 100)
                            }
                        }.frame(height: 8)
                    }
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18).fill(.white)
            .shadow(color: Color(hex: 0x14152A).opacity(0.05), radius: 9, y: 3))
    }

    /// Map the raw source tag from the client into a human label.
    private func sourceLabel(_ key: String) -> String {
        switch key {
        case "home":         return "Accueil"
        case "explore":      return "Explorer (carte)"
        case "search":       return "Recherche"
        case "recommended":  return "Recommandations"
        case "favorites":    return "Favoris"
        case "detail-similar": return "Annonces similaires"
        case "profile":      return "Profil hôte"
        default:             return "Autre"
        }
    }
}
