import SwiftUI

/// Owner inbox of visit requests. Grouped into Nouvelles / À venir / Passées.
/// Actions per row: Confirmer, Refuser, Proposer un nouvel horaire,
/// Marquer terminée, Marquer non honorée, Ouvrir la discussion.
struct OwnerVisitsView: View {
    @StateObject private var store = VisitRequestStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var proposeFor: VisitRequestDTO?
    @State private var confirmDecline: VisitRequestDTO?
    @State private var openedThread: ChatThread?
    @State private var chatOpenFailed = false
    /// id of the visit whose action is in flight, so only that row spins.
    @State private var busyVisitId: String?
    /// id of the visit whose chat is being opened.
    @State private var openingChatFor: String?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView(showsIndicators: false) {
                if store.isLoading && store.items.isEmpty {
                    ProgressView().padding(.top, 60)
                } else if store.items.isEmpty {
                    emptyState.padding(.top, 60)
                } else {
                    LazyVStack(spacing: 22) {
                        section("Nouvelles", nouvelles, accent: Color.moblyAccent)
                        section("À venir", aVenir, accent: Color(hex: 0x1F8A5B))
                        section("Passées", passees, accent: Color(hex: 0x9A9DAC))
                    }
                    .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 40)
                }
            }
            .refreshable { await store.refresh() }
        }
        .background(Color.moblySurface)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task { await store.refresh() }
        .sheet(item: $proposeFor) { visit in
            ProposeTimeSheet(visit: visit) { newDate in
                Task {
                    await store.update(id: visit.id, scheduledAt: newDate)
                }
            }
            .presentationDetents([.height(430)])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $openedThread) { thread in
            ChatThreadView(thread: thread, onBack: { openedThread = nil })
        }
        .alert("Impossible d'ouvrir la conversation", isPresented: $chatOpenFailed) {
            Button("OK", role: .cancel) {}
        }
        .confirmationDialog(
            "Refuser cette demande ?",
            isPresented: Binding(
                get: { confirmDecline != nil },
                set: { if !$0 { confirmDecline = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Refuser", role: .destructive) {
                if let v = confirmDecline {
                    Task { await store.update(id: v.id, status: "CANCELLED") }
                }
                confirmDecline = nil
            }
            Button("Annuler", role: .cancel) { confirmDecline = nil }
        }
    }

    // MARK: - Groups

    private var nouvelles: [VisitRequestDTO] {
        store.items.filter { $0.status == "REQUESTED" && $0.scheduledAt >= .now.addingTimeInterval(-3600) }
    }
    private var aVenir: [VisitRequestDTO] {
        store.items.filter { $0.status == "CONFIRMED" && $0.scheduledAt >= .now.addingTimeInterval(-3600) }
    }
    private var passees: [VisitRequestDTO] {
        store.items.filter {
            $0.status == "COMPLETED" || $0.status == "CANCELLED" || $0.status == "NO_SHOW" ||
            $0.scheduledAt < .now.addingTimeInterval(-3600)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ rows: [VisitRequestDTO], accent: Color) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle().fill(accent).frame(width: 8, height: 8)
                    Text(LT(title)).font(.moblyHeading(15)).foregroundStyle(Color.moblyTextPrimary)
                    Text("\(rows.count)").font(.moblyBody(12, weight: .semibold))
                        .foregroundStyle(Color.moblyTextSecondary)
                    Spacer()
                }
                ForEach(rows) { visit in
                    VisitCard(
                        visit: visit,
                        busy: busyVisitId == visit.id,
                        openingChat: openingChatFor == visit.id,
                        onConfirm: {
                            act(visit, status: "CONFIRMED")
                        },
                        onDecline: { confirmDecline = visit },
                        onPropose: { proposeFor = visit },
                        onComplete: {
                            act(visit, status: "COMPLETED")
                        },
                        onNoShow: {
                            act(visit, status: "NO_SHOW")
                        },
                        onOpenChat: { openChat(for: visit) }
                    )
                }
            }
        }
    }

    private func openChat(for visit: VisitRequestDTO) {
        guard openingChatFor == nil else { return }
        openingChatFor = visit.id
        Task {
            // The peer is whoever ISN'T me. From the owner's inbox that's the
            // visitor; letting the server derive it from the listing would
            // resolve to the owner themselves and 422.
            let me = AuthStore.shared.user?.id
            let peer = (visit.ownerId == me) ? visit.visitorId : visit.ownerId
            let dto = await ChatStore.shared.openThread(listingId: visit.listingId,
                                                        otherUserId: peer)
            await MainActor.run {
                openingChatFor = nil
                guard let dto else { chatOpenFailed = true; return }
                openedThread = ChatThread.from(dto, myUserId: me)
            }
        }
    }

    /// Run a visit transition with a per-row spinner so the tap has feedback
    /// on a slow connection instead of looking like nothing happened.
    private func act(_ visit: VisitRequestDTO, status: String) {
        guard busyVisitId == nil else { return }
        busyVisitId = visit.id
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            await store.update(id: visit.id, status: status)
            await MainActor.run { busyVisitId = nil }
        }
    }

    // MARK: - Top bar

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
            }
            HStack(alignment: .lastTextBaseline) {
                Text("Demandes de visite")
                    .font(.moblyHeading(26)).foregroundStyle(Color.moblyTextPrimary)
                Spacer()
                if store.pendingCount > 0 {
                    Text("\(store.pendingCount) en attente")
                        .font(.moblyBody(12, weight: .semibold))
                        .foregroundStyle(Color.moblyAccent)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Color(hex: 0xFFF3EC)))
                }
            }
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color(hex: 0xC4C7D2))
            Text("Aucune demande pour le moment")
                .font(.moblyHeading(15)).foregroundStyle(Color.moblyTextPrimary)
            Text("Les visiteurs qui demandent à visiter vos annonces apparaîtront ici.")
                .font(.moblyBody(13)).foregroundStyle(Color.moblyTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 20)
    }
}

// MARK: - Card

private struct VisitCard: View {
    let visit: VisitRequestDTO
    /// An action on THIS row is in flight — dim the card and spin the buttons.
    var busy: Bool = false
    /// The chat for this row is being opened.
    var openingChat: Bool = false
    var onConfirm: () -> Void
    var onDecline: () -> Void
    var onPropose: () -> Void
    var onComplete: () -> Void
    var onNoShow: () -> Void
    var onOpenChat: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().padding(.horizontal, 14)
            listingRow.padding(14)
            if let note = visit.note, !note.isEmpty {
                Divider().padding(.horizontal, 14)
                noteRow(note).padding(14)
            }
            Divider().padding(.horizontal, 14)
            actionRow.padding(14)
        }
        .background(
            RoundedRectangle(cornerRadius: 20).fill(.white)
                .shadow(color: Color(hex: 0x14152A).opacity(0.06), radius: 12, y: 4)
        )
    }

    private var header: some View {
        HStack(spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(visit.visitor?.fullName ?? "Visiteur")
                        .font(.moblyHeading(16)).foregroundStyle(Color.moblyTextPrimary)
                        .lineLimit(1)
                    if visit.visitor?.verified == true {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.moblyPrimary)
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "clock").font(.system(size: 11, weight: .semibold))
                    Text(dateLabel).font(.moblyBody(12.5, weight: .semibold))
                }
                .foregroundStyle(Color.moblyTextSecondary)
            }
            Spacer(minLength: 0)
            statusChip
        }
        .padding(14)
    }

    private var avatar: some View {
        ZStack {
            Circle().fill(Color(hex: 0xEEF0FE))
                .frame(width: 46, height: 46)
            Text(initial)
                .font(.moblyHeading(17))
                .foregroundStyle(Color.moblyPrimary)
        }
    }
    private var initial: String {
        guard let name = visit.visitor?.fullName, let first = name.first else { return "?" }
        return String(first).uppercased()
    }

    private var statusChip: some View {
        Text(LT(statusLabel))
            .font(.moblyBody(10.5, weight: .bold))
            .foregroundStyle(statusFG)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Capsule().fill(statusBG))
    }
    private var statusLabel: String {
        switch visit.status {
        case "REQUESTED": return "EN ATTENTE"
        case "CONFIRMED": return "CONFIRMÉE"
        case "CANCELLED": return "REFUSÉE"
        case "COMPLETED": return "TERMINÉE"
        case "NO_SHOW":   return "NON HONORÉE"
        default:          return visit.status
        }
    }
    private var statusFG: Color {
        switch visit.status {
        case "REQUESTED": return Color(hex: 0xC24E10)
        case "CONFIRMED": return Color(hex: 0x1F8A5B)
        case "CANCELLED": return Color(hex: 0xE5484D)
        case "COMPLETED": return Color.moblyPrimary
        case "NO_SHOW":   return Color(hex: 0x9A9DAC)
        default:          return Color.moblyTextSecondary
        }
    }
    private var statusBG: Color {
        switch visit.status {
        case "REQUESTED": return Color(hex: 0xFFF3EC)
        case "CONFIRMED": return Color(hex: 0xE9F9EF)
        case "CANCELLED": return Color(hex: 0xFDEDED)
        case "COMPLETED": return Color(hex: 0xEEF0FE)
        case "NO_SHOW":   return Color(hex: 0xF1F2F6)
        default:          return Color(hex: 0xF1F2F6)
        }
    }

    private var listingRow: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(hex: 0xF1F2F6))
                .frame(width: 54, height: 54)
                .overlay {
                    if let url = visit.listing?.coverUrl, let u = URL(string: url) {
                        AsyncImage(url: u) { img in
                            img.resizable().scaledToFill()
                        } placeholder: { Color(hex: 0xE2E4EC) }
                        .frame(width: 54, height: 54).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else if let name = visit.listing?.imageName {
                        Image(name).resizable().scaledToFill()
                            .frame(width: 54, height: 54).clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(visit.listing?.title ?? "Annonce")
                    .font(.moblyHeading(14)).foregroundStyle(Color.moblyTextPrimary)
                    .lineLimit(1)
                if let l = visit.listing {
                    Text([l.neighborhood, l.city].compactMap { $0 }.joined(separator: " · "))
                        .font(.moblyBody(12)).foregroundStyle(Color.moblyTextSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func noteRow(_ note: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "quote.opening")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.moblyTextSecondary)
                .padding(.top, 2)
            Text(note)
                .font(.moblyBody(13))
                .foregroundStyle(Color.moblyTextPrimary)
            Spacer(minLength: 0)
        }
    }

    // Action row swaps by status.
    private var actionRow: some View {
        Group {
            switch visit.status {
            case "REQUESTED":
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        actionButton("Confirmer", "checkmark", fg: 0x1F8A5B, bg: 0xE9F9EF, loading: busy, action: onConfirm)
                        actionButton("Refuser", "xmark", fg: 0xE5484D, bg: 0xFDEDED, action: onDecline)
                    }
                    HStack(spacing: 10) {
                        actionButton("Proposer un autre horaire", "calendar", fg: 0x3A4FF0, bg: 0xEEF0FE, action: onPropose)
                        actionButton("Discuter", "bubble.left", fg: 0x666F80, bg: 0xF1F2F6, loading: openingChat, action: onOpenChat)
                    }
                }
            case "CONFIRMED":
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        actionButton("Terminée", "checkmark.seal.fill", fg: 0x3A4FF0, bg: 0xEEF0FE, action: onComplete)
                        actionButton("Non honorée", "person.slash", fg: 0x9A9DAC, bg: 0xF1F2F6, action: onNoShow)
                    }
                    HStack(spacing: 10) {
                        actionButton("Reprogrammer", "calendar", fg: 0x666F80, bg: 0xF1F2F6, action: onPropose)
                        actionButton("Discuter", "bubble.left", fg: 0x666F80, bg: 0xF1F2F6, loading: openingChat, action: onOpenChat)
                    }
                }
            default:
                HStack(spacing: 10) {
                    actionButton("Discuter", "bubble.left", fg: 0x666F80, bg: 0xF1F2F6, loading: openingChat, action: onOpenChat)
                }
            }
        }
    }

    /// `loading` swaps the icon for a spinner in place, so the button keeps
    /// its width and the row doesn't reflow mid-tap.
    private func actionButton(_ title: String, _ icon: String, fg: UInt32, bg: UInt32,
                              loading: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            HStack(spacing: 6) {
                if loading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color(hex: fg))
                } else {
                    Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                }
                Text(LT(title)).font(.moblyHeading(13.5))
            }
            .foregroundStyle(Color(hex: fg))
            .frame(maxWidth: .infinity).frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: bg)))
        }
        .buttonStyle(.plain)
        .disabled(loading || busy)
        .animation(.easeInOut(duration: 0.15), value: loading)
    }

    // MARK: Date formatting

    private var dateLabel: String {
        let cal = Calendar.current
        let df = DateFormatter()
        df.locale = Locale(identifier: "fr_FR")
        if cal.isDateInToday(visit.scheduledAt) {
            df.dateFormat = "'Aujourd''hui' HH:mm"
        } else if cal.isDateInTomorrow(visit.scheduledAt) {
            df.dateFormat = "'Demain' HH:mm"
        } else if cal.isDateInYesterday(visit.scheduledAt) {
            df.dateFormat = "'Hier' HH:mm"
        } else {
            df.dateFormat = "EEE d MMM · HH:mm"
        }
        return df.string(from: visit.scheduledAt)
    }
}

// MARK: - Propose time sheet

private struct ProposeTimeSheet: View {
    let visit: VisitRequestDTO
    var onSubmit: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date

    init(visit: VisitRequestDTO, onSubmit: @escaping (Date) -> Void) {
        self.visit = visit
        self.onSubmit = onSubmit
        // Default = one hour after the requested time.
        _date = State(initialValue: visit.scheduledAt.addingTimeInterval(3600))
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Proposer un autre horaire")
                .font(.moblyHeading(18)).foregroundStyle(Color.moblyTextPrimary)
                .padding(.top, 12)
            Text("La demande repassera « en attente » côté visiteur.")
                .font(.moblyBody(13)).foregroundStyle(Color.moblyTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)

            DatePicker("", selection: $date, in: Date.now...,
                       displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.wheel)
                .labelsHidden()
                .environment(\.locale, Locale(identifier: "fr_FR"))
                .padding(.horizontal, 20)

            Button {
                onSubmit(date)
                dismiss()
            } label: {
                Text("Envoyer la proposition")
                    .font(.moblyHeading(15)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(RoundedRectangle(cornerRadius: 15).fill(Color.moblyPrimary))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            Spacer(minLength: 0)
        }
        .padding(.bottom, 20)
        .background(Color.moblySurface)
    }
}
