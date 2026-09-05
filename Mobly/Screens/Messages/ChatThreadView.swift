import SwiftUI
import PhotosUI
import CoreLocation
import UIKit
import AVFoundation

struct ChatThreadView: View {
    let thread: ChatThread
    var onBack: () -> Void = {}
    var onOpenListing: () -> Void = {}

    @ObservedObject private var listingStore = ListingStore.shared
    @ObservedObject private var chat = ChatStore.shared
    @ObservedObject private var auth = AuthStore.shared
    @State private var draft = ""
    @State private var replyingTo: ChatMessage?
    @State private var activeSheet: ActiveSheet?
    enum ActiveSheet: String, Identifiable {
        case attachments, galerie, camera
        var id: String { rawValue }
    }
    @StateObject private var recorder = VoiceRecorder()

    @State private var reactionTarget: ChatMessage?
    @State private var showDetail = false
    @State private var showPeerProfile = false
    @State private var showCall = false
    @State private var callIsVideo = false
    @State private var showProposeVisit = false
    @State private var visitActionBusy = false
    @State private var isUploading = false
    @State private var uploadingPreview: UIImage?
    @State private var fullScreenImageURL: URL?
    @State private var fullScreenLocalImage: UIImage?
    /// Server-reported availability of the listing this conversation is
    /// about. `.unavailable` greys the pill and shows "Non disponible";
    /// `.missing` (server returned 404) shows "Annonce supprimée" and
    /// blocks the tap-through to detail.
    @State private var listingState: ListingState = .available
    enum ListingState { case available, unavailable, missing }
    @State private var showMicPermissionAlert = false
    @State private var showMicHint = false
    @State private var linkPreviewDismissed = false
    @StateObject private var linkPreview = LinkPreviewService()
    @FocusState private var inputFocused: Bool

    /// Messages for this thread, mapped from the store on each render so a
    /// socket delivery shows up without any local copy to keep in sync.
    private var messages: [ChatMessage] {
        let all = chat.messages[thread.id] ?? []
        // Index once instead of scanning the thread per bubble — a long
        // conversation would otherwise be quadratic.
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let me = auth.user?.id

        return all.map { dto in
            let quoted = dto.replyToId.flatMap { byId[$0] }
            let inferred = Self.inferKind(dtoKind: dto.kind, text: dto.text, hasVisit: dto.visitAction != nil)
            let voice = Self.parseVoice(dto.text)
            let loc = Self.parseLocation(dto.text)
            return ChatMessage(
                id: dto.id,
                text: dto.text,
                time: ChatThread.relativeTime(dto.createdAt),
                fromMe: dto.senderId == me,
                status: dto.read ? .read : .sent,
                kind: inferred,
                replyToText: quoted.map {
                    let qk = Self.inferKind(dtoKind: $0.kind, text: $0.text, hasVisit: $0.visitAction != nil)
                    switch qk {
                    case .voice: return "🎤 Note vocale"
                    case .image: return "📷 Photo"
                    case .location: return "📍 Position"
                    default: return $0.text
                    }
                },
                replyToMe: quoted?.senderId == me,
                voiceDuration: voice.map { $0.label },
                voiceSeconds: voice.map { $0.seconds },
                mediaUrl: dto.mediaUrl,
                locationLat: loc?.lat,
                locationLng: loc?.lng,
                day: Self.dayLabel(dto.createdAt),
                visitId: dto.visitId,
                visitAction: dto.visitAction,
                visitIsMine: dto.senderId == me
            )
        }
    }

    /// Voice + location travel as text placeholders today (no upload endpoint
    /// on the server), so infer kind from the payload when the DTO says TEXT.
    private static func inferKind(dtoKind: String, text: String, hasVisit: Bool) -> MessageKind {
        if dtoKind == "SYSTEM" && hasVisit { return .visit }
        if dtoKind == "VOICE" || text.hasPrefix("🎤 Note vocale") { return .voice }
        if dtoKind == "IMAGE" { return .image }
        if parseLocation(text) != nil { return .location }
        return .text
    }

    private static func parseVoice(_ text: String) -> (label: String, seconds: Int)? {
        guard text.hasPrefix("🎤 Note vocale") else { return nil }
        // Expected: "🎤 Note vocale (0:12)"
        guard let open = text.firstIndex(of: "("),
              let close = text.firstIndex(of: ")"),
              open < close else { return nil }
        let inside = String(text[text.index(after: open)..<close])
        let parts = inside.split(separator: ":")
        guard parts.count == 2,
              let m = Int(parts[0]), let s = Int(parts[1]) else { return nil }
        return (inside, m * 60 + s)
    }

    private static func parseLocation(_ text: String) -> (lat: Double, lng: Double)? {
        // Match "q=<lat>,<lng>" from a Google Maps URL we sent.
        guard let range = text.range(of: "q=") else { return nil }
        let tail = text[range.upperBound...]
        let end = tail.firstIndex(where: { $0 == "&" || $0 == " " }) ?? tail.endIndex
        let pair = tail[..<end].split(separator: ",")
        guard pair.count == 2,
              let lat = Double(pair[0]), let lng = Double(pair[1]) else { return nil }
        return (lat, lng)
    }

    /// True when the listing under discussion is mine — an owner answering
    /// enquiries needs different suggestions from a visitor asking them.
    private var iAmTheOwner: Bool {
        guard let me = auth.user?.id,
              let ownerId = chat.threads.first(where: { $0.id == thread.id })?
                  .listing?.ownerId
        else { return false }
        return ownerId == me
    }

    private static func dayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Aujourd'hui" }
        if cal.isDateInYesterday(date) { return "Hier" }
        let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "d MMMM"; return f.string(from: date)
    }

    /// The listing this conversation is about — resolve from data, or build
    /// one from the thread's own fields as a fallback.
    private var partnerTyping: Bool { chat.typingIn.contains(thread.id) }

    private var resolvedListing: Listing {
        if let match = listingStore.listings.first(where: { $0.title == thread.listingTitle }) {
            return match
        }
        return Listing(id: thread.id, title: thread.listingTitle,
                       location: "Douala",
                       price: thread.listingPrice.replacingOccurrences(of: " / mois", with: ""),
                       rating: "4.7", imageName: thread.listingImage, category: "Appartements")
    }

    // Voice recording is handled by the VoiceRecorder @StateObject above.

    /// The most recent visit-related system message, pinned to the top of the
    /// thread so both parties always see the current appointment state.
    private var latestVisitMessage: ChatMessage? {
        messages.reversed().first(where: { $0.kind == .visit })
    }

    private func pinnedVisitCard(_ m: ChatMessage) -> some View {
        PinnedVisitStrip(
            message: m,
            actionable: !m.visitIsMine,
            busy: visitActionBusy,
            onConfirm: { performVisitAction(m, status: "CONFIRMED") },
            onDecline: { performVisitAction(m, status: "CANCELLED") }
        )
    }

    /// Resolve the listing this conversation is about. Chat threads must
    /// survive their annonce being deleted or made indisponible — hiding the
    /// conversation would strand ongoing exchanges. Instead the pill flips
    /// to a greyed "Non disponible" / "Annonce supprimée" state so both
    /// parties see the current status but can keep talking.
    private func refreshListingState() async {
        guard let id = thread.listingId, !id.isEmpty else { return }
        do {
            let dto = try await MoblyAPI.shared.listing(id: id)
            await MainActor.run {
                listingState = dto.available ? .available : .unavailable
            }
        } catch let e as MoblyAPI.APIError where e.status == 404 {
            await MainActor.run { listingState = .missing }
        } catch {
            // Network flake — leave whatever state we were in.
        }
    }

    /// Fire a visit-card action, then refresh the thread so the new SYSTEM
    /// message shows up even when the socket is not connected (offline, or the
    /// visitor signed in via a debug token that never authed the ws).
    private func performVisitAction(_ m: ChatMessage, status: String) {
        guard let vid = m.visitId, !visitActionBusy else { return }
        visitActionBusy = true
        Task {
            _ = try? await MoblyAPI.shared.updateVisit(id: vid, status: status)
            SessionTracker.shared.log("visit.update", [
                "visitId": vid, "status": status, "source": "chat_card"
            ])
            await chat.loadMessages(threadId: thread.id)
            visitActionBusy = false
        }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                listingPill
                if let pinned = latestVisitMessage {
                    pinnedVisitCard(pinned)
                }
                messagesList
                if replyingTo != nil { replyPreview }
                // if !recorder.isRecording { quickReplies } // DEBUG: hidden to test mic tap
                composer
            }
            .background(Color(hex: 0xF4F5F8))

            // Reaction picker overlay
            if let target = reactionTarget {
                reactionOverlay(target)
            }
        }
        .swipeToDismiss(onDismiss: onBack)
        .onAppear { recorder.requestPermissionIfNeeded() }
        .task {
            chat.activeThreadId = thread.id
            ThreadPrefs.shared.clearManualUnread(thread.id)
            await chat.loadMessages(threadId: thread.id)
            chat.markRead(threadId: thread.id)
            await refreshListingState()
        }
        .onDisappear { if chat.activeThreadId == thread.id { chat.activeThreadId = nil } }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .attachments:
                attachmentSheet
                    .presentationDetents([.height(240)])
            case .galerie:
                PhotoLibraryPicker { images in
                    activeSheet = nil
                    guard !images.isEmpty else { return }
                    uploadAndSendCameraImages(images)
                }
                .ignoresSafeArea()
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .interactiveDismissDisabled()
            case .camera:
                CameraPickerView { image in
                    activeSheet = nil
                    if let image { uploadAndSendCamera(image) }
                }
                .ignoresSafeArea()
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .interactiveDismissDisabled()
            }
        }
        .sheet(isPresented: $showProposeVisit) {
            ProposeVisitFromChatSheet(thread: thread)
                .presentationDetents([.height(520)])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showDetail) {
            ListingDetailView(listing: resolvedListing, onClose: { showDetail = false })
        }
        .sheet(isPresented: $showPeerProfile) {
            PeerProfileView(
                thread: thread,
                onOpenListing: { _ in showPeerProfile = false; showDetail = true },
                onCall:  { showPeerProfile = false; callIsVideo = false; showCall = true },
                onVideo: { showPeerProfile = false; callIsVideo = true;  showCall = true },
                onClose: { showPeerProfile = false }
            )
        }
        .fullScreenCover(isPresented: $showCall) {
            CallView(thread: thread, isVideo: callIsVideo, onEnd: { showCall = false })
        }
        .fullScreenCover(isPresented: Binding(
            get: { fullScreenImageURL != nil },
            set: { if !$0 { fullScreenImageURL = nil } }
        )) {
            if let url = fullScreenImageURL {
                FullScreenImageViewer(url: url, onClose: { fullScreenImageURL = nil })
                    .ignoresSafeArea()
            }
        }
        .alert("Microphone désactivé", isPresented: $showMicPermissionAlert) {
            Button("Ouvrir Réglages") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Autorisez l'accès au microphone dans Réglages pour enregistrer des notes vocales.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .frame(width: 34, height: 38)
            }
            Button { showPeerProfile = true } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(thread.color)
                        Text(thread.initial).font(.moblyHeading(16)).foregroundStyle(.white)
                    }
                    .frame(width: 42, height: 42)

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(thread.name).font(.moblyHeading(15.5)).foregroundStyle(Color.moblyTextPrimary)
                            if thread.verified {
                                ZStack {
                                    Circle().fill(Color(hex: 0xB8CCFF))
                                    Image(systemName: "checkmark").font(.system(size: 7, weight: .heavy))
                                        .foregroundStyle(Color.moblyPrimary)
                                }.frame(width: 15, height: 15)
                            }
                        }
                        Text(partnerTyping ? "en train d'écrire…" : (thread.online ? "En ligne" : "Vu récemment"))
                            .font(.moblyBody(11.5))
                            .foregroundStyle(partnerTyping ? Color.moblyPrimary
                                             : (thread.online ? Color(hex: 0x25D366) : Color(hex: 0x9A9DAC)))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            // Voice + video call (in-app, masked numbers)
            Button { callIsVideo = false; showCall = true } label: { headerIcon("phone.fill") }
            Button { callIsVideo = true; showCall = true } label: { headerIcon("video.fill") }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(Color.white.shadow(color: Color(hex: 0x14152A).opacity(0.05), radius: 10, y: 2))
    }

    private func headerIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.moblyPrimary)
            .frame(width: 38, height: 38)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0xF4F5F8)))
    }

    // MARK: Listing pill

    private var listingPill: some View {
        Button {
            // Deleted annonces have no detail to open — don't crash into a 404.
            if listingState != .missing { showDetail = true }
        } label: {
            HStack(spacing: 11) {
                ListingCover(listing: resolvedListing, width: ImageSlot.thumb)
                    .frame(width: 50, height: 50)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(
                        // Grey the cover when the annonce is off-market so it
                        // reads at a glance without hunting for the tag.
                        listingState == .available ? nil :
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Color.white.opacity(0.55))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(thread.listingTitle)
                        .font(.moblyHeading(13.5))
                        .foregroundStyle(listingState == .missing
                                         ? Color(hex: 0x9A9DAC) : Color.moblyTextPrimary)
                        .strikethrough(listingState == .missing)
                    if listingState == .available {
                        Text(thread.listingPrice)
                            .font(.moblyHeading(13))
                            .foregroundStyle(Color.moblyPrimary)
                    } else {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(listingState == .missing
                                      ? Color(hex: 0x9A9DAC) : Color(hex: 0xE5484D))
                                .frame(width: 6, height: 6)
                            Text(listingState == .missing
                                 ? "Annonce supprimée" : "Non disponible")
                                .font(.moblyBody(11.5, weight: .semibold))
                                .foregroundStyle(listingState == .missing
                                                 ? Color(hex: 0x9A9DAC) : Color(hex: 0xE5484D))
                        }
                    }
                }
                Spacer()
                if listingState == .available {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(hex: 0xC4C7D2))
                }
            }
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 16).fill(.white))
            .shadow(color: Color(hex: 0x14152A).opacity(0.06), radius: 12, y: 3)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: Messages list

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 10) {
                    // First-load state: no cached history yet + a fetch in
                    // flight. Skeleton bubbles so the view doesn't sit
                    // visibly empty during the round-trip.
                    if messages.isEmpty && chat.loadingMessagesFor.contains(thread.id) {
                        ChatSkeleton()
                    }
                    ForEach(Array(messages.enumerated()), id: \.element.id) { i, m in
                        // Visit SYSTEM messages are already summarised by the
                        // pinned card at the top of the thread — don't render
                        // them again inline, otherwise a stale REQUESTED card
                        // would still show "Confirmer / Refuser" to the owner
                        // even after they accepted from their inbox.
                        if m.kind == .visit {
                            EmptyView()
                        } else {
                            if i == 0 || messages[i - 1].day != m.day {
                                DateSeparator(text: m.day)
                            }
                            MessageBubble(
                                message: m,
                                onReply: { replyingTo = m },
                                onReact: { reactionTarget = m },
                                onDelete: { },   // TODO: DELETE /threads/:id/messages/:mid
                                onImageTap: { url in fullScreenImageURL = url }
                            )
                            .id(m.id)
                        }
                    }

                    if let preview = uploadingPreview {
                        HStack {
                            Spacer(minLength: 50)
                            uploadPreviewBubble(preview)
                        }
                        .id("uploading")
                    }
                    if partnerTyping { TypingIndicator().id("typing") }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            .onChange(of: messages.count) { _, _ in scrollDown(proxy) }
            .onChange(of: partnerTyping) { _, _ in scrollDown(proxy) }
            .onChange(of: uploadingPreview == nil) { _, _ in scrollDown(proxy) }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private func scrollDown(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    // MARK: Upload preview bubble

    private func uploadPreviewBubble(_ image: UIImage) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 200, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    ZStack {
                        Color.black.opacity(0.35)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        VStack(spacing: 8) {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(1.2)
                            Text("Envoi…")
                                .font(.moblyBody(11, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                }

            Text(ChatThread.relativeTime(Date()))
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.trailing, 8).padding(.bottom, 6)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(
            UnevenRoundedRectangle(cornerRadii: .init(
                topLeading: 18, bottomLeading: 18,
                bottomTrailing: 5, topTrailing: 18))
                .fill(Color.moblyPrimary)
        )
    }

    // MARK: Reply preview above composer

    private var replyPreview: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.moblyPrimary).frame(width: 3, height: 26).clipShape(Capsule())
            VStack(alignment: .leading, spacing: 1) {
                Text(replyingTo?.fromMe == true ? "Vous" : thread.name)
                    .font(.moblyBody(11, weight: .semibold))
                    .foregroundStyle(Color.moblyPrimary)
                Text(replyingTo?.kind == .voice ? "🎤 Note vocale"
                     : (replyingTo?.kind == .image ? "📷 Photo" : replyingTo?.text ?? ""))
                    .font(.moblyBody(11.5))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                    .lineLimit(1)
            }
            Spacer()
            Button { replyingTo = nil } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16)).foregroundStyle(Color(hex: 0xC4C7D2))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .frame(height: 40)
        .background(Color.white)
    }

    // MARK: Quick replies

    private var quickReplies: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(iAmTheOwner ? ChatConstants.ownerReplies
                        : ChatConstants.visitorReplies, id: \.self) { q in
                    Button { draft = q; inputFocused = true } label: {
                        Text(LT(q))
                            .font(.moblyBody(12, weight: .medium))
                            .foregroundStyle(Color.moblyPrimary)
                            .padding(.horizontal, 13).padding(.vertical, 8)
                            .background(Capsule().fill(Color.moblySurfaceTint))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .background(Color.white)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 0) {
            if showMicHint {
                HStack {
                    Spacer()
                    Text("Appuyez longuement pour enregistrer")
                        .font(.moblyBody(12, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(Color(hex: 0x1A1A2E).opacity(0.85)))
                        .fixedSize()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
                .transition(.opacity)
            }
            if let preview = linkPreview.preview, !linkPreviewDismissed {
                ComposerLinkPreview(preview: preview) {
                    linkPreviewDismissed = true
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
                .transition(.opacity)
            }
            Group {
                if recorder.isRecording { recordingBar } else { normalComposer }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .animation(.easeInOut(duration: 0.2), value: showMicHint)
        .animation(.easeInOut(duration: 0.2), value: linkPreview.preview?.url)
        .background(Color.white)
        .onChange(of: draft) { _, newValue in
            linkPreviewDismissed = false
            linkPreview.detectAndFetch(in: newValue)
        }
    }

    private var normalComposer: some View {
        let canSend = !draft.trimmingCharacters(in: .whitespaces).isEmpty
        return HStack(spacing: 10) {
            Button { activeSheet = .attachments } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Color(hex: 0xF4F5F8)))
            }

            HStack(spacing: 10) {
                TextField("Message…", text: $draft, axis: .vertical)
                    .font(.moblyBody(13.5)).foregroundStyle(Color.moblyTextPrimary)
                    .focused($inputFocused).lineLimit(1...4)
            }
            .padding(.horizontal, 16).frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 22).fill(Color(hex: 0xF4F5F8)))

            Button {
                if canSend {
                    send()
                } else {
                    let permission = AVAudioSession.sharedInstance().recordPermission
                    if permission == .denied {
                        showMicPermissionAlert = true
                        return
                    }
                    if permission == .undetermined {
                        recorder.requestPermissionIfNeeded()
                        return
                    }
                    withAnimation(.easeInOut(duration: 0.2)) { showMicHint = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation(.easeInOut(duration: 0.2)) { showMicHint = false }
                    }
                }
            } label: {
                sendCircle(canSend ? "paperplane.fill" : "mic.fill")
            }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.2).onEnded { _ in
                    guard !canSend else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { showMicHint = false }
                    let permission = AVAudioSession.sharedInstance().recordPermission
                    guard permission == .granted else {
                        if permission == .denied { showMicPermissionAlert = true }
                        return
                    }
                    recorder.startRecording()
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
            )
            .id(canSend)
        }
    }

    private var recordingBar: some View {
        HStack(spacing: 12) {
            Button { recorder.cancelRecording() } label: {
                Image(systemName: "trash")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color(hex: 0xE5484D))
                    .frame(width: 42, height: 42)
            }
            HStack(spacing: 8) {
                Circle().fill(Color(hex: 0xE5484D)).frame(width: 9, height: 9)
                    .opacity(Int(recorder.duration) % 2 == 0 ? 1 : 0.3)
                LiveWaveform(samples: recorder.samples)
                    .frame(height: 28)
                Text(timeString(Int(recorder.duration)))
                    .font(.moblyBody(14, weight: .medium)).foregroundStyle(Color.moblyTextPrimary)
            }
            .padding(.horizontal, 16).frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 22).fill(Color(hex: 0xF4F5F8)))

            Button { stopRecordingAndSend() } label: { sendCircle("paperplane.fill") }
        }
    }

    private func sendCircle(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 46, height: 46)
            .background(Circle().fill(Color.moblyPrimary))
            .shadow(color: Color.moblyPrimary.opacity(0.3), radius: 10, y: 5)
    }


    // MARK: Attachment sheet

    private var attachmentSheet: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color(hex: 0xE2E4EC)).frame(width: 40, height: 5).padding(.top, 10).padding(.bottom, 18)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()),
                                GridItem(.flexible()), GridItem(.flexible())], spacing: 20) {
                attachItem("photo.fill", "Galerie", 0x3A4FF0) {
                    activeSheet = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        activeSheet = .galerie
                    }
                }
                attachItem("camera.fill", "Caméra", 0x1F8A5B) {
                    activeSheet = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        activeSheet = .camera
                    }
                }
                attachItem("doc.fill", "Document", 0xFF6B35, enabled: false) { }
                attachItem("mappin.circle.fill", "Position", 0xE5484D) { sendLocation() }
                attachItem("person.crop.circle.fill", "Contact", 0x8B5CF6, enabled: false) { }
                attachItem("chart.bar.fill", "Sondage", 0x2A6FDB, enabled: false) { }
                if iAmTheOwner {
                    attachItem("calendar.badge.plus", "Visite", 0x1F8A5B) {
                        activeSheet = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            showProposeVisit = true
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            Spacer()
        }
    }

    private func attachItem(_ icon: String, _ label: String, _ color: UInt32, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    Circle().fill(Color(hex: color)).frame(width: 56, height: 56)
                    Image(systemName: icon).font(.system(size: 22, weight: .medium)).foregroundStyle(.white)
                }
                Text(LT(label)).font(.moblyBody(11)).foregroundStyle(Color.moblyTextPrimary)
            }
            .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: Reaction overlay

    private func reactionOverlay(_ target: ChatMessage) -> some View {
        ZStack {
            Color.black.opacity(0.15).ignoresSafeArea().onTapGesture { reactionTarget = nil }
            VStack {
                HStack(spacing: 6) {
                    ForEach(ChatConstants.reactions, id: \.self) { emoji in
                        Button {
                            react(target, emoji)
                        } label: {
                            Text(emoji).font(.system(size: 28))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(Capsule().fill(.white))
                .shadow(color: .black.opacity(0.15), radius: 16, y: 8)
            }
        }
    }

    // MARK: Actions

    /// Send through the store: the bubble appears instantly, the POST confirms
    /// it, and the socket carries it to the other person.
    private func send() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let me = auth.user?.id else { return }
        // Capture before clearing — the reply target was previously dropped
        // here, so a quoted reply was sent as an ordinary message.
        let replyId = replyingTo?.id
        draft = ""
        replyingTo = nil
        linkPreview.clear()
        linkPreviewDismissed = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            await chat.send(threadId: thread.id, text: text,
                            myUserId: me, replyToId: replyId)
        }
    }

    private func sendImage() {
        activeSheet = nil
    }

    private func uploadAndSendCamera(_ image: UIImage) {
        uploadAndSendCameraImages([image])
    }

    private func uploadAndSendCameraImages(_ images: [UIImage]) {
        guard let me = auth.user?.id else { return }
        let jpegs = images.compactMap { $0.jpegData(compressionQuality: 0.8) }
        guard !jpegs.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.25)) { uploadingPreview = images.first }
        isUploading = true
        Task {
            do {
                let uploaded = try await MoblyAPI.shared.uploadOwnerPhotos(jpegs)
                for photo in uploaded {
                    await chat.send(threadId: thread.id, text: "📷 Photo",
                                    myUserId: me, kind: "IMAGE", mediaUrl: photo.url)
                }
            } catch {
                for jpeg in jpegs {
                    let localUrl = Self.saveToLocalCache(jpeg)
                    await chat.send(threadId: thread.id, text: "📷 Photo",
                                    myUserId: me, kind: "IMAGE", mediaUrl: localUrl)
                }
            }
            withAnimation(.easeInOut(duration: 0.25)) { uploadingPreview = nil }
            isUploading = false
        }
    }

    private static func saveToLocalCache(_ jpeg: Data) -> String {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chat-photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(UUID().uuidString + ".jpg")
        try? jpeg.write(to: file)
        return file.absoluteString
    }

    private func sendLocation() {
        activeSheet = nil
        guard let me = auth.user?.id else { return }
        Task {
            guard let coord = await LocationService.shared.requestOneShotCoordinate() else {
                await chat.send(threadId: thread.id,
                                text: "📍 Position indisponible (autorisation refusée)",
                                myUserId: me)
                return
            }
            let lat = String(format: "%.6f", coord.latitude)
            let lng = String(format: "%.6f", coord.longitude)
            let url = "https://www.google.com/maps?q=\(lat),\(lng)"
            await chat.send(threadId: thread.id,
                            text: "📍 Ma position: \(url)",
                            myUserId: me)
        }
    }

    private func sendVoice() {
        guard let result = recorder.stopRecording() else { return }
        guard let me = auth.user?.id else { return }
        let seconds = Int(result.duration)
        let label = timeString(seconds)
        let voiceText = "🎤 Note vocale (\(label))"
        let audioUrl = result.url
        let audioSamples = result.samples
        Task {
            await chat.send(threadId: thread.id, text: voiceText, myUserId: me)
            // Register audio under whatever id the message now has (could be
            // the optimistic local id or the server-confirmed id).
            if let newest = (chat.messages[thread.id] ?? [])
                .last(where: { $0.text == voiceText && $0.senderId == me }) {
                AudioPlayerManager.shared.registerAudio(id: newest.id, url: audioUrl, samples: audioSamples)
            }
        }
    }

    private func stopRecordingAndSend() {
        guard recorder.isRecording, recorder.duration > 0.5 else {
            recorder.cancelRecording()
            return
        }
        sendVoice()
    }

    /// Reactions are local-only for now — there is no reactions table, so
    /// persisting them would mean inventing state the server can't confirm.
    private func react(_ target: ChatMessage, _ emoji: String) {
        reactionTarget = nil
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: Helpers

    private func nowTime() -> String { "maintenant" }
    private func timeString(_ s: Int) -> String { String(format: "0:%02d", s) }
}

// Deterministic pick (Date.now/random are unavailable in some contexts; keep stable).
private extension Array {
    func randomElementDeterministic(_ seed: Int) -> Element { self[seed % count] }
}

// MARK: - Message bubble

struct MessageBubble: View {
    let message: ChatMessage
    var onReply: () -> Void = {}
    var onReact: () -> Void = {}
    var onDelete: () -> Void = {}
    var onImageTap: ((URL) -> Void)?

    @State private var dragOffset: CGFloat = 0

    var body: some View {
        HStack {
            if message.fromMe { Spacer(minLength: 50) }
            bubble
                .offset(x: dragOffset)
                .gesture(replySwipe)
                .contextMenu {
                    Button { onReply() } label: { Label("Répondre", systemImage: "arrowshape.turn.up.left") }
                    Button { onReact() } label: { Label("Réagir", systemImage: "face.smiling") }
                    if message.kind == .text {
                        Button { UIPasteboard.general.string = message.text } label: {
                            Label("Copier", systemImage: "doc.on.doc")
                        }
                    }
                    Button(role: .destructive) { onDelete() } label: {
                        Label("Supprimer", systemImage: "trash")
                    }
                }
            if !message.fromMe { Spacer(minLength: 50) }
        }
    }

    private var bubble: some View {
        VStack(alignment: message.fromMe ? .trailing : .leading, spacing: 6) {
            if let reply = message.replyToText {
                HStack(spacing: 6) {
                    Rectangle().fill(message.fromMe ? Color.white.opacity(0.8) : Color.moblyPrimary)
                        .frame(width: 3).clipShape(Capsule())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(message.replyToMe ? "Vous" : "Contact")
                            .font(.moblyBody(10.5, weight: .semibold))
                            .foregroundStyle(message.fromMe ? .white : Color.moblyPrimary)
                        Text(reply).font(.moblyBody(11))
                            .foregroundStyle(message.fromMe ? Color.white.opacity(0.85) : Color(hex: 0x6B6F80))
                            .lineLimit(1)
                    }
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(message.fromMe ? Color.white.opacity(0.15) : Color(hex: 0xF1F2F6)))
            }

            content

            HStack(spacing: 3) {
                Text(message.time)
                    .font(.system(size: 9.5))
                    .foregroundStyle(message.fromMe ? Color.white.opacity(0.7) : Color(hex: 0xB4B7C2))
                if message.fromMe { statusTicks }
            }
        }
        .padding(.horizontal, message.kind == .image ? 6 : 12)
        .padding(.vertical, message.kind == .image ? 6 : 9)
        .background(bubbleShape.fill(message.fromMe ? Color.moblyPrimary : .white))
        .shadow(color: message.fromMe ? .clear : Color(hex: 0x14152A).opacity(0.05), radius: 8, y: 2)
        .overlay(alignment: message.fromMe ? .bottomLeading : .bottomTrailing) {
            if let r = message.reaction {
                Text(r).font(.system(size: 15))
                    .padding(3).background(Circle().fill(.white).shadow(color: .black.opacity(0.1), radius: 2))
                    .offset(x: message.fromMe ? -6 : 6, y: 10)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch message.kind {
        case .text:
            VStack(alignment: .leading, spacing: 0) {
                Text(message.text)
                    .font(.moblyBody(13.5))
                    .foregroundStyle(message.fromMe ? .white : Color.moblyTextPrimary)
                    .multilineTextAlignment(.leading)
                if LinkPreviewService.firstURL(in: message.text) != nil {
                    MessageLinkPreview(text: message.text, fromMe: message.fromMe)
                }
            }
        case .voice:
            VoiceBubble(message: message)
        case .image:
            if let urlStr = message.mediaUrl, let url = URL(string: urlStr) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                            .frame(width: 200, height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    case .failure:
                        imagePlaceholder
                    default:
                        ProgressView()
                            .frame(width: 200, height: 150)
                    }
                }
                .onTapGesture { onImageTap?(url) }
            } else {
                imagePlaceholder
            }
        case .location:
            LocationBubble(message: message)
        case .visit:
            // Rendered via VisitCardBubble, not this bubble. Kept for exhaustive-switch.
            EmptyView()
        }
    }

    private var imagePlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(hex: 0xF1F2F6))
            Image(systemName: "photo")
                .font(.system(size: 28))
                .foregroundStyle(Color(hex: 0xC4C7D2))
        }
        .frame(width: 200, height: 150)
    }

    private var statusTicks: some View {
        Group {
            switch message.status {
            case .sent:
                Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.7))
            case .delivered:
                doubleCheck(Color.white.opacity(0.7))
            case .read:
                doubleCheck(Color(hex: 0x8FE3FF))
            }
        }
    }

    private func doubleCheck(_ color: Color) -> some View {
        ZStack {
            Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).offset(x: -3)
            Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).offset(x: 1)
        }
        .foregroundStyle(color)
    }

    private var bubbleShape: some Shape {
        UnevenRoundedRectangle(cornerRadii: .init(
            topLeading: 18,
            bottomLeading: message.fromMe ? 18 : 5,
            bottomTrailing: message.fromMe ? 5 : 18,
            topTrailing: 18))
    }

    private var replySwipe: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { v in
                if v.translation.width > 0 { dragOffset = min(v.translation.width, 60) }
            }
            .onEnded { v in
                if v.translation.width > 45 { onReply(); UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                withAnimation(.spring()) { dragOffset = 0 }
            }
    }
}

// MARK: - First-load skeleton

/// Placeholder bubbles shown for a fresh conversation while the first page
/// of history is on the wire. Cached threads skip this entirely — nothing
/// flashes over an already-populated list.
struct ChatSkeleton: View {
    @State private var shimmer = false
    private let rows: [(fromMe: Bool, width: CGFloat)] = [
        (false, 180), (true, 140), (false, 220), (true, 100), (false, 160)
    ]
    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack {
                    if r.fromMe { Spacer(minLength: 60) }
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(hex: 0xF1F2F6))
                        .frame(width: r.width, height: 34)
                        .overlay(
                            LinearGradient(colors: [
                                Color.white.opacity(0),
                                Color.white.opacity(0.55),
                                Color.white.opacity(0),
                            ], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 80)
                            .offset(x: shimmer ? r.width : -r.width)
                            .mask(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        )
                    if !r.fromMe { Spacer(minLength: 60) }
                }
            }
        }
        .padding(.top, 8)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) {
                shimmer = true
            }
        }
    }
}

// MARK: - Voice + location bubbles

/// Playable voice-note row. Bars fill left→right with `progress` and bounce
/// subtly while playing so the bubble reads as "in motion".
struct VoiceBubble: View {
    let message: ChatMessage
    @ObservedObject private var player = AudioPlayerManager.shared

    private var total: Int { message.voiceSeconds ?? 5 }
    private var progress: Double { player.progress(for: message.id) }
    private var isPlaying: Bool { player.isPlaying(id: message.id) }
    private var displaySeconds: Int {
        // While playing show elapsed; when idle show the full length.
        isPlaying ? player.elapsed(for: message.id, fallback: 0) : total
    }
    private var tint: Color { message.fromMe ? .white : Color.moblyPrimary }
    private var dimTint: Color {
        message.fromMe ? Color.white.opacity(0.35) : Color.moblyPrimary.opacity(0.28)
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                player.toggle(id: message.id, duration: total)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Waveform(tint: tint, dim: dimTint, progress: progress,
                     isPlaying: isPlaying,
                     realSamples: player.samples(for: message.id))
                .frame(width: 130, height: 24)

            Text(formatMinSec(displaySeconds))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(message.fromMe ? Color.white.opacity(0.85) : Color(hex: 0x9A9DAC))
        }
    }

    private func formatMinSec(_ s: Int) -> String {
        String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Location bubble. Static Maps snapshot on top, tap anywhere to open the
/// coordinate in Google Maps (if installed) or Apple Maps.
struct LocationBubble: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .center) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(colors: [Color(hex: 0xD5DEF5), Color(hex: 0xEEF0FE)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    .frame(width: 220, height: 120)
                gridLines
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(Color(hex: 0xE5484D))
                    .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(spacing: 6) {
                Image(systemName: "location.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(message.fromMe ? .white : Color.moblyPrimary)
                Text("Ma position")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(message.fromMe ? .white : Color.moblyTextPrimary)
                Spacer(minLength: 0)
                Text("Ouvrir")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(message.fromMe ? Color.white.opacity(0.85) : Color.moblyPrimary)
            }
            .frame(width: 220)
        }
        .contentShape(Rectangle())
        .onTapGesture { openInMaps() }
    }

    private var gridLines: some View {
        Canvas { ctx, size in
            let stroke = Color.white.opacity(0.5)
            for i in stride(from: 0, through: size.width, by: 22) {
                var p = Path(); p.move(to: CGPoint(x: i, y: 0)); p.addLine(to: CGPoint(x: i, y: size.height))
                ctx.stroke(p, with: .color(stroke), lineWidth: 0.5)
            }
            for j in stride(from: 0, through: size.height, by: 22) {
                var p = Path(); p.move(to: CGPoint(x: 0, y: j)); p.addLine(to: CGPoint(x: size.width, y: j))
                ctx.stroke(p, with: .color(stroke), lineWidth: 0.5)
            }
        }
        .frame(width: 220, height: 120)
        .allowsHitTesting(false)
    }

    private func openInMaps() {
        guard let lat = message.locationLat, let lng = message.locationLng else { return }
        // Prefer Google Maps app when installed; otherwise Apple Maps (works
        // without an LSApplicationQueriesSchemes entry via universal link).
        let g = URL(string: "comgooglemaps://?q=\(lat),\(lng)&center=\(lat),\(lng)")
        let apple = URL(string: "https://maps.apple.com/?ll=\(lat),\(lng)&q=Position")!
        if let g, UIApplication.shared.canOpenURL(g) {
            UIApplication.shared.open(g)
        } else {
            UIApplication.shared.open(apple)
        }
    }
}

// MARK: - Waveform + typing

struct Waveform: View {
    var tint: Color
    var dim: Color = .gray.opacity(0.3)
    var progress: Double = 0
    var isPlaying: Bool = false
    /// When non-nil, use real recorded audio levels instead of the static
    /// placeholder pattern. The array is down-sampled to fit the bar count.
    var realSamples: [CGFloat]? = nil

    private static let fallbackHeights: [CGFloat] = [
        8, 14, 20, 10, 16, 22, 12, 18, 9, 15, 21, 11, 17, 13, 19,
        10, 16, 8, 14, 20, 12, 18, 9
    ]
    private let barCount = 23
    @State private var pulse: Bool = false

    /// Build bar heights from real samples (down-sampled to `barCount`) or
    /// fall back to the static pattern for legacy messages.
    private var heights: [CGFloat] {
        guard let raw = realSamples, !raw.isEmpty else {
            return Self.fallbackHeights
        }
        // Down-sample the raw levels to exactly `barCount` bars.
        var out = [CGFloat]()
        let step = Double(raw.count) / Double(barCount)
        for i in 0..<barCount {
            let lo = Int(Double(i) * step)
            let hi = min(raw.count, Int(Double(i + 1) * step))
            let slice = raw[lo..<max(lo + 1, hi)]
            let avg = slice.reduce(0, +) / CGFloat(slice.count)
            // Scale 0-1 level to 4-22 pt height.
            out.append(4 + avg * 18)
        }
        return out
    }

    var body: some View {
        let bars = heights
        let played = Int((Double(barCount) * progress).rounded(.down))
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<bars.count, id: \.self) { i in
                let base = bars[i]
                let live = isPlaying && i == played
                Capsule()
                    .fill(i < played ? tint : dim)
                    .frame(width: 2.5, height: live && pulse ? base + 3 : base)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .animation(isPlaying ? .easeInOut(duration: 0.35).repeatForever(autoreverses: true) : .default,
                   value: pulse)
        .onAppear { pulse = isPlaying }
        .onChange(of: isPlaying) { _, v in pulse = v }
    }
}

/// Live recording waveform — renders the most recent samples as bars that
/// scroll left, giving visual feedback that the microphone is capturing audio.
struct LiveWaveform: View {
    let samples: [CGFloat]
    private let maxBars = 40

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 2) {
                let visible = Array(samples.suffix(maxBars))
                ForEach(Array(visible.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(Color.moblyPrimary)
                        .frame(width: 2.5, height: max(3, level * geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
    }
}

struct DateSeparator: View {
    let text: String
    var body: some View {
        Text(LT(text))
            .font(.moblyBody(10.5, weight: .semibold))
            .foregroundStyle(Color(hex: 0x6B6F80))
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.9)))
            .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
            .padding(.vertical, 4)
    }
}

struct TypingIndicator: View {
    @State private var phase = false
    var body: some View {
        HStack {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color(hex: 0x9A9DAC))
                        .frame(width: 8, height: 8)
                        .offset(y: phase ? -6 : 2)
                        .animation(
                            .easeInOut(duration: 0.45)
                                .repeatForever(autoreverses: true)
                                .delay(Double(i) * 0.18),
                            value: phase
                        )
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(
                UnevenRoundedRectangle(cornerRadii: .init(
                    topLeading: 18, bottomLeading: 5, bottomTrailing: 18, topTrailing: 18
                ))
                .fill(Color.white)
                .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
            )
            Spacer(minLength: 50)
        }
        .transition(.move(edge: .leading).combined(with: .opacity))
        .onAppear { phase = true }
    }
}

// MARK: - Visit card bubble
//
// Special centred bubble rendered when a message.kind == .visit. The snapshot
// `visitAction` picks the color and label; when the transition is REQUESTED
// and the current user is the owner, inline Confirmer / Refuser buttons act on
// the visit without leaving the thread.
struct VisitCardBubble: View {
    let message: ChatMessage
    /// True when the current user is the *receiver* of the visit request and
    /// therefore expected to Confirmer / Refuser. False when I sent it — I see
    /// the card without action buttons.
    let actionable: Bool
    /// True while a card action is in flight so the buttons disable + spin.
    var busy: Bool = false
    var onConfirm: () -> Void
    var onDecline: () -> Void

    @State private var pressed = false

    private var action: String { message.visitAction ?? "REQUESTED" }

    private var accent: Color {
        switch action {
        case "CONFIRMED":   return Color(hex: 0x1F8A5B)
        case "CANCELLED":   return Color(hex: 0xE5484D)
        case "COMPLETED":   return Color.moblyPrimary
        case "NO_SHOW":     return Color(hex: 0x9A9DAC)
        case "RESCHEDULED": return Color(hex: 0xC24E10)
        default:            return Color.moblyAccent   // REQUESTED
        }
    }
    private var chipBG: Color {
        switch action {
        case "CONFIRMED":   return Color(hex: 0xE9F9EF)
        case "CANCELLED":   return Color(hex: 0xFDEDED)
        case "COMPLETED":   return Color(hex: 0xEEF0FE)
        case "NO_SHOW":     return Color(hex: 0xF1F2F6)
        case "RESCHEDULED": return Color(hex: 0xFFF3EC)
        default:            return Color(hex: 0xFFF3EC)
        }
    }
    private var icon: String {
        switch action {
        case "CONFIRMED":   return "checkmark.seal.fill"
        case "CANCELLED":   return "xmark.seal.fill"
        case "COMPLETED":   return "flag.checkered"
        case "NO_SHOW":     return "person.slash"
        case "RESCHEDULED": return "clock.arrow.circlepath"
        default:            return "calendar.badge.plus"
        }
    }
    private var statusLabel: String {
        switch action {
        case "CONFIRMED":   return "Confirmée"
        case "CANCELLED":   return "Annulée"
        case "COMPLETED":   return "Terminée"
        case "NO_SHOW":     return "Non honorée"
        case "RESCHEDULED": return "Nouvel horaire"
        default:            return "En attente"
        }
    }

    var body: some View {
        HStack {
            Spacer(minLength: 20)
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(chipBG).frame(width: 40, height: 40)
                        Image(systemName: icon)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(accent)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(LT(statusLabel))
                            .font(.moblyBody(11, weight: .bold))
                            .foregroundStyle(accent)
                            .tracking(0.4)
                        Text(message.text)
                            .font(.moblyHeading(14.5))
                            .foregroundStyle(Color.moblyTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                if (action == "REQUESTED" || action == "RESCHEDULED") && actionable {
                    HStack(spacing: 8) {
                        Button(action: onConfirm) {
                            HStack(spacing: 6) {
                                if busy { ProgressView().tint(Color(hex: 0x1F8A5B)) }
                                else { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)) }
                                Text("Accepter").font(.moblyHeading(13.5))
                            }
                            .foregroundStyle(Color(hex: 0x1F8A5B))
                            .frame(maxWidth: .infinity).frame(height: 38)
                            .background(RoundedRectangle(cornerRadius: 11).fill(Color(hex: 0xE9F9EF)))
                            .opacity(busy ? 0.7 : 1)
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                        Button(action: onDecline) {
                            HStack(spacing: 6) {
                                Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                                Text("Refuser").font(.moblyHeading(13.5))
                            }
                            .foregroundStyle(Color(hex: 0xE5484D))
                            .frame(maxWidth: .infinity).frame(height: 38)
                            .background(RoundedRectangle(cornerRadius: 11).fill(Color(hex: 0xFDEDED)))
                            .opacity(busy ? 0.7 : 1)
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                    }
                }

                HStack {
                    Spacer()
                    Text(message.time)
                        .font(.moblyBody(10.5))
                        .foregroundStyle(Color.moblyTextSecondary)
                }
            }
            .padding(14)
            .frame(maxWidth: 300)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(accent.opacity(0.35), lineWidth: 1.5)
                    )
                    .shadow(color: Color(hex: 0x14152A).opacity(0.06), radius: 8, y: 3)
            )
            Spacer(minLength: 20)
        }
    }
}

// MARK: - Pinned visit strip
//
// A slim, single-row banner that lives right under the listing pill. Same
// visual language as the message-list VisitCardBubble but shrunk to a strip
// so it doesn't dominate the thread.
struct PinnedVisitStrip: View {
    let message: ChatMessage
    let actionable: Bool
    var busy: Bool = false
    var onConfirm: () -> Void
    var onDecline: () -> Void

    private var action: String { message.visitAction ?? "REQUESTED" }

    private var accent: Color {
        switch action {
        case "CONFIRMED":   return Color(hex: 0x1F8A5B)
        case "CANCELLED":   return Color(hex: 0xE5484D)
        case "COMPLETED":   return Color.moblyPrimary
        case "NO_SHOW":     return Color(hex: 0x9A9DAC)
        case "RESCHEDULED": return Color(hex: 0xC24E10)
        default:            return Color.moblyAccent
        }
    }
    private var bgTint: Color {
        switch action {
        case "CONFIRMED":   return Color(hex: 0xE9F9EF)
        case "CANCELLED":   return Color(hex: 0xFDEDED)
        case "COMPLETED":   return Color(hex: 0xEEF0FE)
        case "NO_SHOW":     return Color(hex: 0xF1F2F6)
        case "RESCHEDULED": return Color(hex: 0xFFF3EC)
        default:            return Color(hex: 0xFFF3EC)
        }
    }
    private var icon: String {
        switch action {
        case "CONFIRMED":   return "checkmark.seal.fill"
        case "CANCELLED":   return "xmark.seal.fill"
        case "COMPLETED":   return "flag.checkered"
        case "NO_SHOW":     return "person.slash"
        case "RESCHEDULED": return "clock.arrow.circlepath"
        default:            return "calendar.badge.plus"
        }
    }
    private var statusLabel: String {
        switch action {
        case "CONFIRMED":   return "Confirmée"
        case "CANCELLED":   return "Annulée"
        case "COMPLETED":   return "Terminée"
        case "NO_SHOW":     return "Non honorée"
        case "RESCHEDULED": return "Nouvel horaire"
        default:            return "En attente"
        }
    }

    /// Just the "· <date>" tail from the SYSTEM message text, so the strip
    /// reads e.g. "En attente · jeudi 13 août · 21h29" without repeating
    /// the "Visite demandée" phrase (already implied by the status label).
    private var dateTail: String {
        if let sep = message.text.range(of: " · ") {
            return String(message.text[sep.upperBound...])
        }
        return message.text
    }

    private var showsActions: Bool {
        (action == "REQUESTED" || action == "RESCHEDULED") && actionable
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(bgTint).frame(width: 30, height: 30)
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accent)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(LT(statusLabel))
                        .font(.moblyBody(10.5, weight: .bold))
                        .foregroundStyle(accent)
                        .tracking(0.3)
                    Text(dateTail)
                        .font(.moblyHeading(13))
                        .foregroundStyle(Color.moblyTextPrimary)
                        .lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if busy {
                    ProgressView().tint(accent).padding(.trailing, 4)
                }
            }
            if showsActions {
                HStack(spacing: 8) {
                    compactButton(title: "Accepter", icon: "checkmark",
                                  fg: Color(hex: 0x1F8A5B), bg: Color(hex: 0xE9F9EF),
                                  action: onConfirm)
                    compactButton(title: "Refuser", icon: "xmark",
                                  fg: Color(hex: 0xE5484D), bg: Color(hex: 0xFDEDED),
                                  action: onDecline)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(hex: 0xE2E4EC)).frame(height: 1)
        }
        .overlay(alignment: .leading) {
            Rectangle().fill(accent).frame(width: 3)
        }
    }

    private func compactButton(title: String, icon: String, fg: Color, bg: Color,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold))
                Text(LT(title)).font(.moblyHeading(12.5)).lineLimit(1)
            }
            .foregroundStyle(fg)
            .frame(maxWidth: .infinity).frame(height: 32)
            .background(Capsule().fill(bg))
            .opacity(busy ? 0.7 : 1)
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }
}

// MARK: - Propose visit sheet (owner-initiated, from chat)

struct ProposeVisitFromChatSheet: View {
    let thread: ChatThread
    @Environment(\.dismiss) private var dismiss

    @State private var date: Date = {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: .now) ?? .now
        return cal.date(bySettingHour: 15, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }()
    @State private var note = ""
    @State private var isSubmitting = false
    @State private var submitError: String?
    @State private var didSubmit = false

    var body: some View {
        VStack(spacing: 0) {
            if didSubmit { successView } else { formView }
        }
        .background(Color.moblySurface)
    }

    private var formView: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Proposer une visite")
                    .font(.moblyHeading(20))
                    .foregroundStyle(Color.moblyTextPrimary)
                Spacer()
            }
            .padding(.top, 12)

            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color(hex: 0xEEF0FE)).frame(width: 44, height: 44)
                    Text(thread.initial).font(.moblyHeading(16)).foregroundStyle(Color.moblyPrimary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(thread.name).font(.moblyHeading(14))
                        .foregroundStyle(Color.moblyTextPrimary)
                    Text(thread.listingTitle).font(.moblyBody(12))
                        .foregroundStyle(Color.moblyTextSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(.white))

            VStack(alignment: .leading, spacing: 8) {
                Text("Date et heure").font(.moblyHeading(14))
                    .foregroundStyle(Color.moblyTextPrimary)
                DatePicker("", selection: $date, in: Date.now...,
                           displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .environment(\.locale, Locale(identifier: "fr_FR"))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Message (optionnel)")
                    .font(.moblyHeading(14))
                    .foregroundStyle(Color.moblyTextPrimary)
                TextField("Bonjour, je vous propose ce créneau…",
                          text: $note, axis: .vertical)
                    .lineLimit(3...5)
                    .font(.moblyBody(14))
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.white)
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(hex: 0xE2E4EC), lineWidth: 1)))
            }

            if let err = submitError {
                Text(err).font(.moblyBody(12))
                    .foregroundStyle(Color(hex: 0xE5484D))
            }

            Spacer(minLength: 0)

            Button(action: submit) {
                HStack(spacing: 8) {
                    if isSubmitting { ProgressView().tint(.white) }
                    Text(isSubmitting ? "Envoi…" : "Envoyer la proposition")
                        .font(.moblyHeading(15))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 52)
                .background(RoundedRectangle(cornerRadius: 15)
                    .fill(isSubmitting || !canSubmit ? Color(hex: 0x9BA6F8) : Color.moblyPrimary))
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting || !canSubmit)
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 20)
    }

    private var canSubmit: Bool {
        thread.peerId != nil && thread.listingId != nil
    }

    private var successView: some View {
        VStack(spacing: 16) {
            Spacer()
            ZStack {
                Circle().fill(Color(hex: 0xE9F9EF)).frame(width: 84, height: 84)
                Image(systemName: "checkmark")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Color(hex: 0x1F8A5B))
            }
            Text("Proposition envoyée")
                .font(.moblyHeading(20))
                .foregroundStyle(Color.moblyTextPrimary)
            Text("Le visiteur pourra accepter ou refuser directement dans la conversation.")
                .font(.moblyBody(13.5))
                .foregroundStyle(Color.moblyTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            Spacer()
            Button { dismiss() } label: {
                Text("Terminé")
                    .font(.moblyHeading(15)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(RoundedRectangle(cornerRadius: 15).fill(Color.moblyPrimary))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    private func submit() {
        guard let visitorId = thread.peerId, let listingId = thread.listingId else {
            submitError = "Conversation incomplète."
            return
        }
        submitError = nil
        isSubmitting = true
        Task {
            do {
                _ = try await MoblyAPI.shared.inviteVisit(
                    listingId: listingId,
                    visitorId: visitorId,
                    scheduledAt: date,
                    note: note.isEmpty ? nil : note
                )
                await MainActor.run {
                    isSubmitting = false
                    didSubmit = true
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            } catch let e as MoblyAPI.APIError {
                await MainActor.run {
                    isSubmitting = false
                    submitError = e.message
                }
            } catch {
                await MainActor.run {
                    isSubmitting = false
                    submitError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Photo library picker

struct PhotoLibraryPicker: UIViewControllerRepresentable {
    var onFinish: ([UIImage]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = 5
        config.filter = .images
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onFinish: ([UIImage]) -> Void
        init(onFinish: @escaping ([UIImage]) -> Void) { self.onFinish = onFinish }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !results.isEmpty else { onFinish([]); return }
            var images: [UIImage] = []
            let group = DispatchGroup()
            for result in results {
                group.enter()
                result.itemProvider.loadObject(ofClass: UIImage.self) { object, _ in
                    if let img = object as? UIImage { images.append(img) }
                    group.leave()
                }
            }
            group.notify(queue: .main) { [weak self] in
                self?.onFinish(images)
            }
        }
    }
}

// MARK: - Camera picker

struct CameraPickerView: UIViewControllerRepresentable {
    var onFinish: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (UIImage?) -> Void
        init(onFinish: @escaping (UIImage?) -> Void) { self.onFinish = onFinish }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            onFinish(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
        }
    }
}

// MARK: - Full-screen image viewer

struct FullScreenImageViewer: View {
    let url: URL
    var onClose: () -> Void

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(
                            MagnifyGesture()
                                .onChanged { v in scale = lastScale * v.magnification }
                                .onEnded { v in
                                    lastScale = max(1, scale)
                                    scale = lastScale
                                    if scale == 1 { offset = .zero; lastOffset = .zero }
                                }
                        )
                        .simultaneousGesture(
                            DragGesture()
                                .onChanged { v in
                                    if scale > 1 {
                                        offset = CGSize(
                                            width: lastOffset.width + v.translation.width,
                                            height: lastOffset.height + v.translation.height
                                        )
                                    }
                                }
                                .onEnded { v in
                                    lastOffset = offset
                                    if scale <= 1 {
                                        let dragY = v.translation.height
                                        if abs(dragY) > 100 {
                                            onClose()
                                        }
                                    }
                                }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation(.spring(response: 0.3)) {
                                if scale > 1 {
                                    scale = 1; lastScale = 1
                                    offset = .zero; lastOffset = .zero
                                } else {
                                    scale = 2.5; lastScale = 2.5
                                }
                            }
                        }
                case .failure:
                    VStack(spacing: 12) {
                        Image(systemName: "photo.slash")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.5))
                        Text("Impossible de charger l'image")
                            .font(.moblyBody(14))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                default:
                    ProgressView().tint(.white).scaleEffect(1.3)
                }
            }

            VStack {
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(.white.opacity(0.2)))
                    }
                    .padding(.trailing, 16).padding(.top, 8)
                }
                Spacer()
            }
        }
        .statusBarHidden()
    }
}

#Preview {
    ChatThreadView(thread: ChatThread.preview)
}
