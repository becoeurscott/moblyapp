import SwiftUI

struct SavedSearch: Identifiable {
    let id = UUID()
    let title: String
    let filters: String
    let count: Int
    let alert: Bool
    var location: String = ""   // where to recenter Explore
}

struct FavoriteListing: Identifiable {
    /// Identity follows the listing so the row keeps it across store refreshes.
    var id: String { listing.id }
    let listing: Listing
    let oldPrice: String?     // struck-through old price, nil = none
    let priceDrop: Bool
}

enum FavoritesData {
    /// Saved searches start empty. The SavedSearch table exists but has no
    /// endpoint yet, so seeding them would show every user the same invented
    /// searches as if they were their own.
    static let searches: [SavedSearch] = []

}

struct FavoritesView: View {
    var onOpenListing: (Listing) -> Void = { _ in }
    var onOpenSearch: (SavedSearch) -> Void = { _ in }
    var onOpenSavedSearch: (SavedSearchItem) -> Void = { _ in }

    @ObservedObject private var userData = UserDataStore.shared
    @ObservedObject private var auth = AuthStore.shared
    @ObservedObject private var savedSearches = SavedSearchStore.shared
    @State private var tab = 0   // 0 = Espaces, 1 = Recherches
    @State private var sort: FavSort = .recent

    /// Straight from the server — no local copy, so an un-favourite made on
    /// the detail screen is reflected here immediately.
    private var favorites: [FavoriteListing] {
        userData.favorites.map { FavoriteListing(listing: $0, oldPrice: nil, priceDrop: false) }
    }

    enum FavSort: String, CaseIterable {
        case recent = "Récents", priceAsc = "Prix croissant", priceDesc = "Prix décroissant", rating = "Mieux notés"
    }

    private var sortedFavorites: [FavoriteListing] {
        func price(_ f: FavoriteListing) -> Int { Int(f.listing.price.filter(\.isNumber)) ?? 0 }
        switch sort {
        case .recent:   return favorites
        case .priceAsc: return favorites.sorted { price($0) < price($1) }
        case .priceDesc: return favorites.sorted { price($0) > price($1) }
        case .rating:   return favorites.sorted { $0.listing.rating > $1.listing.rating }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if tab == 0 {
                        if favorites.isEmpty { emptyEspaces } else { espacesTab }
                    } else {
                        if savedSearches.items.isEmpty { emptyRecherches } else { savedSearchesTab }
                    }
                }
                .padding(.bottom, 110)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.moblySurface)
        .refreshable { await userData.loadFavorites() }
        .task {
            guard auth.isSignedIn else { return }
            await userData.loadFavorites()
        }
    }

    /// Signed-out and signed-in need different copy: "Aucun favori" alone reads
    /// as a bug to someone who simply isn't logged in.
    private func emptyState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(Color(hex: 0xEEF0FE)).frame(width: 78, height: 78)
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Color.moblyPrimary)
            }
            .padding(.top, 70)
            Text(LT(title))
                .font(.moblyHeading(18))
                .foregroundStyle(Color.moblyTextPrimary)
            Text(LT(message))
                .font(.moblyBody(13.5))
                .foregroundStyle(Color(hex: 0x9A9DAC))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 44)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyEspaces: some View {
        emptyState(
            icon: auth.isSignedIn ? "heart" : "person.crop.circle",
            title: auth.isSignedIn ? "Aucun favori" : "Connectez-vous",
            message: auth.isSignedIn
                ? "Touchez le cœur sur une annonce pour la retrouver ici."
                : "Connectez-vous pour enregistrer vos annonces préférées."
        )
    }

    private var emptyRecherches: some View {
        emptyState(
            icon: "magnifyingglass",
            title: "Aucune recherche enregistrée",
            message: "Enregistrez une recherche depuis Explorer pour être alerté des nouvelles annonces."
        )
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 16) {
            HStack {
                Text(L("Préférés")).font(.moblyHeading(26)).foregroundStyle(Color.moblyTextPrimary)
                Spacer()
                Menu {
                    Picker("Trier", selection: $sort) {
                        ForEach(FavSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(sort == .recent ? Color.moblyTextPrimary : Color.moblyPrimary)
                        .frame(width: 42, height: 42)
                        .background(RoundedRectangle(cornerRadius: 14).fill(.white)
                            .shadow(color: Color(hex: 0x14152A).opacity(0.06), radius: 8, y: 2))
                }
            }

            HStack(spacing: 6) {
                segment("\(L("Espaces")) (\(favorites.count))", 0)
                segment("\(L("Recherches")) (\(savedSearches.count))", 1)
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0xECEDF2)))
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func segment(_ title: String, _ i: Int) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { tab = i }
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            Text(LT(title))
                .font(.moblyBody(13, weight: .semibold))
                .foregroundStyle(tab == i ? .white : Color(hex: 0x6B6F80))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 11)
                        .fill(tab == i ? Color.moblyPrimary : .clear)
                        .shadow(color: tab == i ? Color.moblyPrimary.opacity(0.25) : .clear, radius: 8, y: 3)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: Espaces tab

    private var espacesTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recherches enregistrées")
                .font(.moblyHeading(15))
                .foregroundStyle(Color.moblyTextPrimary)
                .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 11)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 11) {
                    ForEach(FavoritesData.searches) { s in
                        Button { onOpenSearch(s) } label: { SavedSearchCard(search: s) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
            }
            .padding(.bottom, 24)

            Text("Espaces sauvegardés")
                .font(.moblyHeading(15))
                .foregroundStyle(Color.moblyTextPrimary)
                .padding(.horizontal, 18).padding(.bottom, 12)

            VStack(spacing: 14) {
                ForEach(sortedFavorites) { f in
                    FavoriteRow(fav: f,
                                onOpen: { onOpenListing(f.listing) },
                                onUnfav: { Task { await userData.toggleFavorite(f.listing) } })
                }
            }
            .padding(.horizontal, 18)
        }
    }

    // MARK: Recherches tab

    private var recherchesTab: some View {
        VStack(spacing: 12) {
            ForEach(FavoritesData.searches) { s in
                Button { onOpenSearch(s) } label: { SavedSearchWideCard(search: s) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18).padding(.top, 16)
    }

    // MARK: Recherches enregistrées (SavedSearchStore)

    private var savedSearchesTab: some View {
        VStack(spacing: 12) {
            ForEach(savedSearches.items) { item in
                SavedSearchRow(item: item,
                               onOpen: { onOpenSavedSearch(item) },
                               onDelete: { savedSearches.remove(item) })
            }
        }
        .padding(.horizontal, 18).padding(.top, 16)
    }
}

/// Row in Favoris > Recherches for a `SavedSearchItem`. Tap opens the
/// underlying search; the trailing "×" removes it.
struct SavedSearchRow: View {
    let item: SavedSearchItem
    var onOpen: () -> Void
    var onDelete: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.moblyPrimary.opacity(0.14)).frame(width: 44, height: 44)
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.moblyPrimary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.label)
                    .font(.moblyHeading(14.5))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.moblyBody(11.5))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                    .lineLimit(2)
            }
            Spacer()
            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color(hex: 0xF4F5F8)))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(.white))
        .shadow(color: Color(hex: 0x14152A).opacity(0.04), radius: 8, y: 2)
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
    }
}

// MARK: - Saved search cards

struct SavedSearchCard: View {
    let search: SavedSearch
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 11).fill(Color.moblySurfaceTint).frame(width: 36, height: 36)
                    Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.moblyPrimary)
                }
                Spacer()
                if search.alert {
                    HStack(spacing: 4) {
                        Circle().fill(Color(hex: 0x25D366)).frame(width: 6, height: 6)
                        Text("Alerte").font(.moblyBody(10, weight: .semibold)).foregroundStyle(Color(hex: 0x1F8A5B))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Color(hex: 0xE9F9EF)))
                }
            }
            .padding(.bottom, 10)
            Text(search.title).font(.moblyHeading(14.5)).foregroundStyle(Color.moblyTextPrimary)
            Text(search.filters).font(.moblyBody(11.5)).foregroundStyle(Color(hex: 0x9A9DAC))
                .padding(.top, 3).padding(.bottom, 10)
            Text("\(search.count) nouveaux").font(.moblyBody(12, weight: .semibold)).foregroundStyle(Color.moblyPrimary)
        }
        .padding(15)
        .frame(width: 190, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(.white))
        .shadow(color: Color(hex: 0x14152A).opacity(0.06), radius: 14, y: 4)
    }
}

struct SavedSearchWideCard: View {
    let search: SavedSearch
    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 13).fill(Color.moblySurfaceTint).frame(width: 48, height: 48)
                Image(systemName: "magnifyingglass").font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.moblyPrimary)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(search.title).font(.moblyHeading(15)).foregroundStyle(Color.moblyTextPrimary)
                    if search.alert {
                        HStack(spacing: 3) {
                            Circle().fill(Color(hex: 0x25D366)).frame(width: 5, height: 5)
                            Text("Alerte").font(.moblyBody(9.5, weight: .semibold)).foregroundStyle(Color(hex: 0x1F8A5B))
                        }
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Capsule().fill(Color(hex: 0xE9F9EF)))
                    }
                }
                Text(search.filters).font(.moblyBody(11.5)).foregroundStyle(Color(hex: 0x9A9DAC))
                Text("\(search.count) nouveaux").font(.moblyBody(12, weight: .semibold)).foregroundStyle(Color.moblyPrimary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(hex: 0xC4C7D2))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18).fill(.white))
        .shadow(color: Color(hex: 0x14152A).opacity(0.06), radius: 14, y: 4)
    }
}

// MARK: - Favorite row

struct FavoriteRow: View {
    let fav: FavoriteListing
    var onOpen: () -> Void
    var onUnfav: () -> Void
    @State private var liked = true
    @State private var offsetX: CGFloat = 0

    var body: some View {
        ZStack(alignment: .trailing) {
            // Red delete revealed on swipe-left
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(hex: 0xE5484D))
                .overlay(
                    VStack(spacing: 3) {
                        Image(systemName: "heart.slash.fill").font(.system(size: 18, weight: .semibold))
                        Text("Retirer").font(.moblyBody(11, weight: .semibold))
                    }.foregroundStyle(.white).padding(.trailing, 22),
                    alignment: .trailing
                )

            rowCard
                .offset(x: offsetX)
                .highPriorityGesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { v in
                            // right → left only
                            if v.translation.width < 0 {
                                offsetX = max(v.translation.width, -120)
                            }
                        }
                        .onEnded { v in
                            if v.translation.width < -80 {
                                withAnimation(.easeIn(duration: 0.2)) { offsetX = -450 }
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { onUnfav() }
                            } else {
                                withAnimation(.spring()) { offsetX = 0 }
                            }
                        }
                )
        }
    }

    private var rowCard: some View {
        Button(action: onOpen) {
            HStack(spacing: 13) {
                ZStack(alignment: .topLeading) {
                    ListingCover(listing: fav.listing, width: ImageSlot.thumb)
                        .frame(width: 108, height: 108)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    ZStack {
                        Circle().fill(Color(hex: 0xB8CCFF))
                        Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(Color.moblyPrimary)
                    }.frame(width: 22, height: 22).padding(7)
                    // heart top-right
                    HStack { Spacer()
                        Button {
                            liked.toggle()
                            if !liked { onUnfav() }
                        } label: {
                            Image(systemName: liked ? "heart.fill" : "heart")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.moblyAccent)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(.white.opacity(0.92)))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(7)
                    .frame(width: 108)
                }

                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        Text(fav.listing.title).font(.moblyHeading(15)).foregroundStyle(Color.moblyTextPrimary)
                        Spacer()
                        HStack(spacing: 3) {
                            Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Color.moblyPrimary)
                            Text(fav.listing.rating).font(.moblyBody(10.5, weight: .bold)).foregroundStyle(Color.moblyTextPrimary)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.moblySurfaceTint))
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "mappin.and.ellipse").font(.system(size: 11, weight: .medium))
                        Text(fav.listing.location).font(.moblyBody(11.5))
                    }
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                    .padding(.top, 3)

                    if fav.priceDrop {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down").font(.system(size: 10, weight: .bold))
                            Text("Prix baissé").font(.moblyBody(10.5, weight: .semibold))
                        }
                        .foregroundStyle(Color(hex: 0x1F8A5B))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Color(hex: 0xE9F9EF)))
                        .padding(.top, 7)
                    }

                    Spacer(minLength: 4)

                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(fav.listing.price)\(LT(fav.listing.priceUnit))").font(.moblyHeading(15)).foregroundStyle(Color.moblyPrimary)
                        if let old = fav.oldPrice {
                            Text(old).font(.moblyBody(11)).foregroundStyle(Color(hex: 0xB4B7C2)).strikethrough()
                        }
                    }
                }
                .padding(.vertical, 5).padding(.trailing, 4)
            }
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 18).fill(.white))
            .shadow(color: Color(hex: 0x14152A).opacity(0.06), radius: 16, y: 4)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    FavoritesView()
}
