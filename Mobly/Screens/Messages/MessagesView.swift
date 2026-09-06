import SwiftUI

struct MessagesView: View {
    @ObservedObject private var chat = ChatStore.shared
    @ObservedObject private var auth = AuthStore.shared
    @ObservedObject private var prefs = ThreadPrefs.shared
    @ObservedObject private var push = PushService.shared
    @State private var openThread: ChatThread?
    @State private var searchText = ""
    @State private var showArchived = false
    @State private var confirmDelete: ChatThread?

    /// Rows come from the server, mapped per render — there is no local copy
    /// to drift out of sync with what the socket delivers.
    ///
    /// Locally-deleted threads are hidden; pinned threads float to the top;
    /// archived threads only show when the user reveals the archive view;
    /// a manually-unread flag from the row's long-press menu forces
    /// `unread >= 1` even when the server thinks the thread is read.
    private var threads: [ChatThread] {
        chat.threads.compactMap { dto -> ChatThread? in
            if prefs.deleted.contains(dto.id) { return nil }
            let f = prefs.flags(for: dto.id)
            if f.archived != showArchived { return nil }
            var t = ChatThread.from(dto, myUserId: auth.user?.id)
            if f.manuallyUnread && t.unread == 0 { t.unread = 1 }
            return t
        }
        .sorted { a, b in
            let pa = prefs.flags(for: a.id).pinned
            let pb = prefs.flags(for: b.id).pinned
            if pa != pb { return pa && !pb }
            return false // keep server order (already newest-first)
        }
    }

    private var filtered: [ChatThread] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return threads }
        return threads.filter {
            $0.name.lowercased().contains(q) || $0.listing.lowercased().contains(q)
        }
    }

    /// Count of archived threads currently in the inbox — drives the pinned
    /// "Archivés" row at the top when we're on the main inbox.
    private var archivedCount: Int {
        chat.threads.filter { !prefs.deleted.contains($0.id) && prefs.flags(for: $0.id).archived }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            List {
                // Pinned archive row — WhatsApp-style entry to the archived
                // inbox. Only shown on the main view when there's ≥1 archived
                // thread; tap flips `showArchived` to reveal the archive.
                if !showArchived, archivedCount > 0 {
                    Button { withAnimation { showArchived = true } } label: {
                        archiveRow(count: archivedCount)
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
                }
                // Header when we're viewing the archive so the user can get back.
                if showArchived {
                    Button { withAnimation { showArchived = false } } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Retour aux discussions")
                                .font(.moblyBody(13, weight: .semibold))
                            Spacer()
                        }
                        .foregroundStyle(Color.moblyPrimary)
                        .padding(.vertical, 12).padding(.horizontal, 14)
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 0, trailing: 14))
                }

                if chat.isLoadingThreads && filtered.isEmpty {
                    ThreadListSkeleton()
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                } else if filtered.isEmpty {
                    emptyState
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
                } else {
                    ForEach(filtered) { thread in
                        Button {
                            prefs.clearManualUnread(thread.id)
                            chat.markRead(threadId: thread.id)
                            // Kick the fetch off the moment the row is
                            // tapped, not when the cover finishes its present
                            // animation — the round-trip overlaps the
                            // transition so the thread often opens with
                            // messages already there.
                            Task { await chat.loadMessages(threadId: thread.id) }
                            openThread = thread
                        } label: {
                            ChatRow(thread: thread, prefs: prefs.flags(for: thread.id))
                        }
                        .buttonStyle(.plain)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14))
                        .contextMenu { menu(for: thread) }
                        // Swipe-LEFT (trailing) — WhatsApp-style: More +
                        // Archive. Full-swipe left archives the row (or
                        // unarchives when we're already in the archive).
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button {
                                withAnimation { prefs.toggleArchive(thread.id) }
                            } label: {
                                Label(prefs.flags(for: thread.id).archived ? "Désarchiver" : "Archiver",
                                      systemImage: prefs.flags(for: thread.id).archived ? "tray.and.arrow.up" : "archivebox.fill")
                            }
                            .tint(Color(hex: 0x5B6CF5))

                            Button {
                                confirmDelete = thread
                            } label: {
                                Label("Supprimer", systemImage: "trash")
                            }
                            .tint(Color(hex: 0xE5484D))

                            Menu {
                                menu(for: thread)
                            } label: {
                                Label("Plus", systemImage: "ellipsis.circle")
                            }
                            .tint(Color(hex: 0x6B6F80))
                        }
                        // Swipe-RIGHT (leading) — Pin + Unread. Full-swipe
                        // right marks the row unread (WhatsApp behaviour).
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                if thread.unread > 0 || prefs.flags(for: thread.id).manuallyUnread {
                                    prefs.clearManualUnread(thread.id)
                                    chat.markRead(threadId: thread.id)
                                } else {
                                    prefs.markUnread(thread.id)
                                }
                            } label: {
                                Label(thread.unread > 0 || prefs.flags(for: thread.id).manuallyUnread
                                      ? "Marquer lu" : "Marquer non lu",
                                      systemImage: thread.unread > 0 || prefs.flags(for: thread.id).manuallyUnread
                                      ? "envelope.open.fill" : "envelope.badge.fill")
                            }
                            .tint(Color(hex: 0x1F8A5B))

                            Button {
                                prefs.togglePin(thread.id)
                            } label: {
                                Label(prefs.flags(for: thread.id).pinned ? "Détacher" : "Épingler",
                                      systemImage: prefs.flags(for: thread.id).pinned ? "pin.slash.fill" : "pin.fill")
                            }
                            .tint(Color(hex: 0xFF6B35))
                        }
                    }
                }

                Color.clear.frame(height: 100)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.white)
        }
        .background(Color.white)
        .refreshable { await chat.loadThreads() }
        .task {
            // Debug: auto-open the first thread whose last message is a visit
            // system message — for screenshotting the visit card. Runs even
            // when auth isn't ready yet — wait for bootstrap then load.
            let wantsVisit = ProcessInfo.processInfo.environment["OPEN_VISIT_THREAD"] == "1"
            if wantsVisit {
                for _ in 0..<20 {
                    if auth.isSignedIn { break }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            guard auth.isSignedIn else { return }
            await chat.loadThreads()
            if wantsVisit {
                try? await Task.sleep(nanoseconds: 400_000_000)
                let match = chat.threads.first(where: { $0.lastMessage?.visitAction == "REQUESTED" })
                    ?? chat.threads.first(where: { $0.lastMessage?.visitAction != nil })
                    ?? chat.threads.first
                if let dto = match {
                    openThread = ChatThread.from(dto, myUserId: auth.user?.id)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NetworkMonitor.didReconnect)) { _ in
            guard auth.isSignedIn else { return }
            Task { await chat.loadThreads() }
            chat.reconnectSocket()
        }
        .fullScreenCover(item: $openThread) { thread in
            ChatThreadView(thread: thread, onBack: { openThread = nil })
        }
        .onChange(of: push.pendingThreadId) { _, threadId in
            guard let threadId else { return }
            push.pendingThreadId = nil
            if let dto = chat.threads.first(where: { $0.id == threadId }) {
                chat.markRead(threadId: threadId)
                Task { await chat.loadMessages(threadId: threadId) }
                openThread = ChatThread.from(dto, myUserId: auth.user?.id)
            } else {
                Task {
                    await chat.loadThreads()
                    if let dto = chat.threads.first(where: { $0.id == threadId }) {
                        chat.markRead(threadId: threadId)
                        await chat.loadMessages(threadId: threadId)
                        openThread = ChatThread.from(dto, myUserId: auth.user?.id)
                    }
                }
            }
        }
        .confirmationDialog(
            "Supprimer cette conversation ?",
            isPresented: Binding(
                get: { confirmDelete != nil },
                set: { if !$0 { confirmDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: confirmDelete
        ) { t in
            Button("Supprimer", role: .destructive) { prefs.delete(t.id); confirmDelete = nil }
            Button("Annuler", role: .cancel) { confirmDelete = nil }
        } message: { _ in
            Text("Elle sera masquée de votre boîte de réception. Les messages restent sur le serveur.")
        }
    }

    /// Pinned row at the top of the inbox that opens the archive when there
    /// are ≥1 archived conversations, WhatsApp-style.
    private func archiveRow(count: Int) -> some View {
        HStack(spacing: 13) {
            ZStack {
                Circle().fill(Color(hex: 0xEEF0FE)).frame(width: 44, height: 44)
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.moblyPrimary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Archivés")
                    .font(.moblyHeading(14.5))
                    .foregroundStyle(Color.moblyTextPrimary)
                Text("\(count) conversation\(count == 1 ? "" : "s")")
                    .font(.moblyBody(11.5))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(hex: 0xC4C7D2))
        }
        .padding(.vertical, 8)
    }

    /// WhatsApp-style long-press menu on a conversation row.
    @ViewBuilder
    private func menu(for thread: ChatThread) -> some View {
        let f = prefs.flags(for: thread.id)
        // Read / unread — reads the same channel as tapping the row, plus a
        // local override for "mark as unread" (the server has no dedicated
        // endpoint for that yet).
        if thread.unread > 0 || f.manuallyUnread {
            Button {
                prefs.clearManualUnread(thread.id)
                chat.markRead(threadId: thread.id)
            } label: { Label("Marquer comme lu", systemImage: "envelope.open") }
        } else {
            Button {
                prefs.markUnread(thread.id)
            } label: { Label("Marquer comme non lu", systemImage: "envelope.badge") }
        }

        Button {
            prefs.togglePin(thread.id)
        } label: {
            Label(f.pinned ? "Détacher" : "Épingler",
                  systemImage: f.pinned ? "pin.slash" : "pin")
        }

        Button {
            prefs.toggleMute(thread.id)
        } label: {
            Label(f.muted ? "Rétablir les notifications" : "Mettre en sourdine",
                  systemImage: f.muted ? "bell" : "bell.slash")
        }

        Button {
            prefs.toggleArchive(thread.id)
        } label: {
            Label(f.archived ? "Désarchiver" : "Archiver",
                  systemImage: f.archived ? "tray.and.arrow.up" : "archivebox")
        }

        Divider()

        Button(role: .destructive) {
            confirmDelete = thread
        } label: { Label("Supprimer", systemImage: "trash") }
    }

    /// Two distinct empty states: signed-out users are told to sign in, signed-in
    /// users are told how a conversation starts. "Aucune conversation" alone
    /// would read as a bug to someone who simply isn't logged in.
    private var emptyState: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(Color(hex: 0xEEF0FE)).frame(width: 78, height: 78)
                Image(systemName: auth.isSignedIn ? "bubble.left.and.bubble.right" : "person.crop.circle")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Color.moblyPrimary)
            }
            .padding(.top, 60)

            Text(auth.isSignedIn ? "Aucune conversation" : "Connectez-vous")
                .font(.moblyHeading(18))
                .foregroundStyle(Color.moblyTextPrimary)

            Text(auth.isSignedIn
                 ? "Contactez un propriétaire depuis une annonce pour démarrer une conversation."
                 : "Connectez-vous pour retrouver vos messages.")
                .font(.moblyBody(13.5))
                .foregroundStyle(Color(hex: 0x9A9DAC))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 40)

            if chat.isOffline {
                Label("Hors ligne", systemImage: "wifi.slash")
                    .font(.moblyBody(12, weight: .medium))
                    .foregroundStyle(Color(hex: 0xFF6B35))
                    .padding(.top, 4)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        VStack(spacing: 16) {
            HStack {
                Text(L("Discuter"))
                    .font(.moblyHeading(26))
                    .foregroundStyle(Color.moblyTextPrimary)
                Spacer()
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .frame(width: 42, height: 42)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0xF4F5F8)))
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                TextField("Rechercher une conversation…", text: $searchText)
                    .font(.moblyBody(13.5))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 15)
            .frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0xF4F5F8)))
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }
}

struct ChatRow: View {
    let thread: ChatThread
    var prefs: ThreadPrefs.Flags = ThreadPrefs.Flags()

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    Circle().fill(thread.color)
                    Text(thread.initial)
                        .font(.moblyHeading(19)).foregroundStyle(.white)
                }
                .frame(width: 54, height: 54)
                if thread.online {
                    Circle().fill(Color(hex: 0x25D366))
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(.white, lineWidth: 2.5))
                }
            }

            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text(thread.name)
                        .font(.moblyHeading(15))
                        .foregroundStyle(Color.moblyTextPrimary)
                        .lineLimit(1)
                    if thread.verified {
                        ZStack {
                            Circle().fill(Color(hex: 0xB8CCFF))
                            Image(systemName: "checkmark")
                                .font(.system(size: 7, weight: .heavy))
                                .foregroundStyle(Color.moblyPrimary)
                        }
                        .frame(width: 16, height: 16)
                    }
                    if prefs.muted {
                        Image(systemName: "bell.slash.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color(hex: 0x9A9DAC))
                    }
                    if prefs.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color(hex: 0x9A9DAC))
                            .rotationEffect(.degrees(45))
                    }
                    Spacer()
                    Text(thread.time)
                        .font(.moblyBody(11))
                        .foregroundStyle(Color(hex: 0x9A9DAC))
                }

                Text(thread.listing)
                    .font(.moblyBody(11.5))
                    .foregroundStyle(Color.moblyPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)

                HStack(spacing: 8) {
                    // "Vous : …" when the last message is ours, so the row says
                    // at a glance whether the other person has replied yet.
                    Text(thread.fromMe ? "Vous : \(thread.preview)" : thread.preview)
                        .font(.moblyBody(12.5, weight: thread.unread > 0 ? .semibold : .regular))
                        .foregroundStyle(thread.unread > 0 ? Color.moblyTextPrimary : Color(hex: 0x9A9DAC))
                        .lineLimit(1)
                    Spacer()
                    if thread.unread > 0 {
                        Text("\(thread.unread)")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(minWidth: 19, minHeight: 19)
                            .padding(.horizontal, 5)
                            .background(Capsule().fill(Color(hex: 0xE5484D)))
                    }
                }
                .padding(.top, 3)
                .padding(.bottom, 14)
                .overlay(Rectangle().fill(Color(hex: 0xF1F2F6)).frame(height: 1), alignment: .bottom)
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

#Preview {
    MessagesView()
}
