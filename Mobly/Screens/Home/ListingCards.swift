import SwiftUI

// MARK: - Featured hero carousel (top of Home)

/// Auto-sliding carousel of featured listings shown at the top of the Home feed.
struct FeaturedHeroCarousel: View {
    let listings: [Listing]
    var onOpen: (Listing) -> Void = { _ in }

    @State private var index = 0
    private let timer = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 12) {
            TabView(selection: $index) {
                ForEach(Array(listings.enumerated()), id: \.element.id) { i, listing in
                    HeroCard(listing: listing) { onOpen(listing) }
                        .padding(.horizontal, 22)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 210)
            .onReceive(timer) { _ in
                guard listings.count > 1 else { return }
                withAnimation(.easeInOut(duration: 0.6)) {
                    index = (index + 1) % listings.count
                }
            }

            // Page dots
            HStack(spacing: 6) {
                ForEach(listings.indices, id: \.self) { i in
                    Capsule()
                        .fill(i == index ? Color.moblyPrimary : Color(hex: 0xD5D8E2))
                        .frame(width: i == index ? 20 : 7, height: 7)
                        .animation(.easeInOut(duration: 0.25), value: index)
                }
            }
        }
    }
}

private struct HeroCard: View {
    let listing: Listing
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            ZStack(alignment: .bottomLeading) {
                ListingCover(listing: listing, width: ImageSlot.hero)
                    .scaledToFill()
                    .frame(height: 210)
                    .frame(maxWidth: .infinity)
                    .clipped()

                // Legibility gradient
                LinearGradient(
                    colors: [.clear, .black.opacity(0.55)],
                    startPoint: .center, endPoint: .bottom
                )

                // Top overlays
                VStack {
                    HStack(alignment: .top) {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 11)).foregroundStyle(Color.moblyPrimary)
                            Text(listing.rating)
                                .font(.moblyHeading(12)).foregroundStyle(Color(hex: 0x14152A))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(.white))
                        Spacer()
                        HeartButton(listing: listing)
                    }
                    Spacer()
                }
                .padding(14)

                // Bottom content
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(listing.title)
                            .font(.moblyHeading(20)).foregroundStyle(.white)
                            .lineLimit(1)
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(listing.price)
                                .font(.moblyHeading(16)).foregroundStyle(.white)
                            if !listing.priceUnit.isEmpty {
                                Text(LT(listing.priceUnit)).font(.moblyBody(12)).foregroundStyle(.white.opacity(0.85))
                            }
                        }
                    }
                    Spacer()
                    Text("Voir détails")
                        .font(.moblyHeading(13)).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Capsule().fill(Color.moblyPrimary))
                }
                .padding(16)
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: Color(hex: 0x14152A).opacity(0.18), radius: 16, y: 10)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Recommended card (horizontal "Recommandé pour vous" row)

struct RecommendedCard: View {
    let listing: Listing
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    ListingCover(listing: listing)
                        .scaledToFill()
                        .frame(height: 132)
                        .frame(maxWidth: .infinity)
                        .clipped()
                    HeartButton(listing: listing).padding(9)
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .top) {
                        Text(listing.title)
                            .font(.moblyHeading(14.5)).foregroundStyle(Color.moblyTextPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        HStack(spacing: 3) {
                            Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(Color.moblyAccent)
                            Text(listing.rating).font(.moblyBody(12, weight: .semibold)).foregroundStyle(Color.moblyTextPrimary)
                        }
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 11, weight: .medium))
                        Text(listing.location).font(.moblyBody(11.5)).lineLimit(1)
                    }
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(listing.price)
                            .font(.moblyHeading(14)).foregroundStyle(Color.moblyPrimary)
                        if !listing.priceUnit.isEmpty {
                            Text(LT(listing.priceUnit))
                                .font(.moblyBody(11))
                                .foregroundStyle(Color(hex: 0x9A9DAC))
                        }
                    }
                    .padding(.top, 2)
                }
                .padding(12)
            }
            .frame(width: 230)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color(hex: 0xE2E4EC), lineWidth: 1.5))
            .shadow(color: Color(hex: 0x14152A).opacity(0.05), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Heart button (toggleable favorite)

struct HeartButton: View {
    let listing: Listing
    @ObservedObject private var userData = UserDataStore.shared
    @ObservedObject private var auth = AuthStore.shared
    @State private var needsSignIn = false

    private var liked: Bool { userData.isFavorite(listing.id) }

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            guard auth.isSignedIn else { needsSignIn = true; return }
            Task {
                _ = await userData.toggleFavorite(listing)
                SessionTracker.shared.log("favorite.toggle", [
                    "listingId": listing.id, "favorited": userData.isFavorite(listing.id)
                ])
            }
        } label: {
            Image(systemName: liked ? "heart.fill" : "heart")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(liked ? Color.moblyAccent : Color(hex: 0x9A9DAC))
                .frame(width: 32, height: 32)
                .background(Circle().fill(.white))
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                .scaleEffect(liked ? 1.1 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.5), value: liked)
        }
        .buttonStyle(.plain)
        .alert("Connexion requise", isPresented: $needsSignIn) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Connectez-vous pour enregistrer vos favoris.")
        }
    }
}
