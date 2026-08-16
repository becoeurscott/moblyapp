import SwiftUI

/// Bridging view shown the instant a user taps "Message l'hôte" on a listing.
///
/// The real thread only exists after `POST /threads` finishes — on a Douala
/// connection that's ~1.3s of blank silence if we wait before presenting
/// anything. Instead we present *this* view immediately: the same header,
/// listing pill, and composer as `ChatThreadView`, with skeleton message
/// bubbles pulsing where the real messages will land. As soon as the thread
/// id comes back, we swap to the real `ChatThreadView` — which itself has
/// nothing left to fetch because it also observes `ChatStore.messages`.
struct ChatOpeningView: View {
    let listing: Listing
    var onBack: () -> Void = {}

    @ObservedObject private var chat = ChatStore.shared
    @ObservedObject private var auth = AuthStore.shared
    @State private var resolvedThread: ChatThread?
    @State private var openFailed = false

    var body: some View {
        Group {
            if let t = resolvedThread {
                // Real thread is ready — hand off. ChatThreadView loads
                // messages in its own .task the moment it appears.
                ChatThreadView(thread: t, onBack: onBack)
                    .transition(.opacity)
            } else {
                ChatSkeletonScreen(listing: listing, onBack: onBack)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: resolvedThread?.id)
        .task { await open() }
        .alert("Impossible d'ouvrir la conversation", isPresented: $openFailed) {
            Button("Réessayer") { Task { await open() } }
            Button("Annuler", role: .cancel) { onBack() }
        } message: {
            Text("Vérifiez votre connexion et réessayez.")
        }
    }

    private func open() async {
        guard auth.isSignedIn else { return }
        guard let dto = await chat.openThread(listingId: listing.id) else {
            openFailed = true
            return
        }
        resolvedThread = ChatThread.from(dto, myUserId: auth.user?.id)
    }
}

// MARK: - Skeleton

/// The visible-while-loading screen. Same overall shape as `ChatThreadView`
/// so the swap doesn't jump: header + listing pill + a few placeholder
/// bubbles + a disabled composer.
private struct ChatSkeletonScreen: View {
    let listing: Listing
    var onBack: () -> Void

    @State private var pulse = false

    private var ownerName: String { listing.ownerName ?? "Propriétaire" }
    private var ownerInitial: String { String(ownerName.prefix(1)).uppercased() }

    var body: some View {
        VStack(spacing: 0) {
            header
            listingPill.padding(.horizontal, 16).padding(.top, 12)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    skeletonBubble(width: 240, fromMe: false, delay: 0)
                    skeletonBubble(width: 160, fromMe: true,  delay: 0.15)
                    skeletonBubble(width: 200, fromMe: false, delay: 0.30)
                    HStack {
                        loadingChip
                        Spacer()
                    }
                    .padding(.top, 8)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
            }

            composerSkeleton
        }
        .background(Color(hex: 0xF4F5F8))
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    // MARK: Header (mirrors ChatThreadView.header structure)

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .frame(width: 42, height: 42)
                    .background(RoundedRectangle(cornerRadius: 14).fill(.white)
                        .shadow(color: Color(hex: 0x14152A).opacity(0.06), radius: 8, y: 2))
            }
            ZStack {
                Circle().fill(LinearGradient(colors: [Color.moblyPrimary, Color(hex: 0x6D2FE0)],
                                             startPoint: .top, endPoint: .bottom))
                    .frame(width: 42, height: 42)
                Text(ownerInitial).font(.moblyHeading(15)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(ownerName)
                    .font(.moblyHeading(15))
                    .foregroundStyle(Color.moblyTextPrimary)
                Text("Chargement…")
                    .font(.moblyBody(11.5))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
        .background(Color.white)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(hex: 0xECEDF1)).frame(height: 1)
        }
    }

    private var listingPill: some View {
        HStack(spacing: 12) {
            ListingCover(listing: listing)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(listing.title).font(.moblyHeading(13.5))
                    .foregroundStyle(Color.moblyTextPrimary).lineLimit(1)
                Text(listing.price + LT(listing.priceUnit))
                    .font(.moblyBody(12)).foregroundStyle(Color.moblyPrimary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color(hex: 0xC4C7D2))
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 16).fill(.white))
        .shadow(color: Color(hex: 0x14152A).opacity(0.06), radius: 8, y: 3)
    }

    private func skeletonBubble(width: CGFloat, fromMe: Bool, delay: Double) -> some View {
        HStack {
            if fromMe { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(shimmerFill)
                    .frame(width: width, height: 12)
                Capsule().fill(shimmerFill)
                    .frame(width: width * 0.7, height: 12)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(fromMe
                        ? UnevenRoundedRectangle(cornerRadii: .init(topLeading: 18, bottomLeading: 18, bottomTrailing: 5, topTrailing: 18)).fill(Color.moblyPrimary.opacity(0.15))
                        : UnevenRoundedRectangle(cornerRadii: .init(topLeading: 18, bottomLeading: 5, bottomTrailing: 18, topTrailing: 18)).fill(Color.white))
            .opacity(pulse ? 0.55 : 1)
            .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true).delay(delay), value: pulse)
            if !fromMe { Spacer(minLength: 40) }
        }
    }

    private var shimmerFill: some ShapeStyle {
        Color(hex: 0xE2E4EC)
    }

    private var loadingChip: some View {
        HStack(spacing: 6) {
            ProgressView().scaleEffect(0.7).tint(Color.moblyTextSecondary)
            Text("Ouverture de la conversation…")
                .font(.moblyBody(11.5)).foregroundStyle(Color.moblyTextSecondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(Color.white))
        .overlay(Capsule().stroke(Color(hex: 0xE2E4EC), lineWidth: 1))
    }

    private var composerSkeleton: some View {
        HStack(spacing: 9) {
            Circle().fill(Color(hex: 0xE2E4EC)).frame(width: 32, height: 32)
            Capsule().fill(Color(hex: 0xF4F5F8)).frame(height: 32)
            Circle().fill(Color.moblyPrimary.opacity(0.3)).frame(width: 32, height: 32)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(Color.white)
        .overlay(Rectangle().fill(Color(hex: 0xECEDF1)).frame(height: 1), alignment: .top)
    }
}
