import SwiftUI

/// Bridging view shown the instant a user taps "Message l'hôte" on a listing.
///
/// If a cached thread for this listing already exists (from a prior session or
/// disk cache), we show it immediately while `POST /threads` refreshes in the
/// background. Otherwise we still open a real chat shell immediately from the
/// listing data, then swap in the server thread id as soon as InsForge answers.
struct ChatOpeningView: View {
    let listing: Listing
    var onBack: () -> Void = {}

    @ObservedObject private var chat = ChatStore.shared
    @ObservedObject private var auth = AuthStore.shared
    @State private var resolvedThread: ChatThread?
    @State private var openFailed = false
    @State private var openErrorMessage = ""

    private var cachedThread: ChatThread? {
        guard let dto = chat.threads.first(where: { $0.listing?.id == listing.id }) else { return nil }
        return ChatThread.from(dto, myUserId: auth.user?.id)
    }

    var body: some View {
        Group {
            if let t = resolvedThread ?? cachedThread {
                ChatThreadView(thread: t, onBack: onBack)
                    .transition(.opacity)
            } else {
                ChatThreadView(thread: .pending(for: listing), onBack: onBack)
                    .transition(.opacity)
            }
        }
        .animation(Motion.instant, value: resolvedThread?.id)
        .swipeToDismiss(onDismiss: onBack)
        .task { await open() }
        .alert("Impossible d'ouvrir la conversation", isPresented: $openFailed) {
            Button("Réessayer") { Task { await open() } }
            Button("Annuler", role: .cancel) { onBack() }
        } message: {
            Text(openErrorMessage)
        }
    }

    private func open() async {
        guard auth.isSignedIn else {
            openErrorMessage = "Votre session a expiré. Reconnectez-vous pour envoyer un message."
            openFailed = true
            return
        }
        do {
            let dto = try await chat.openThreadOrThrow(listingId: listing.id)
            guard !Task.isCancelled else { return }
            resolvedThread = ChatThread.from(dto, myUserId: auth.user?.id)
        } catch let error as MoblyAPI.APIError {
            guard !Task.isCancelled, !error.isCancelled else { return }
            // If we're already showing cached messages, swallow the error
            // silently — the user can still read old messages and type.
            if cachedThread != nil { return }
            openErrorMessage = error.message
            openFailed = true
            #if DEBUG
            MoblyNetDebug.record("openThread status=\(error.status) code=\(error.code)")
            #endif
        } catch {
            guard !Task.isCancelled else { return }
            if cachedThread != nil { return }
            openErrorMessage = "La conversation n'a pas pu être chargée. Réessayez dans un instant."
            openFailed = true
            #if DEBUG
            MoblyNetDebug.record("openThread decoding/transport error: \(error)")
            #endif
        }
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
            UserAvatar(name: ownerName, userId: listing.ownerId,
                       avatarUrl: listing.ownerAvatarUrl,
                       avatarColor: listing.ownerAvatarColor, size: 42)
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
