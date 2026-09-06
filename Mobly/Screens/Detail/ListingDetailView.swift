import SwiftUI
import MapKit

struct ListingDetailView: View {
    let listing: Listing
    /// Free-form attribution tag sent to the backend so the owner's
    /// "Origine des vues" stat can bucket real traffic sources: "home",
    /// "explore", "search", "recommended", "favorites", "detail-similar",
    /// "profile". Nil bucketed as "Autre".
    var source: String? = nil
    var onClose: () -> Void = {}
    var onMessage: () -> Void = {}
    var onCall: () -> Void = {}
    var onRequestVisit: () -> Void = {}

    @State private var photoIndex = 0
    @ObservedObject private var userData = UserDataStore.shared
    private var liked: Bool { userData.isFavorite(listing.id) }
    @State private var showViewer = false
    @State private var showGrid = false
    @State private var showReviewSheet = false
    @State private var descExpanded = false
    @State private var showAllReviewsSheet = false
    @State private var reviews: [Review] = Review.samples

    @ObservedObject private var chat = ChatStore.shared
    @ObservedObject private var auth = AuthStore.shared
    /// Real conversation with this listing's owner, once opened. The owner is
    /// resolved server-side from the listing id — the client never names them.
    @State private var openedThread: ChatThread?
    @State private var openingChat = false
    @State private var needsSignIn = false
    @State private var contactFailed = false
    @State private var showVisitSheet = false
    /// Pushed detail view for a similar listing. Presented as a cover so
    /// the user can stack detail → similar → similar → back cleanly.
    @State private var pushedListing: Listing?
    /// Server-confirmed availability. Starts from the model we were handed and
    /// is re-checked on appear, because the copy that got us here may be a
    /// cached feed entry or a chat pill from days ago.
    @State private var isAvailable: Bool = true

    /// Owner name from the listing's server payload. Was hardcoded "Marie
    /// Ngono" on every listing, crediting one invented person as the owner of
    /// all 126 real properties.
    private var ownerName: String { listing.ownerName ?? "Propriétaire" }

    private func contactOwner() {
        guard auth.isSignedIn else { needsSignIn = true; return }
        // Present the chat screen immediately with a skeleton preview so the
        // ~1.3s Supabase round-trip on POST /threads doesn't leave the user
        // staring at an unresponsive button. ChatOpeningView swaps to the
        // real ChatThreadView the moment openThread resolves.
        openingChat = true
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let autoSlide = Timer.publish(every: 3.5, on: .main, in: .common).autoconnect()

    /// Real coordinate for the listing's map card. Priority: DB lat/lng →
    /// city-name lookup (Douala, Yaoundé, Buéa…) → Douala centre as a last
    /// resort. Every annonce now shows its own place on the map instead of
    /// every card centring on Douala.
    private var coordinate: CLLocationCoordinate2D {
        if let lat = listing.lat, let lng = listing.lng, lat != 0 || lng != 0 {
            return CLLocationCoordinate2D(latitude: lat, longitude: lng)
        }
        return CityCoordinates.coordinate(for: listing.location)
            ?? CLLocationCoordinate2D(latitude: 4.0511, longitude: 9.7679)
    }

    private var gallery: [String] {
        if !listing.photos.isEmpty { return listing.photos }
        if let url = listing.coverUrl { return [url] }
        return [listing.imageName]
    }

    private var amenities: [(String, String)] {
        let iconMap: [String: String] = [
            "Wifi": "wifi",
            "TV": "tv",
            "Climatisation": "snowflake",
            "Parking": "car.fill",
            "Piscine": "figure.pool.swim",
            "Sécurité": "lock.shield.fill",
            "Cuisine équipée": "fork.knife",
            "Lave-linge": "washer.fill",
            "Eau chaude": "drop.fill",
            "Eau courante": "drop.fill",
            "Petit-déjeuner": "cup.and.saucer.fill",
            "Salle de sport": "dumbbell.fill",
            "Meublé": "sofa.fill",
            "Produits de toilette": "shower.fill",
            "Trousse de secours": "cross.case.fill",
        ]
        if listing.tags.isEmpty {
            // Fallback set — never assume "Meublé" on a listing the owner
            // explicitly published as Non meublé, otherwise the description
            // and the Non meublé filter contradict each other.
            let isNonMeuble = listing.deals.contains("Non meublé")
            var fallback: [(String, String)] = [
                ("wifi","Wifi"),
                ("drop.fill","Eau courante"),
                ("car.fill","Parking"),
                ("snowflake","Climatisation"),
            ]
            if !isNonMeuble {
                fallback.insert(("sofa.fill","Meublé"), at: 1)
            }
            return fallback
        }
        return listing.tags.map { tag in (iconMap[tag] ?? "checkmark.circle.fill", tag) }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.white.ignoresSafeArea()

            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    heroGallery
                    heroButtons
                }

                ScrollView(showsIndicators: false) {
                    content
                        .padding(.horizontal, 22)
                        .padding(.top, 14)
                        .padding(.bottom, 120)
                }
            }

            VStack(spacing: 0) {
                if !isAvailable { unavailableBanner }
                stickyBar
            }
        }
        .ignoresSafeArea(edges: .top)
        .swipeToDismiss(onDismiss: onClose)
        .onAppear {
            SessionTracker.shared.log("listing.view", [
                "listingId": listing.id,
                "category": listing.category
            ])
            // Server-side view event — powers the owner's real-time stats
            // (views counter, per-day chart, "Origine des vues"). Fire and
            // forget: the detail page must never wait on this.
            isAvailable = listing.available
            Task {
                _ = try? await MoblyAPI.shared.trackListingView(
                    id: listing.id, source: source ?? "detail")
                // Authoritative check — an owner may have pulled the space
                // offline since this listing was cached.
                if let fresh = try? await MoblyAPI.shared.listing(id: listing.id) {
                    await MainActor.run { isAvailable = fresh.available }
                }
            }
        }
        .fullScreenCover(isPresented: $showViewer) {
            ImageViewer(images: gallery, index: $photoIndex)
                .swipeToDismiss(onDismiss: { showViewer = false })
        }
        .fullScreenCover(isPresented: $showGrid) {
            PhotoGridView(images: gallery) { i in
                photoIndex = i
                showGrid = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showViewer = true }
            } onClose: { showGrid = false }
                .swipeToDismiss(onDismiss: { showGrid = false })
        }
        .fullScreenCover(item: $openedThread) { thread in
            ChatThreadView(thread: thread, onBack: { openedThread = nil })
        }
        .fullScreenCover(item: $pushedListing) { l in
            ListingDetailView(listing: l,
                              source: "detail-similar",
                              onClose: { pushedListing = nil })
        }
        .fullScreenCover(isPresented: $openingChat) {
            ChatOpeningView(listing: listing, onBack: { openingChat = false })
        }
        .alert("Impossible d'ouvrir la conversation", isPresented: $contactFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Vérifiez votre connexion et réessayez.")
        }
        .alert("Connexion requise", isPresented: $needsSignIn) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Connectez-vous pour contacter le propriétaire.")
        }
        .sheet(isPresented: $showVisitSheet) {
            RequestVisitSheet(listing: listing)
                .presentationDetents([.height(520)])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: Photo gallery strip (scrolls right→left; "Voir tout" at 7+ photos)

    private var photoStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Photos")
                    .font(.moblyHeading(16))
                    .foregroundStyle(Color.moblyTextPrimary)
                Text("(\(gallery.count))")
                    .font(.moblyBody(13))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                Spacer()
                if gallery.count >= 7 {
                    Button { showGrid = true } label: {
                        Text("Voir tout")
                            .font(.moblyBody(12.5, weight: .semibold))
                            .foregroundStyle(Color.moblyPrimary)
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    let maxThumbs = 5
                    let shown = Array(gallery.prefix(maxThumbs).enumerated())
                    ForEach(shown, id: \.offset) { i, name in
                        let isLastShown = (i == maxThumbs - 1) && gallery.count > maxThumbs
                        Button {
                            if isLastShown { showGrid = true }
                            else { photoIndex = i; showViewer = true }
                        } label: {
                            Color.clear
                                .frame(width: 84, height: 84)
                                .overlay(RemoteImage(source: name, width: ImageSlot.thumb).clipped())
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay {
                                    if isLastShown {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .fill(.black.opacity(0.5))
                                            VStack(spacing: 2) {
                                                Image(systemName: "photo.on.rectangle.angled")
                                                    .font(.system(size: 15, weight: .semibold))
                                                Text("+\(gallery.count - maxThumbs + 1)")
                                                    .font(.moblyHeading(15))
                                            }
                                            .foregroundStyle(.white)
                                        }
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Hero gallery

    /// Roughly half the screen, like the Airbnb/Zillow immersive cover — was a
    /// flat 380pt, which on a tall phone left the photo covering barely a
    /// third of the screen instead of reading as a cover image.
    private var heroHeight: CGFloat {
        UIScreen.main.bounds.height * 0.38
    }

    private var safeAreaTop: CGFloat {
        (UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.safeAreaInsets.top) ?? 59
    }

    private var heroGallery: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(gallery.enumerated()), id: \.offset) { i, name in
                        RemoteImage(source: name, width: ImageSlot.hero, contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                            .id(i)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: Binding(
                get: { photoIndex },
                set: { if let v = $0 { photoIndex = v } }
            ))
        }
        .onReceive(autoSlide) { _ in
            guard !reduceMotion, !showViewer else { return }
            withAnimation(.easeInOut(duration: 0.6)) {
                photoIndex = (photoIndex + 1) % gallery.count
            }
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 6) {
                ForEach(gallery.indices, id: \.self) { i in
                    Capsule()
                        .fill(i == photoIndex ? .white : .white.opacity(0.5))
                        .frame(width: i == photoIndex ? 16 : 6, height: 6)
                        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: photoIndex)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Capsule().fill(.black.opacity(0.28)))
            .padding(.bottom, 16)
        }
        .frame(height: heroHeight)
        .clipped()
        .clipShape(UnevenRoundedRectangle(
            cornerRadii: .init(bottomLeading: 26, bottomTrailing: 26),
            style: .continuous))
        .ignoresSafeArea(edges: .top)
    }

    private var heroButtons: some View {
        HStack {
            CircleIconButton(icon: "xmark", action: onClose)
            Spacer()
            HStack(spacing: 10) {
                CircleIconButton(icon: "square.and.arrow.up") {}
                CircleIconButton(icon: liked ? "heart.fill" : "heart",
                                 tint: liked ? .moblyAccent : .moblyTextPrimary) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    guard auth.isSignedIn else { needsSignIn = true; return }
                    Task {
                        _ = await userData.toggleFavorite(listing)
                        SessionTracker.shared.log("favorite.toggle", [
                            "listingId": listing.id,
                            "favorited": userData.isFavorite(listing.id),
                            "source": "listing_detail"
                        ])
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, safeAreaTop + 8)
    }

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(listing.title)
                .font(.moblyHeading(24))
                .foregroundStyle(Color.moblyTextPrimary)

            HStack(spacing: 6) {
                if listing.rating.isEmpty {
                    Text("Nouveau")
                        .font(.moblyBody(13, weight: .semibold))
                        .foregroundStyle(Color.moblyPrimary)
                    Text("· Aucun avis")
                        .font(.moblyBody(13))
                        .foregroundStyle(Color(hex: 0x9A9DAC))
                } else {
                    Image(systemName: "star.fill")
                        .font(.system(size: 12)).foregroundStyle(Color.moblyPrimary)
                    Text(listing.rating)
                        .font(.moblyBody(13, weight: .semibold))
                        .foregroundStyle(Color.moblyTextPrimary)
                    Text("(\(reviews.count) avis)")
                        .font(.moblyBody(13))
                        .foregroundStyle(Color(hex: 0x9A9DAC))
                }
                Text("·").foregroundStyle(Color(hex: 0x9A9DAC))
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                Text(listing.location)
                    .font(.moblyBody(13))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
            }
            .padding(.top, 8)

            // Host row + in-app contact (2026 pivot)
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Color(hex: 0xEEF0FE)).frame(width: 54, height: 54)
                    Image(systemName: "person.fill")
                        .font(.system(size: 24)).foregroundStyle(Color.moblyPrimary)
                }
                .frame(width: 54, height: 54)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(ownerName)
                            .font(.moblyHeading(16))
                            .foregroundStyle(Color.moblyTextPrimary)
                        verifiedBadge
                    }
                    Text("Propriétaire vérifié")
                        .font(.moblyBody(13))
                        .foregroundStyle(Color(hex: 0x9A9DAC))
                }
                Spacer()
                CircleIconButton(icon: "phone.fill", bg: .white,
                                 tint: .moblyPrimary, size: 44, action: onCall)
                CircleIconButton(icon: "bubble.left.fill", bg: .white,
                                 tint: .moblyPrimary, size: 44, action: contactOwner)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(hex: 0xF8F8FA)))
            .padding(.top, 12)

            divider

            // Description
            Text("Description")
                .font(.moblyHeading(17))
                .foregroundStyle(Color.moblyTextPrimary)
                .padding(.bottom, 10)
            Text(descriptionText)
                .font(.moblyBody(13.5))
                .foregroundStyle(Color(hex: 0x4A4E5A))
                .lineSpacing(4)
                .lineLimit(descExpanded ? nil : 4)
            if !descExpanded && descriptionText.count > 120 {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { descExpanded = true }
                } label: {
                    Text("Lire tout")
                        .font(.moblyBody(13, weight: .semibold))
                        .foregroundStyle(Color.moblyPrimary)
                }
                .padding(.top, 4)
            }

            // Photo gallery strip
            photoStrip
                .padding(.top, 16)

            if !listing.features.isEmpty {
                divider
                Text("Caractéristiques")
                    .font(.moblyHeading(17))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .padding(.bottom, 14)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    let sorted = listing.features.sorted(by: { $0.key < $1.key })
                    ForEach(sorted, id: \.key) { key, value in
                        VStack(spacing: 6) {
                            Text(LT(value))
                                .font(.moblyHeading(18))
                                .foregroundStyle(Color.moblyTextPrimary)
                            Text(key)
                                .font(.moblyBody(12.5))
                                .foregroundStyle(Color(hex: 0x9A9DAC))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(hex: 0xF8F8FA)))
                    }
                }
            }

            divider

            Text("Équipements")
                .font(.moblyHeading(17))
                .foregroundStyle(Color.moblyTextPrimary)
                .padding(.bottom, 14)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)],
                      spacing: 10) {
                ForEach(amenities, id: \.1) { icon, label in
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(hex: 0xEEF0FE))
                            Image(systemName: icon)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color.moblyPrimary)
                        }
                        .frame(width: 42, height: 42)
                        Text(LT(label))
                            .font(.moblyBody(13, weight: .medium))
                            .foregroundStyle(Color.moblyTextPrimary)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(hex: 0xF8F8FA)))
                }
            }

            divider

            trustRow(icon: "checkmark.shield.fill", title: "Hôte vérifié",
                     sub: "Identité et documents confirmés par Mobly.")
                .padding(.bottom, 16)
            trustRow(icon: "calendar.badge.clock", title: "Visite sur place possible",
                     sub: "Planifiez une visite avant de vous engager.")

            divider

            // Location map
            Text("Localisation")
                .font(.moblyHeading(17))
                .foregroundStyle(Color.moblyTextPrimary)
                .padding(.bottom, 4)
            HStack(spacing: 5) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 11, weight: .medium))
                Text(listing.location)
                    .font(.moblyBody(12.5))
            }
            .foregroundStyle(Color(hex: 0x9A9DAC))
            .padding(.bottom, 12)
            locationMap

            divider

            // Reviews
            reviewsSection

            // Similar listings
            if !similarListings.isEmpty {
                divider
                Text("Similaires")
                    .font(.moblyHeading(17))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .padding(.bottom, 14)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(similarListings) { l in
                            Button { pushedListing = l } label: {
                                SimilarCard(listing: l)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var similarListings: [Listing] {
        ListingStore.shared.listings
            .filter { $0.category == listing.category && $0.id != listing.id }
            .prefix(6).map { $0 }
    }

    // MARK: Location map

    private var locationMap: some View {
        ZStack(alignment: .bottomTrailing) {
            Map(initialPosition: .region(
                MKCoordinateRegion(center: coordinate,
                                   span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))
            )) {
                Annotation(listing.title, coordinate: coordinate) {
                    ZStack {
                        Circle().fill(Color.moblyAccent.opacity(0.2)).frame(width: 44, height: 44)
                        Circle().fill(Color.moblyAccent).frame(width: 18, height: 18)
                            .overlay(Circle().stroke(.white, lineWidth: 3))
                    }
                }
            }
            .frame(height: 170)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: 0xEFF0F4), lineWidth: 1))
            .allowsHitTesting(false)

            Button { openInMaps() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.turn.up.right").font(.system(size: 11, weight: .semibold))
                    Text("Itinéraire").font(.moblyBody(12, weight: .semibold))
                }
                .foregroundStyle(Color.moblyPrimary)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Capsule().fill(.white))
                .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            .padding(12)
        }
    }

    /// Open the listing's coordinate in Google Maps if installed, otherwise
    /// in Apple Maps via the universal `maps.apple.com` link. Uses driving
    /// directions from the user's current location.
    private func openInMaps() {
        let lat = coordinate.latitude
        let lng = coordinate.longitude
        let name = listing.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Annonce"
        // Google Maps app (only opens if the URL scheme is declared in
        // LSApplicationQueriesSchemes — otherwise canOpenURL returns false
        // and we fall through to Apple Maps, which always works).
        let google = URL(string: "comgooglemaps://?daddr=\(lat),\(lng)&directionsmode=driving")!
        if UIApplication.shared.canOpenURL(google) {
            UIApplication.shared.open(google); return
        }
        // Apple Maps universal link — opens the Maps app on iOS without any
        // scheme declaration and falls back to Safari elsewhere.
        let apple = URL(string: "http://maps.apple.com/?daddr=\(lat),\(lng)&q=\(name)")!
        UIApplication.shared.open(apple)
    }

    // MARK: Reviews

    private var averageRating: Double {
        guard !reviews.isEmpty else { return 0 }
        return Double(reviews.map(\.stars).reduce(0, +)) / Double(reviews.count)
    }

    private var reviewsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Avis")
                    .font(.moblyHeading(17))
                    .foregroundStyle(Color.moblyTextPrimary)
                if reviews.isEmpty {
                    Text("· Aucun avis")
                        .font(.moblyBody(13))
                        .foregroundStyle(Color(hex: 0x9A9DAC))
                } else {
                    Image(systemName: "star.fill")
                        .font(.system(size: 12)).foregroundStyle(Color.moblyPrimary)
                    Text(String(format: "%.1f", averageRating))
                        .font(.moblyBody(13, weight: .semibold))
                        .foregroundStyle(Color.moblyTextPrimary)
                    Text("· \(reviews.count) avis")
                        .font(.moblyBody(13))
                        .foregroundStyle(Color(hex: 0x9A9DAC))
                }
                Spacer()
                if !reviews.isEmpty {
                    Button {
                        showAllReviewsSheet = true
                    } label: {
                        Text("Voir tout")
                            .font(.moblyBody(12.5, weight: .semibold))
                            .foregroundStyle(Color.moblyPrimary)
                    }
                }
                Button {
                    showReviewSheet = true
                } label: {
                    Text("Laisser un avis")
                        .font(.moblyBody(12.5, weight: .semibold))
                        .foregroundStyle(Color.moblyPrimary)
                        .padding(.leading, reviews.isEmpty ? 0 : 12)
                }
            }
            .padding(.bottom, 16)

            if reviews.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "star.bubble")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(Color(hex: 0xD5D8E2))
                    Text("Soyez le premier à laisser un avis")
                        .font(.moblyBody(14, weight: .medium))
                        .foregroundStyle(Color(hex: 0x9A9DAC))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(Array(reviews.prefix(5))) { review in
                            ReviewCard(review: review)
                        }
                        if reviews.count > 5 {
                            Button {
                                showAllReviewsSheet = true
                            } label: {
                                VStack(spacing: 8) {
                                    ZStack {
                                        Circle().fill(Color.moblySurfaceTint).frame(width: 44, height: 44)
                                        Image(systemName: "arrow.right")
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundStyle(Color.moblyPrimary)
                                    }
                                    Text("Voir tout")
                                        .font(.moblyBody(12.5, weight: .semibold))
                                        .foregroundStyle(Color.moblyPrimary)
                                }
                                .frame(width: 100)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 22)
                }
                .padding(.horizontal, -22)
            }
        }
        .sheet(isPresented: $showReviewSheet) {
            LeaveReviewSheet { stars, text in
                reviews.insert(Review(author: "Vous", initial: "V", stars: stars,
                                      timeAgo: "À l'instant", text: text), at: 0)
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showAllReviewsSheet) {
            AllReviewsView(reviews: reviews)
        }
    }

    private func trustRow(icon: String, title: String, sub: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(Color.moblyPrimary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(LT(title))
                    .font(.moblyHeading(14.5))
                    .foregroundStyle(Color.moblyTextPrimary)
                Text(LT(sub))
                    .font(.moblyBody(12.5))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
            }
        }
    }

    private var descriptionText: String {
        // Prefer the owner's own description; fall back to a generated blurb.
        if !listing.about.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return listing.about
        }
        return "\(listing.title) est un espace \(listing.subtitle.isEmpty ? "confortable" : listing.subtitle.lowercased()) situé à \(listing.location). Lumineux, bien entretenu et proche des commerces, transports et écoles. Idéal pour un séjour longue durée. Visite sur place possible avant tout engagement — contactez l'hôte directement dans l'app."
    }

    private var verifiedBadge: some View {
        ZStack {
            Circle().fill(Color(hex: 0xB8CCFF))
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(Color.moblyPrimary)
        }
        .frame(width: 16, height: 16)
    }

    private var divider: some View {
        Rectangle().fill(Color(hex: 0xEFF0F4)).frame(height: 1)
            .padding(.vertical, 18)
    }

    // MARK: Sticky bar

    /// Shown when the owner has taken the space off the market. Placed above
    /// the CTA bar so it is impossible to miss before tapping Message.
    private var unavailableBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(hex: 0xE5484D))
            VStack(alignment: .leading, spacing: 1) {
                Text("Non disponible")
                    .font(.moblyHeading(13.5))
                    .foregroundStyle(Color.moblyTextPrimary)
                Text("Le propriétaire a retiré cet espace du marché.")
                    .font(.moblyBody(11.5))
                    .foregroundStyle(Color(hex: 0x6B6F80))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: 0xFDEDED))
    }

    private var stickyBar: some View {
        HStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(listing.price)
                    .font(.moblyHeading(16))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if !listing.priceUnit.isEmpty {
                    Text(LT(listing.priceUnit))
                        .font(.moblyBody(11))
                        .foregroundStyle(Color(hex: 0x9A9DAC))
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            Button {
                guard AuthStore.shared.isSignedIn else { needsSignIn = true; return }
                showVisitSheet = true
            } label: {
                Image(systemName: "calendar")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.moblyPrimary)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Color(hex: 0xEEF0FE)))
            }
            .buttonStyle(.plain)
            .disabled(!isAvailable)
            .opacity(isAvailable ? 1 : 0.4)
            Button(action: contactOwner) {
                Text("Message")
                    .font(.moblyHeading(14))
                    .foregroundStyle(Color(hex: 0x3A4FF0))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 16)
                    .frame(height: 48)
                    .background(Capsule().fill(isAvailable ? Color(hex: 0xDDE1FC) : Color(hex: 0xC4C7D2)))
            }
            .disabled(!isAvailable)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 30)
        .background(
            Rectangle().fill(.ultraThinMaterial)
                .shadow(color: Color(hex: 0x14152A).opacity(0.08), radius: 16, y: -4)
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

// MARK: - Photo grid (all photos)

struct PhotoGridView: View {
    let images: [String]
    var onSelect: (Int) -> Void
    var onClose: () -> Void

    private let cols = [GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.moblyTextPrimary)
                        .frame(width: 40, height: 40)
                        .background(RoundedRectangle(cornerRadius: 13).fill(Color(hex: 0xF4F5F8)))
                }
                Spacer()
                Text("Toutes les photos")
                    .font(.moblyHeading(17))
                    .foregroundStyle(Color.moblyTextPrimary)
                Spacer()
                Color.clear.frame(width: 40, height: 40)
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 8)

            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: cols, spacing: 8) {
                    ForEach(Array(images.enumerated()), id: \.offset) { i, name in
                        Button { onSelect(i) } label: {
                            Color.clear
                                .frame(maxWidth: .infinity)
                                .aspectRatio(1, contentMode: .fit)
                                .overlay(RemoteImage(source: name, width: ImageSlot.thumb).clipped())
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
        }
        .background(Color.white)
    }
}

// MARK: - Full-screen image viewer

struct ImageViewer: View {
    let images: [String]
    @Binding var index: Int
    @Environment(\.dismiss) private var dismiss

    @State private var zoom: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                CircleIconButton(icon: "xmark", bg: .white.opacity(0.15), tint: .white) {
                    dismiss()
                }
                Spacer()
                Text("\(index + 1)/\(images.count)")
                    .font(.moblyBody(13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(.white.opacity(0.15)))
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 8)

            TabView(selection: $index) {
                ForEach(Array(images.enumerated()), id: \.offset) { i, name in
                    RemoteImage(source: name, width: ImageSlot.full, contentMode: .fit)
                        .scaleEffect(i == index ? zoom : 1)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { zoom = max(1, min($0, 4)) }
                                .onEnded { _ in withAnimation(.spring()) { zoom = 1 } }
                        )
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
        }
        .background(Color.black.ignoresSafeArea())
    }
}

// MARK: - Circle icon button

struct CircleIconButton: View {
    var icon: String
    var bg: Color = .white
    var tint: Color = .moblyTextPrimary
    var size: CGFloat = 38
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(Circle().fill(bg))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                .contentShape(Circle())
        }
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Circle())
        .buttonStyle(.plain)
    }
}

private struct SimilarCard: View {
    let listing: Listing
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ListingCover(listing: listing)
                .frame(width: 160, height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(listing.title)
                .font(.moblyHeading(13))
                .foregroundStyle(Color.moblyTextPrimary)
                .lineLimit(1)
            Text(listing.price + " " + listing.priceUnit)
                .font(.moblyBody(12, weight: .semibold))
                .foregroundStyle(Color.moblyPrimary)
        }
        .frame(width: 160)
    }
}

#Preview {
    ListingDetailView(listing: Listing(
        id: "preview-1",
        title: "Appartement Vue Mer · Kribi",
        location: "Kribi, Cameroun",
        price: "45 000 FCFA",
        rating: "4.7",
        imageName: "ListingGreen",
        coverUrl: nil,
        photos: [],
        category: "Appartements",
        subtitle: "Meublé · 2 chambres",
        about: "Magnifique appartement avec vue sur la mer à Kribi.",
        verified: true,
        boosted: false,
        tags: ["Wifi", "Climatisation", "Parking"],
        reviewCount: 42,
        deals: ["À louer", "Meublé"]
    ))
}
