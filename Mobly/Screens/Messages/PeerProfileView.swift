import SwiftUI

/// Profile of the other party in a conversation — the WhatsApp-style contact
/// sheet you get when tapping the chat header. Shows their name, avatar, when
/// they joined, verification, listings they've published, and utility actions
/// (call, video, mute, block, report). Server details load on appear from
/// `MoblyAPI.user(id:)`; while the request is in flight the sheet renders
/// what the chat header already knows.
struct PeerProfileView: View {
    let thread: ChatThread
    var onOpenListing: (Listing) -> Void = { _ in }
    var onCall: () -> Void = {}
    var onVideo: () -> Void = {}
    var onClose: () -> Void = {}

    @ObservedObject private var listingStore = ListingStore.shared
    @ObservedObject private var prefs = ThreadPrefs.shared
    @ObservedObject private var blocked = BlockedUsers.shared

    @State private var loaded: MoblyAPI.PublicUserDTO?
    @State private var loading = true
    @State private var reportDraft = ""
    @State private var showReport = false
    @State private var confirmBlock = false

    private var peerId: String? { thread.peerId }
    private var peerName: String { loaded?.fullName ?? thread.name }
    private var peerCity: String? { loaded?.city }
    private var peerVerified: Bool { loaded?.verified ?? thread.verified }
    private var flags: ThreadPrefs.Flags { prefs.flags(for: thread.id) }
    private var isBlocked: Bool { peerId.map { blocked.isBlocked($0) } ?? false }

    private var peerListings: [Listing] {
        guard let id = peerId else { return [] }
        return listingStore.listings.filter { l in
            // The public listings feed doesn't expose ownerId directly on the
            // Swift `Listing`, so fall back to the thread's listing when it
            // matches, and to any listing whose ownerName equals the peer.
            if l.title == thread.listingTitle { return true }
            if let name = loaded?.fullName, l.ownerName == name { return true }
            _ = id
            return false
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    hero
                    infoCard
                    actionRow
                    if !peerListings.isEmpty { listingsSection }
                    reportBlockRow
                    Spacer(minLength: 30)
                }
                .padding(.top, 8)
            }
            .background(Color(hex: 0xF7F8FA).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Fermer") { onClose() }
                }
                ToolbarItem(placement: .principal) {
                    Text("Profil").font(.moblyHeading(15))
                }
            }
        }
        .task { await load() }
        .confirmationDialog(
            isBlocked ? "Débloquer \(peerName) ?" : "Bloquer \(peerName) ?",
            isPresented: $confirmBlock, titleVisibility: .visible
        ) {
            Button(isBlocked ? "Débloquer" : "Bloquer",
                   role: isBlocked ? .none : .destructive) {
                guard let id = peerId else { return }
                isBlocked ? blocked.unblock(id) : blocked.block(id)
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text(isBlocked
                 ? "Vous recevrez à nouveau ses messages."
                 : "Vous ne recevrez plus ses messages. Vous pouvez le débloquer à tout moment.")
        }
        .sheet(isPresented: $showReport) { reportSheet }
    }

    // MARK: Header

    private var hero: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(thread.color)
                Text(thread.initial)
                    .font(.moblyHeading(44)).foregroundStyle(.white)
            }
            .frame(width: 108, height: 108)
            .overlay(alignment: .bottomTrailing) {
                if peerVerified {
                    ZStack {
                        Circle().fill(Color.moblyPrimary)
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 26, height: 26)
                    .overlay(Circle().stroke(Color(hex: 0xF7F8FA), lineWidth: 3))
                }
            }
            .shadow(color: thread.color.opacity(0.35), radius: 12, y: 6)

            Text(peerName)
                .font(.moblyHeading(22))
                .foregroundStyle(Color.moblyTextPrimary)

            if let city = peerCity {
                Label(city, systemImage: "mappin.and.ellipse")
                    .font(.moblyBody(12.5))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
            }
        }
    }

    // MARK: Info card

    private var infoCard: some View {
        VStack(spacing: 0) {
            infoRow(icon: "person.crop.circle.badge.checkmark",
                    label: "Statut",
                    value: peerVerified ? "Vérifié" : "Non vérifié",
                    tint: peerVerified ? Color(hex: 0x1F8A5B) : Color(hex: 0x9A9DAC))
            divider
            infoRow(icon: "calendar",
                    label: "Membre depuis",
                    value: memberSince,
                    tint: Color.moblyPrimary)
            if loaded?.isOwner == true {
                divider
                infoRow(icon: "house.fill",
                        label: "Annonces publiées",
                        value: "\(loaded?.listingsCount ?? peerListings.count)",
                        tint: Color(hex: 0xFF6B35))
            }
            if let avg = loaded?.avgRating, avg > 0 {
                divider
                infoRow(icon: "star.fill",
                        label: "Note moyenne",
                        value: String(format: "%.1f (%d avis)", avg, loaded?.totalReviews ?? 0),
                        tint: Color(hex: 0xF5B301))
            }
        }
        .background(RoundedRectangle(cornerRadius: 18).fill(.white))
        .padding(.horizontal, 18)
    }

    private var divider: some View {
        Rectangle().fill(Color(hex: 0xF1F2F6)).frame(height: 1).padding(.leading, 62)
    }

    private func infoRow(icon: String, label: String, value: String, tint: Color) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(tint.opacity(0.15))
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(LT(label))
                    .font(.moblyBody(11.5))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                Text(LT(value))
                    .font(.moblyBody(14, weight: .semibold))
                    .foregroundStyle(Color.moblyTextPrimary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var memberSince: String {
        guard let created = loaded?.createdAt else { return loading ? "Chargement…" : "—" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "MMMM yyyy"
        return f.string(from: created).capitalized
    }

    // MARK: Actions

    private var actionRow: some View {
        HStack(spacing: 12) {
            actionButton("phone.fill", "Appeler", Color.moblyPrimary) { onCall() }
            actionButton("video.fill", "Vidéo", Color.moblyPrimary) { onVideo() }
            actionButton(flags.muted ? "bell.fill" : "bell.slash.fill",
                         flags.muted ? "Rétablir" : "Sourdine",
                         Color(hex: 0x8B5CF6)) {
                prefs.toggleMute(thread.id)
            }
        }
        .padding(.horizontal, 18)
    }

    private func actionButton(_ icon: String, _ label: String, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tint)
                Text(LT(label))
                    .font(.moblyBody(11.5, weight: .semibold))
                    .foregroundStyle(Color.moblyTextPrimary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background(RoundedRectangle(cornerRadius: 14).fill(.white))
        }
        .buttonStyle(.plain)
    }

    // MARK: Listings

    private var listingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Annonces de \(peerName.split(separator: " ").first.map(String.init) ?? peerName)")
                    .font(.moblyHeading(15))
                    .foregroundStyle(Color.moblyTextPrimary)
                Spacer()
                Text("\(peerListings.count)")
                    .font(.moblyBody(11.5, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
            }
            .padding(.horizontal, 18)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(peerListings) { l in
                        Button { onOpenListing(l) } label: {
                            PeerListingCard(listing: l)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
            }
        }
    }

    // MARK: Report + block

    private var reportBlockRow: some View {
        VStack(spacing: 0) {
            Button {
                showReport = true
            } label: {
                dangerRow(icon: "flag.fill", label: "Signaler", tint: Color(hex: 0xE5484D))
            }
            divider
            Button {
                confirmBlock = true
            } label: {
                dangerRow(icon: isBlocked ? "hand.raised.slash.fill" : "hand.raised.fill",
                          label: isBlocked ? "Débloquer" : "Bloquer",
                          tint: Color(hex: 0xE5484D))
            }
        }
        .background(RoundedRectangle(cornerRadius: 18).fill(.white))
        .padding(.horizontal, 18)
        .padding(.top, 10)
    }

    private func dangerRow(icon: String, label: String, tint: Color) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(tint.opacity(0.15))
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 36, height: 36)
            Text(LT(label))
                .font(.moblyBody(14, weight: .semibold))
                .foregroundStyle(tint)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    private var reportSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("Signaler \(peerName)")
                    .font(.moblyHeading(20))
                    .padding(.top, 8)
                Text("Décrivez le problème. L'équipe Mobly examinera ce signalement.")
                    .font(.moblyBody(13))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                TextEditor(text: $reportDraft)
                    .font(.moblyBody(13.5))
                    .padding(10)
                    .frame(minHeight: 180)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0xF4F5F8)))
                Spacer()
                Button {
                    SessionTracker.shared.log("chat.report_user", [
                        "peerId": peerId ?? "unknown",
                        "reason": reportDraft
                    ])
                    reportDraft = ""
                    showReport = false
                } label: {
                    Text("Envoyer le signalement")
                        .font(.moblyHeading(15))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .background(RoundedRectangle(cornerRadius: 14)
                            .fill(reportDraft.trimmingCharacters(in: .whitespaces).isEmpty
                                  ? Color(hex: 0xE5484D).opacity(0.5) : Color(hex: 0xE5484D)))
                }
                .disabled(reportDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(20)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Annuler") { showReport = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Load

    private func load() async {
        guard let id = peerId else { loading = false; return }
        do {
            let u = try await MoblyAPI.shared.user(id: id)
            await MainActor.run { self.loaded = u; self.loading = false }
        } catch {
            await MainActor.run { self.loading = false }
        }
    }
}

private struct PeerListingCard: View {
    let listing: Listing
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ListingCover(listing: listing)
                .frame(width: 160, height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(listing.title)
                .font(.moblyBody(13, weight: .semibold))
                .foregroundStyle(Color.moblyTextPrimary)
                .lineLimit(1)
            HStack(spacing: 3) {
                Text(listing.price)
                    .font(.moblyHeading(12.5))
                    .foregroundStyle(Color.moblyPrimary)
                Text(LT(listing.priceUnit))
                    .font(.moblyBody(10))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
            }
        }
        .frame(width: 160)
    }
}
