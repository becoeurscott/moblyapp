import Foundation

/// WebSocket link to the chat hub.
///
/// Uses `URLSessionWebSocketTask` (built into Foundation — no dependency) and
/// mirrors the server contract in `backend/src/realtime/hub.ts`:
/// the token goes in the **first frame**, never the URL, because query strings
/// end up in access logs and proxy history.
///
/// The socket only ever *receives*. Sending goes through REST so it has a
/// status code, a retry story and idempotency — see `ChatStore.send`.
@MainActor
final class ChatSocket: NSObject, ObservableObject {

    enum State { case disconnected, connecting, connected }
    @Published private(set) var state: State = .disconnected

    /// Events surfaced to the store.
    enum Event {
        case message(threadId: String, message: MessageDTO)
        case typing(threadId: String, userId: String, typing: Bool)
        case read(threadId: String, userId: String)
        case presence(userId: String, online: Bool)
        case callIncoming(callId: String, threadId: String, fromId: String, fromName: String, isVideo: Bool)
        case callAccepted(callId: String)
        case callRejected(callId: String)
        case callEnded(callId: String)
        case callAudio(Data)
    }

    var onEvent: ((Event) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var reconnectAttempt = 0
    private var pingTimer: Timer?
    /// Set when the app deliberately disconnects, so we don't fight it by
    /// reconnecting.
    private var intentionallyClosed = false

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// `http(s)://host/api/v1` → `ws(s)://host/ws`
    private var socketURL: URL? {
        guard var comps = URLComponents(url: MoblyAPI.shared.baseURL,
                                        resolvingAgainstBaseURL: false) else { return nil }
        comps.scheme = (comps.scheme == "https") ? "wss" : "ws"
        comps.path = "/ws"
        comps.query = nil
        return comps.url
    }

    func connect() {
        guard state == .disconnected, MoblyAPI.shared.isAuthenticated,
              let url = socketURL else { return }
        intentionallyClosed = false
        state = .connecting

        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
        self.session = session

        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receive()
        authenticate()
    }

    func disconnect() {
        intentionallyClosed = true
        pingTimer?.invalidate()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        state = .disconnected
    }

    // MARK: - Outbound

    private func authenticate() {
        guard let token = MoblyAPI.shared.token else { return }
        sendJSON(["type": "auth", "token": token])
    }

    func sendTyping(threadId: String, typing: Bool) {
        guard state == .connected else { return }
        sendJSON(["type": "typing", "threadId": threadId, "typing": typing])
    }

    func markRead(threadId: String) {
        guard state == .connected else { return }
        sendJSON(["type": "read", "threadId": threadId])
    }

    // MARK: - Call signaling

    func sendCallStart(callId: String, threadId: String, isVideo: Bool) {
        sendJSON(["type": "call:start", "callId": callId, "threadId": threadId, "isVideo": isVideo])
    }

    func sendCallAccept(callId: String) {
        sendJSON(["type": "call:accept", "callId": callId])
    }

    func sendCallReject(callId: String) {
        sendJSON(["type": "call:reject", "callId": callId])
    }

    func sendCallEnd(callId: String) {
        sendJSON(["type": "call:end", "callId": callId])
    }

    func sendCallAudio(_ data: Data) {
        guard state == .connected else { return }
        task?.send(.data(data)) { _ in }
    }

    private func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { [weak self] error in
            if error != nil { Task { @MainActor in self?.scheduleReconnect() } }
        }
    }

    // MARK: - Inbound

    private func receive() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure:
                    self.scheduleReconnect()
                case .success(let message):
                    switch message {
                    case .string(let text): self.handle(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8),
                           text.first == "{" {
                            self.handle(text)
                        } else {
                            self.onEvent?(.callAudio(data))
                        }
                    @unknown default: break
                    }
                    // One receive only ever delivers one frame — re-arm.
                    self.receive()
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let envelope = try? decoder.decode(Envelope.self, from: data) else { return }

        switch envelope.type {
        case "ready":
            state = .connected
            reconnectAttempt = 0
            startPing()
        case "message":
            if let threadId = envelope.threadId, let m = envelope.message {
                onEvent?(.message(threadId: threadId, message: m))
            }
        case "typing":
            if let threadId = envelope.threadId, let userId = envelope.userId {
                onEvent?(.typing(threadId: threadId, userId: userId, typing: envelope.typing ?? false))
            }
        case "read":
            if let threadId = envelope.threadId, let userId = envelope.userId {
                onEvent?(.read(threadId: threadId, userId: userId))
            }
        case "presence":
            if let userId = envelope.userId {
                onEvent?(.presence(userId: userId, online: envelope.online ?? false))
            }
        case "call:incoming":
            if let callId = envelope.callId, let threadId = envelope.threadId,
               let from = envelope.from {
                onEvent?(.callIncoming(callId: callId, threadId: threadId,
                                       fromId: from.id, fromName: from.name,
                                       isVideo: envelope.isVideo ?? false))
            }
        case "call:accepted":
            if let callId = envelope.callId { onEvent?(.callAccepted(callId: callId)) }
        case "call:rejected":
            if let callId = envelope.callId { onEvent?(.callRejected(callId: callId)) }
        case "call:ended":
            if let callId = envelope.callId { onEvent?(.callEnded(callId: callId)) }
        case "error":
            // The server refused the token — a reconnect loop would just spam
            // it, so wait for the app to re-authenticate.
            disconnect()
        default:
            break
        }
    }

    private struct CallPeer: Decodable {
        let id: String
        let name: String
    }

    private struct Envelope: Decodable {
        let type: String
        let threadId: String?
        let userId: String?
        let typing: Bool?
        let online: Bool?
        let message: MessageDTO?
        let callId: String?
        let isVideo: Bool?
        let from: CallPeer?
    }

    // MARK: - Keepalive & reconnect

    private func startPing() {
        pingTimer?.invalidate()
        // The server also pings, but an idle socket behind a mobile NAT can be
        // reaped from our side too — keep traffic flowing both ways.
        pingTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sendJSON(["type": "ping"]) }
        }
    }

    /// Exponential backoff with jitter, capped at 30s. Without the cap a long
    /// outage would push retries out to hours; without jitter every client in
    /// the country reconnects on the same beat.
    private func scheduleReconnect() {
        guard !intentionallyClosed else { return }
        pingTimer?.invalidate()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        state = .disconnected

        guard MoblyAPI.shared.isAuthenticated else { return }
        reconnectAttempt += 1
        let base = min(pow(2.0, Double(reconnectAttempt)) * 0.5, 30)
        let delay = base + Double.random(in: 0...1)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self?.connect()
        }
    }
}

extension ChatSocket: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession,
                                webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                                reason: Data?) {
        Task { @MainActor in self.scheduleReconnect() }
    }
}
