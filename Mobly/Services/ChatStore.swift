import Foundation
import Combine

// MARK: - Wire types (match backend/src/routes/chat.routes.ts)

struct MessageDTO: Codable, Identifiable, Equatable {
    let id: String
    let threadId: String
    let senderId: String
    /// Client-generated id, echoed back. Lets an optimistic bubble be replaced
    /// by the confirmed row instead of appearing twice.
    let clientId: String?
    let kind: String
    let text: String
    let mediaUrl: String?
    let durationSec: Int?
    let replyToId: String?
    /// Set only when this is a SYSTEM message posted from a visit state change.
    /// `visitAction` snapshots the transition (REQUESTED / CONFIRMED / CANCELLED
    /// / COMPLETED / NO_SHOW / RESCHEDULED); `visitId` points at the underlying
    /// VisitRequest row so the recipient can act on it in place.
    let visitId: String?
    let visitAction: String?
    var read: Bool
    let readAt: Date?
    let createdAt: Date
}

struct ThreadPeerDTO: Codable, Identifiable, Equatable {
    let id: String
    let fullName: String
    let avatarUrl: String?
    let avatarColor: String?
    let verified: Bool
    var online: Bool?
}

struct ThreadListingDTO: Codable, Equatable {
    let id: String
    let title: String
    let imageName: String?
    let coverUrl: String?
    let priceFcfa: Int?
    /// Lets the client tell whether *I* own this listing, which decides
    /// whether the quick replies are questions or answers.
    let ownerId: String?
}

struct ThreadDTO: Codable, Identifiable, Equatable {
    let id: String
    let listing: ThreadListingDTO?
    var participants: [ThreadPeerDTO]
    var lastMessage: MessageDTO?
    var unread: Int
    let updatedAt: Date
}

/// Conversations, messages, and the live socket.
///
/// **Where messages live:** Supabase is the source of truth. This store keeps a
/// copy on disk so a thread opens instantly and stays readable offline — on a
/// Douala connection, refetching history on every open is both slow and
/// expensive for the user.
@MainActor
final class ChatStore: ObservableObject {
    static let shared = ChatStore()

    @Published private(set) var threads: [ThreadDTO] = []
    @Published private(set) var messages: [String: [MessageDTO]] = [:]   // threadId -> messages
    @Published private(set) var typingIn: Set<String> = []               // threadIds
    @Published private(set) var isLoadingThreads = false
    /// Thread ids that are currently fetching a page of messages. The chat
    /// view uses this to show a small "chargement…" indicator only when the
    /// local cache is empty — a warm cache renders instantly, no spinner.
    @Published private(set) var loadingMessagesFor: Set<String> = []
    @Published private(set) var isOffline = false

    /// Id of the last message the user acknowledged as read, per thread.
    /// `loadThreads()` uses this to force unread=0 for a thread the user
    /// JUST opened whose server-side mark-read POST is still in flight —
    /// but only when the server's newest message id is exactly the one we
    /// already read. A different newest id means a real new message arrived
    /// and the badge must appear. Keying by id (not a timestamp) removes the
    /// client/server clock-skew race that would otherwise silently drop it.
    private var lastReadMessageId: [String: String] = [:]
    /// When each thread was last prewarmed. Used by `prewarmAllThreads` to
    /// skip a refetch that happened within the TTL window.
    private var lastPrewarmedAt: [String: Date] = [:]
    /// Thread the user is currently looking at. Incoming messages for it must
    /// not bump the badge — the user is reading them in real time.
    var activeThreadId: String?

    var isConnected: Bool { socket.state == .connected }
    let socket = ChatSocket()

    private let api = MoblyAPI.shared
    private var cancellables = Set<AnyCancellable>()

    private init() {
        loadFromDisk()

        socket.onEvent = { [weak self] event in
            Task { @MainActor in self?.apply(event) }
        }
        // Re-render when the socket's connection state changes.
        socket.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // A refused refresh ends the session — drop the cache so the next user
        // on this device can't read the previous one's conversations.
        NotificationCenter.default.addObserver(
            forName: MoblyAPI.sessionExpired, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.clearLocal() }
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard api.isAuthenticated else { return }
        socket.connect()
        Task {
            await loadThreads()
            // Sync every conversation's first page in the background right
            // after the inbox lands so tapping a thread later opens with
            // zero perceptible delay. Concurrency capped so a user with a
            // long inbox doesn't fire dozens of requests at once.
            await prewarmAllThreads()
        }
    }

    /// Fetch the first page of every thread in parallel (bounded). Called
    /// after `loadThreads` at start and after `bootstrap` on cold launches.
    /// Silently no-ops for threads whose cache is already fresh, so a warm
    /// relaunch does not hammer the server.
    func prewarmAllThreads(force: Bool = false) async {
        let ids = threads.map(\.id)
        guard !ids.isEmpty else { return }
        let now = Date()
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for id in ids {
                // Skip when we fetched this thread within the last 30s and
                // the caller isn't explicitly asking for a fresh pull.
                if !force, let ts = lastPrewarmedAt[id],
                   now.timeIntervalSince(ts) < 30 { continue }
                if running >= 4 { await group.next(); running -= 1 }
                group.addTask { await self.loadMessages(threadId: id) }
                lastPrewarmedAt[id] = now
                running += 1
            }
        }
    }

    func stop() { socket.disconnect() }

    // MARK: - Loading

    func loadThreads() async {
        isLoadingThreads = true
        isOffline = false
        defer { isLoadingThreads = false }
        do {
            struct Wrap: Decodable { let items: [ThreadDTO] }
            let w: Wrap = try await api.request("threads", authorized: true)
            // Force unread=0 for a thread the user just opened whose server
            // mark-read POST is still in flight — but only when the server's
            // newest message is exactly the one we've already seen. If it's
            // a different id, a real new message arrived and the badge stays.
            threads = w.items.map { dto in
                var t = dto
                if let readId = lastReadMessageId[dto.id],
                   dto.lastMessage?.id == readId {
                    t.unread = 0
                }
                return t
            }
            saveToDisk()
        } catch let e as MoblyAPI.APIError {
            // Cached threads stay on screen; only the banner changes.
            if e.isOffline { isOffline = true }
        } catch {}
    }

    /// Load a page of history. Cached messages show immediately; the fetch
    /// reconciles afterwards.
    func loadMessages(threadId: String, before: Date? = nil) async {
        loadingMessagesFor.insert(threadId)
        defer { loadingMessagesFor.remove(threadId) }
        do {
            struct Wrap: Decodable { let items: [MessageDTO]; let nextBefore: Date? }
            var query: [String: String] = ["limit": "50"]
            if let before { query["before"] = ISO8601DateFormatter().string(from: before) }
            let w: Wrap = try await api.request(
                "threads/\(threadId)/messages", query: query, authorized: true
            )
            if before == nil {
                // Preserve any optimistic ("local-…") messages the user just
                // sent — they haven't been echoed back by the server yet, so
                // an unconditional replace would make them briefly vanish.
                let pending = (messages[threadId] ?? []).filter { $0.id.hasPrefix("local-") }
                messages[threadId] = w.items + pending
            } else {
                messages[threadId] = w.items + (messages[threadId] ?? [])
            }
            saveToDisk()
        } catch let e as MoblyAPI.APIError {
            if e.isOffline { isOffline = true }
        } catch {}
    }

    // MARK: - Sending

    /// Open (or reuse) the conversation about a listing. The owner is resolved
    /// server-side from the listing id.
    ///
    /// Returns the thread itself rather than an id: a freshly created thread
    /// has no messages yet, and `GET /threads` deliberately hides those — so
    /// re-fetching the list to find it would come back empty.
    @discardableResult
    /// Open (or reuse) a conversation.
    ///
    /// Pass `otherUserId` when the peer is NOT the listing's owner — an owner
    /// opening a chat from their visit inbox is talking to the *visitor*, and
    /// letting the server derive the peer from the listing would resolve to
    /// the owner themselves and fail.
    func openThread(listingId: String, otherUserId: String? = nil) async -> ThreadDTO? {
        do {
            struct Body: Encodable { let listingId: String; let otherUserId: String? }
            struct Wrap: Decodable { let thread: ThreadDTO }
            let w: Wrap = try await api.request(
                "threads", method: "POST",
                body: Body(listingId: listingId, otherUserId: otherUserId),
                authorized: true
            )
            // Keep it locally so the conversation screen can render straight
            // away; it joins the inbox once a message exists.
            if !threads.contains(where: { $0.id == w.thread.id }) {
                threads.insert(w.thread, at: 0)
            }
            return w.thread
        } catch let e as MoblyAPI.APIError {
            isOffline = e.isOffline
            return nil
        } catch {
            return nil
        }
    }

    /// Send a message.
    ///
    /// The bubble appears immediately with a locally-minted `clientId`, then is
    /// replaced by the server's row when it confirms. Because the server keys
    /// on that same `clientId`, a retry after a dropped connection resolves to
    /// the existing message rather than posting twice.
    func send(threadId: String, text: String, myUserId: String,
              kind: String = "TEXT", mediaUrl: String? = nil,
              replyToId: String? = nil) async {
        let clientId = UUID().uuidString
        let optimistic = MessageDTO(
            id: "local-\(clientId)", threadId: threadId, senderId: myUserId,
            clientId: clientId, kind: kind, text: text, mediaUrl: mediaUrl,
            durationSec: nil, replyToId: replyToId, visitId: nil, visitAction: nil,
            read: false, readAt: nil, createdAt: Date()
        )
        messages[threadId, default: []].append(optimistic)
        bumpThreadToTop(threadId, lastMessage: optimistic)

        do {
            struct Body: Encodable {
                let text: String; let clientId: String; let kind: String
                let mediaUrl: String?; let replyToId: String?
            }
            struct Wrap: Decodable { let message: MessageDTO }
            let w: Wrap = try await api.request(
                "threads/\(threadId)/messages", method: "POST",
                body: Body(text: text, clientId: clientId, kind: kind,
                           mediaUrl: mediaUrl, replyToId: replyToId),
                authorized: true
            )
            // Swap the placeholder for the confirmed row.
            if let i = messages[threadId]?.firstIndex(where: { $0.clientId == clientId }) {
                messages[threadId]?[i] = w.message
            }
            bumpThreadToTop(threadId, lastMessage: w.message)
            saveToDisk()
            // Asked here rather than at launch: someone who has just messaged an
            // owner has an obvious reason to want the reply, so the prompt lands
            // far better than a cold one on first open.
            await PushService.shared.requestIfAppropriate()
        } catch {
            // Leave the optimistic bubble in place — it still carries the text,
            // and the same clientId makes a later retry safe.
            isOffline = (error as? MoblyAPI.APIError)?.isOffline ?? false
        }
    }

    /// Update the thread's preview + move it to the top of the inbox, so an
    /// outgoing message lands where the eye expects it (last-sent = top).
    private func bumpThreadToTop(_ threadId: String, lastMessage: MessageDTO) {
        guard let i = threads.firstIndex(where: { $0.id == threadId }) else { return }
        threads[i].lastMessage = lastMessage
        if i != 0 {
            let t = threads.remove(at: i)
            threads.insert(t, at: 0)
        }
    }

    func markRead(threadId: String) {
        socket.markRead(threadId: threadId)
        // Watermark = the newest message id we have locally. Server-fetched
        // history is authoritative; local optimistic ("local-…") ids are
        // skipped because the server has never heard of them and would
        // never echo them back through loadThreads().
        if let newest = messages[threadId]?.last(where: { !$0.id.hasPrefix("local-") })?.id {
            lastReadMessageId[threadId] = newest
        } else if let last = threads.first(where: { $0.id == threadId })?.lastMessage?.id {
            lastReadMessageId[threadId] = last
        }
        if let i = threads.firstIndex(where: { $0.id == threadId }) {
            threads[i].unread = 0
        }
        Task {
            _ = try? await api.request(
                "threads/\(threadId)/read", method: "POST", authorized: true
            ) as EmptyResponse
        }
    }

    func setTyping(threadId: String, _ typing: Bool) {
        socket.sendTyping(threadId: threadId, typing: typing)
    }

    // MARK: - Socket events

    private func apply(_ event: ChatSocket.Event) {
        switch event {
        case .message(let threadId, let message):
            var list = messages[threadId] ?? []
            // Guard against the echo of our own send and any duplicate frame.
            if !list.contains(where: { $0.id == message.id })
                && !(message.clientId.map { c in list.contains { $0.clientId == c } } ?? false) {
                list.append(message)
                messages[threadId] = list
            }
            let myId = AuthStore.shared.user?.id
            let mine = message.senderId == myId
            let viewing = activeThreadId == threadId
            if let i = threads.firstIndex(where: { $0.id == threadId }) {
                threads[i].lastMessage = message
                // Only bump the badge for a message that (a) isn't mine and
                // (b) the user isn't currently reading. Otherwise the count
                // reappears on threads the user just cleared.
                if !mine && !viewing {
                    threads[i].unread += 1
                    // A new inbound message invalidates the read watermark
                    // so a subsequent loadThreads() no longer forces this
                    // thread to 0.
                    lastReadMessageId.removeValue(forKey: threadId)
                }
                if i != 0 {
                    let t = threads.remove(at: i)
                    threads.insert(t, at: 0)
                }
            } else {
                // First message of a thread we haven't loaded yet.
                Task { await loadThreads() }
            }
            // If a message arrives while the user has the thread open, ack
            // it as read immediately so the server counters agree with the UI.
            if viewing && !mine {
                markRead(threadId: threadId)
            }
            saveToDisk()

        case .typing(let threadId, _, let typing):
            if typing { typingIn.insert(threadId) } else { typingIn.remove(threadId) }

        case .read(let threadId, _):
            messages[threadId] = messages[threadId]?.map { m in
                var copy = m
                copy.read = true
                return copy
            }

        case .presence(let userId, let online):
            for i in threads.indices {
                if let j = threads[i].participants.firstIndex(where: { $0.id == userId }) {
                    threads[i].participants[j].online = online
                }
            }

        case .callIncoming(let callId, let threadId, let fromId, let fromName, let isVideo):
            CallService.shared.handleIncoming(callId: callId, threadId: threadId,
                                              fromId: fromId, fromName: fromName, isVideo: isVideo)
        case .callAccepted:
            CallService.shared.handleAccepted()
        case .callRejected:
            CallService.shared.handleRejected()
        case .callEnded:
            CallService.shared.handleEnded()
        case .callAudio(let data):
            CallService.shared.handleAudioData(data)
        }
    }

    // MARK: - Local storage

    /// Conversations are personal data, so the cache lives in Application
    /// Support (not Caches, which the system may purge mid-conversation) with
    /// file protection — encrypted at rest, readable after first unlock so a
    /// background push can still update it.
    private var cacheURL: URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        let folder = dir.appendingPathComponent("Mobly", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("chat-cache.json")
    }

    private struct Snapshot: Codable {
        var threads: [ThreadDTO]
        var messages: [String: [MessageDTO]]
    }

    private func saveToDisk() {
        guard let url = cacheURL else { return }
        // Only the recent tail is worth keeping — full history is a server
        // concern, and an unbounded file would grow forever on disk.
        let trimmed = messages.mapValues { Array($0.suffix(200)) }
        let snapshot = Snapshot(threads: threads, messages: trimmed)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func loadFromDisk() {
        guard let url = cacheURL, let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(Snapshot.self, from: data) else { return }
        threads = snapshot.threads
        messages = snapshot.messages
    }

    #if DEBUG
    /// Debug-only helper: drop a set of demo messages into a thread id so a
    /// screenshot route (`START_AT=thread`) has content to render.
    func debugSeed(threadId: String, messages: [MessageDTO]) {
        self.messages[threadId] = messages
    }
    #endif

    /// Wipe on sign-out — another user on the same device must not find the
    /// previous one's conversations sitting in the cache. Also drops the
    /// unread watermark (`lastReadMessageId`) so a new user's badge is
    /// driven purely by what the server reports; without this, a shared
    /// thread id could carry the previous user's "already read" watermark
    /// forward and hide legitimate new messages.
    func clearLocal() {
        threads = []
        messages = [:]
        typingIn = []
        lastReadMessageId = [:]
        activeThreadId = nil
        if let url = cacheURL { try? FileManager.default.removeItem(at: url) }
    }
}
