import SwiftUI

/// Where both sides of a visit go to see where it stands.
///
/// The Messages header's top-right slot used to hold a decorative
/// `square.and.pencil` glyph that wasn't even a button — it did nothing at all.
/// Visits were only visible to owners, buried in the owner dashboard, and a
/// visitor who asked for a viewing had no screen anywhere that told them
/// whether it had been accepted.
///
/// Owners land on "Reçues" and can accept or decline in place; visitors get
/// "Mes demandes" with the current status of each. Someone who is both (most
/// owners rent elsewhere too) gets both tabs.
struct VisitsHubView: View {
    var onClose: () -> Void = {}
    /// Fallback when no conversation exists for the space yet.
    var onOpenListing: (String) -> Void = { _ in }

    @ObservedObject private var store = VisitRequestStore.shared
    @ObservedObject private var session = Session.shared

    @State private var tab: Tab = .mine
    @State private var busyId: String?

    enum Tab { case received, mine }

    private var isOwner: Bool { session.isOwner }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isOwner { picker }

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 12) {
                    let list = (tab == .received && isOwner) ? store.items : store.myRequests
                    if list.isEmpty {
                        emptyState
                    } else {
                        ForEach(list) { visit in
                            VisitCard(
                                visit: visit,
                                showActions: tab == .received && isOwner
                                    && visit.status == "REQUESTED",
                                busy: busyId == visit.id,
                                onAccept: { act(visit, "CONFIRMED") },
                                onDecline: { act(visit, "CANCELLED") },
                                onOpen: { open(visit) }
                            )
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 40)
                .animation(Motion.content, value: store.items.count)
                .animation(Motion.content, value: store.myRequests.count)
            }
        }
        .background(Color.moblySurface)
        .task {
            tab = isOwner ? .received : .mine
            await store.refreshMine(silent: !store.myRequests.isEmpty)
            if isOwner { await store.refresh(silent: !store.items.isEmpty) }
        }
        .refreshable {
            await store.refreshMine()
            if isOwner { await store.refresh() }
        }
    }

    /// Tapping a visit goes to where it happened: the conversation it was
    /// arranged in, or failing that the space itself.
    private func open(_ visit: VisitRequestDTO) {
        if let thread = ChatStore.shared.threads.first(where: { $0.listing?.id == visit.listingId }) {
            onClose()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                PushService.shared.pendingThreadId = thread.id
            }
        } else {
            onOpenListing(visit.listingId)
        }
    }

    private func act(_ visit: VisitRequestDTO, _ status: String) {
        busyId = visit.id
        Task {
            await store.update(id: visit.id, status: status)
            busyId = nil
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack {
            Text(L("Visites"))
                .font(.moblyHeading(22))
                .foregroundStyle(Color.moblyTextPrimary)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color(hex: 0xF4F5F8)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 6)
    }

    private var picker: some View {
        HStack(spacing: 8) {
            tabButton("Reçues", .received, count: store.items.filter { $0.status == "REQUESTED" }.count)
            tabButton("Mes demandes", .mine, count: nil)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }

    private func tabButton(_ title: String, _ value: Tab, count: Int?) -> some View {
        Button {
            withAnimation(Motion.quick) { tab = value }
        } label: {
            HStack(spacing: 6) {
                Text(L(title))
                    .font(.moblyBody(13, weight: .semibold))
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.moblyBody(11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.moblyAccent))
                }
            }
            .foregroundStyle(tab == value ? .white : Color.moblyTextPrimary)
            .padding(.horizontal, 16)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(tab == value ? Color.moblyPrimary : .white))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(tab == value ? Color.clear : Color(hex: 0xE2E4EC), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Color(hex: 0xD5D8E2))
            Text(LT(tab == .received ? "Aucune demande reçue"
                                     : "Aucune demande de visite"))
                .font(.moblyBody(14, weight: .medium))
                .foregroundStyle(Color(hex: 0x9A9DAC))
            Text(LT(tab == .received
                    ? "Les demandes de visite sur vos espaces apparaîtront ici."
                    : "Depuis une annonce, touchez « Demander une visite »."))
                .font(.moblyBody(12.5))
                .foregroundStyle(Color(hex: 0xB0B3BF))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }
}

// MARK: - Row

private struct VisitCard: View {
    let visit: VisitRequestDTO
    let showActions: Bool
    let busy: Bool
    var onAccept: () -> Void
    var onDecline: () -> Void
    var onOpen: () -> Void

    private var whenText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "EEEE d MMMM · HH'h'mm"
        return f.string(from: visit.scheduledAt).capitalized
    }

    /// The other party: an owner reads the visitor's name, a visitor the owner's.
    private var counterparty: String {
        (showActions ? visit.visitor?.fullName : visit.owner?.fullName) ?? "Utilisateur"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(visit.listing?.title ?? "Espace")
                        .font(.moblyHeading(15))
                        .foregroundStyle(Color.moblyTextPrimary)
                        .lineLimit(1)
                    Text(whenText)
                        .font(.moblyBody(12.5))
                        .foregroundStyle(Color.moblyTextPrimary)
                    Text(counterparty)
                        .font(.moblyBody(12))
                        .foregroundStyle(Color(hex: 0x9A9DAC))
                }
                Spacer()
                statusChip
            }

            if let note = visit.note, !note.isEmpty {
                Text(note)
                    .font(.moblyBody(12.5))
                    .foregroundStyle(Color(hex: 0x4A4E5A))
                    .lineLimit(3)
            }

            if showActions {
                HStack(spacing: 10) {
                    Button(action: onDecline) {
                        Text(L("Refuser"))
                            .font(.moblyBody(13, weight: .semibold))
                            .foregroundStyle(Color(hex: 0xE5484D))
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0xFDEDED)))
                    }
                    Button(action: onAccept) {
                        Group {
                            if busy { ProgressView().tint(.white) }
                            else { Text(L("Accepter")).font(.moblyBody(13, weight: .semibold)) }
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.moblyPrimary))
                    }
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: 0xEFF0F4), lineWidth: 1))
        .contentShape(Rectangle())
        // The accept/decline buttons keep their own taps; this catches the rest
        // of the card.
        .onTapGesture { onOpen() }
    }

    private var statusChip: some View {
        Text(LT(label))
            .font(.moblyBody(10.5, weight: .bold))
            .foregroundStyle(fg)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Capsule().fill(bg))
    }
    private var label: String {
        switch visit.status {
        case "REQUESTED": return "EN ATTENTE"
        case "CONFIRMED": return "CONFIRMÉE"
        case "CANCELLED": return "REFUSÉE"
        case "COMPLETED": return "TERMINÉE"
        case "NO_SHOW":   return "NON HONORÉE"
        default:          return visit.status
        }
    }
    private var fg: Color {
        switch visit.status {
        case "REQUESTED": return Color(hex: 0xC24E10)
        case "CONFIRMED": return Color(hex: 0x1F8A5B)
        case "CANCELLED": return Color(hex: 0xE5484D)
        case "COMPLETED": return Color.moblyPrimary
        default:          return Color(hex: 0x9A9DAC)
        }
    }
    private var bg: Color {
        switch visit.status {
        case "REQUESTED": return Color(hex: 0xFFF1E8)
        case "CONFIRMED": return Color(hex: 0xE9F9EF)
        case "CANCELLED": return Color(hex: 0xFDEDED)
        case "COMPLETED": return Color(hex: 0xEEF0FE)
        default:          return Color(hex: 0xF4F5F8)
        }
    }
}
