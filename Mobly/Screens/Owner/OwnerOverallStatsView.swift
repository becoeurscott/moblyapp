import SwiftUI
import Charts

/// Overall performance across every annonce the owner has. Opened by tapping
/// the dashboard's dark-blue "Performances" card.
///
/// Every figure is counted from the server's event tables, so an annonce that
/// is deleted takes its views, contacts and favourites out of these totals.
/// The screen refetches when the server says the figures changed (a new view,
/// a deletion) and every 15 seconds while it is on screen.
struct OwnerOverallStatsView: View {
    var initial: MoblyAPI.OwnerOverview?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = OwnerListings.shared

    @State private var overview: MoblyAPI.OwnerOverview?
    @State private var loading = false
    @State private var pollTimer: Timer?
    @State private var statsAnnonce: OwnerAnnonce?

    private var data: MoblyAPI.OwnerOverview? { overview ?? initial }
    private var totals: MoblyAPI.OwnerOverview.Totals? { data?.totals }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        heroCard
                        statGrid
                        // Older servers send only the headline figures.
                        if data?.daily30d != nil {
                            trendChart
                            sourcesCard
                            rankingCard
                        }
                    }
                    .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 40)
                }
                .refreshable { await refresh() }
            }
            .background(Color.moblySurface)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $statsAnnonce) { OwnerStatsView(annonce: $0) }
        }
        .task { await refresh() }
        .onAppear { startPolling() }
        .onDisappear { stopPolling() }
        .onReceive(NotificationCenter.default.publisher(for: OwnerListings.statsChanged)) { _ in
            Task { await refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didEnterBackgroundNotification)) { _ in stopPolling() }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification)) { _ in
            startPolling()
            Task { await refresh() }
        }
    }

    // MARK: Refresh

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
        // Keep the last figures on screen when the call fails.
        guard let fresh = try? await MoblyAPI.shared.ownerOverview() else { return }
        withAnimation(Motion.content) { overview = fresh }
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
            Text("Statistiques globales").font(.moblyHeading(19)).foregroundStyle(Color.moblyTextPrimary)
            Spacer()
            Color.clear.frame(width: 42, height: 42)
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 10)
    }

    // MARK: Hero

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Vues totales")
                .font(.moblyBody(13, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
            Text((totals?.views ?? data?.views ?? 0).formattedGrouped)
                .font(.moblyHeading(38))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
            HStack(spacing: 14) {
                heroPill("\((data?.last30d.views ?? 0).formattedGrouped) sur 30 jours",
                         delta: data?.deltas30d.views)
                heroPill("\(data?.listings ?? store.annonces.count) annonce\((data?.listings ?? 0) > 1 ? "s" : "")",
                         delta: nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 24)
            .fill(LinearGradient(colors: [Color(hex: 0x1A2266), Color(hex: 0x2A3690)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing)))
        .shadow(color: Color(hex: 0x1A2266).opacity(0.3), radius: 18, y: 8)
    }

    private func heroPill(_ text: String, delta: Int?) -> some View {
        HStack(spacing: 5) {
            Text(text).font(.moblyBody(12, weight: .semibold))
            if let delta {
                Text("\(delta >= 0 ? "+" : "")\(delta)%")
                    .font(.moblyBody(11.5, weight: .bold))
                    .foregroundStyle(delta >= 0 ? Color(hex: 0x7CF0B4) : Color(hex: 0xFF9A9D))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(.white.opacity(0.14)))
    }

    // MARK: Grid

    private var statGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                  spacing: 12) {
            tile("bubble.left.fill", "Contacts", "\(totals?.contacts ?? data?.contacts ?? 0)", 0x1F8A5B)
            tile("heart.fill", "Favoris", "\(totals?.favorites ?? data?.favorites ?? 0)", 0xE5484D)
            tile("calendar", "Demandes de visite", "\(totals?.visits ?? 0)", 0x8B5CF6)
            tile("percent", "Taux de contact",
                 String(format: "%.1f%%", totals?.contactRate ?? 0), 0xFF6B35)
        }
    }

    private func tile(_ icon: String, _ label: String, _ value: String, _ tint: UInt32) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(hex: tint))
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: tint).opacity(0.12)))
            Text(value)
                .font(.moblyHeading(22))
                .foregroundStyle(Color.moblyTextPrimary)
                .contentTransition(.numericText())
            Text(label)
                .font(.moblyBody(12))
                .foregroundStyle(Color(hex: 0x9A9DAC))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18).fill(.white)
            .shadow(color: Color(hex: 0x14152A).opacity(0.05), radius: 9, y: 3))
    }

    // MARK: Trend

    private struct Point: Identifiable {
        let id = UUID()
        let date: Date
        let value: Int
        let series: String
    }

    private var points: [Point] {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.timeZone = TimeZone(identifier: "UTC")
        return (data?.daily30d ?? []).flatMap { d -> [Point] in
            guard let date = parser.date(from: d.date) else { return [] }
            return [Point(date: date, value: d.views, series: "Vues"),
                    Point(date: date, value: d.contacts, series: "Contacts")]
        }
    }

    private var trendChart: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Évolution").font(.moblyHeading(16)).foregroundStyle(Color.moblyTextPrimary)
                Spacer()
                Text("30 derniers jours").font(.moblyBody(12, weight: .medium))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
            }
            Chart(points) { p in
                LineMark(x: .value("Jour", p.date), y: .value("Nombre", p.value))
                    .foregroundStyle(by: .value("Série", p.series))
                    .interpolationMethod(.catmullRom)
                if p.series == "Vues" {
                    AreaMark(x: .value("Jour", p.date), y: .value("Nombre", p.value))
                        .foregroundStyle(LinearGradient(
                            colors: [Color.moblyPrimary.opacity(0.22), Color.moblyPrimary.opacity(0)],
                            startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.catmullRom)
                }
            }
            .chartForegroundStyleScale(["Vues": Color.moblyPrimary, "Contacts": Color(hex: 0x1F8A5B)])
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .chartLegend(position: .top, alignment: .leading)
            .frame(height: 190)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18).fill(.white)
            .shadow(color: Color(hex: 0x14152A).opacity(0.05), radius: 9, y: 3))
    }

    // MARK: Sources

    private var sourcesCard: some View {
        let palette: [UInt32] = [0x3A4FF0, 0x1F8A5B, 0xFF6B35, 0x8B5CF6, 0x2A6FDB, 0xF5B301]
        let rows = data?.sources30d ?? []
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Origine des vues").font(.moblyHeading(16)).foregroundStyle(Color.moblyTextPrimary)
                Spacer()
                Text("30 derniers jours").font(.moblyBody(12, weight: .medium))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
            }
            if rows.isEmpty {
                Text("Aucune vue enregistrée sur les 30 derniers jours.")
                    .font(.moblyBody(12.5))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, s in
                    VStack(spacing: 7) {
                        HStack {
                            Text(Self.sourceLabel(s.source))
                                .font(.moblyBody(13.5, weight: .medium))
                                .foregroundStyle(Color.moblyTextPrimary)
                            Spacer()
                            Text("\(s.count)")
                                .font(.moblyBody(12))
                                .foregroundStyle(Color(hex: 0x9A9DAC))
                            Text("\(s.percent)%")
                                .font(.moblyHeading(13.5))
                                .foregroundStyle(Color.moblyTextPrimary)
                                .frame(minWidth: 40, alignment: .trailing)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color(hex: 0xF1F2F6))
                                Capsule().fill(Color(hex: palette[i % palette.count]))
                                    .frame(width: geo.size.width * CGFloat(s.percent) / 100)
                            }
                        }
                        .frame(height: 8)
                    }
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18).fill(.white)
            .shadow(color: Color(hex: 0x14152A).opacity(0.05), radius: 9, y: 3))
    }

    static func sourceLabel(_ key: String) -> String {
        switch key {
        case "home":           return "Accueil"
        case "explore":        return "Explorer (carte)"
        case "search":         return "Recherche"
        case "boost":          return "Boost (mise en avant)"
        case "share":          return "Lien partagé"
        case "notification":   return "Notifications"
        case "chat":           return "Messages"
        case "recommended":    return "Recommandations"
        case "favorites":      return "Favoris"
        case "detail-similar": return "Annonces similaires"
        case "profile":        return "Profil hôte"
        default:               return "Autre"
        }
    }

    // MARK: Ranking

    private var rankingCard: some View {
        let rows = data?.topListings ?? []
        return VStack(alignment: .leading, spacing: 14) {
            Text("Par annonce").font(.moblyHeading(16)).foregroundStyle(Color.moblyTextPrimary)
            if rows.isEmpty {
                Text("Aucune annonce pour le moment.")
                    .font(.moblyBody(12.5))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
            }
            ForEach(rows) { r in
                Button {
                    statsAnnonce = store.annonces.first { $0.listing.id == r.id }
                } label: {
                    HStack(spacing: 12) {
                        RemoteImage(source: r.coverUrl ?? "ListingGreen", width: ImageSlot.thumb)
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(r.title)
                                .font(.moblyHeading(14))
                                .foregroundStyle(Color.moblyTextPrimary)
                                .lineLimit(1)
                            HStack(spacing: 10) {
                                metric("eye.fill", r.views)
                                metric("bubble.left.fill", r.contacts)
                                metric("heart.fill", r.favorites)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("+\(r.views30d)")
                                .font(.moblyHeading(13.5))
                                .foregroundStyle(Color.moblyPrimary)
                            Text("30 j")
                                .font(.moblyBody(10.5))
                                .foregroundStyle(Color(hex: 0x9A9DAC))
                        }
                    }
                    .opacity(r.available ? 1 : 0.55)
                }
                .buttonStyle(.plain)
                if r.id != rows.last?.id { Divider() }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18).fill(.white)
            .shadow(color: Color(hex: 0x14152A).opacity(0.05), radius: 9, y: 3))
    }

    private func metric(_ icon: String, _ value: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 10))
            Text(value.formattedGrouped).font(.moblyBody(11.5, weight: .medium))
        }
        .foregroundStyle(Color(hex: 0x9A9DAC))
    }
}
