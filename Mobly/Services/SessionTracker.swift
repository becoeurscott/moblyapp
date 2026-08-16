import Foundation
import UIKit

/// Per-install analytics session + typed event queue.
///
/// Anonymous by default: the first cold launch mints a `deviceId` (persisted in
/// UserDefaults for the lifetime of the install) and asks the backend for a
/// `sessionId`. When the user later signs in, `attach()` links the session to
/// their account, so the sign-up funnel survives without any duplicate rows.
///
/// Events are queued locally and flushed in small batches — this cuts the
/// per-tap network cost on a spotty Douala connection and coalesces bursts
/// (e.g. a scroll through six screens becomes one POST). A flush also runs on
/// background so nothing is dropped when the app is suspended.
@MainActor
final class SessionTracker {
    static let shared = SessionTracker()

    private let api = MoblyAPI.shared

    private enum Key {
        static let deviceId = "analytics.deviceId"
    }

    private(set) var deviceId: String
    private(set) var sessionId: String?

    private var queue: [PendingEvent] = []
    private var flushTask: Task<Void, Never>?
    private var heartbeatTimer: Timer?

    private init() {
        // Stable per-install identifier — never the vendor id, so an app
        // reinstall counts as a new install and we can't correlate across
        // uninstalls.
        if let existing = UserDefaults.standard.string(forKey: Key.deviceId) {
            deviceId = existing
        } else {
            let fresh = UUID().uuidString
            UserDefaults.standard.set(fresh, forKey: Key.deviceId)
            deviceId = fresh
        }
    }

    // MARK: - Lifecycle

    /// Call once on app launch. Idempotent — a second call reuses the current
    /// session id.
    func start() async {
        if sessionId != nil { return }
        observeLifecycle()
        do {
            struct Body: Encodable {
                let deviceId: String
                let appVersion: String?
                let os: String?
            }
            struct Resp: Decodable { let sessionId: String }
            let body = Body(
                deviceId: deviceId,
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                os: "iOS \(UIDevice.current.systemVersion)"
            )
            let r: Resp = try await api.request(
                "sessions/start", method: "POST", body: body,
                authorized: api.isAuthenticated, retries: 1
            )
            sessionId = r.sessionId
            startHeartbeat()
        } catch {
            // Best-effort. A missed session shouldn't block the app.
        }
    }

    /// Link the current session to the caller's userId once sign-in completes.
    func attach() async {
        guard let sid = sessionId, api.isAuthenticated else { return }
        struct Body: Encodable { let sessionId: String }
        _ = try? await api.request(
            "sessions/attach", method: "POST",
            body: Body(sessionId: sid), authorized: true, retries: 1
        ) as EmptyResponse
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        // Once every 60s while foregrounded is enough — the /events call also
        // bumps lastActiveAt server-side.
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.heartbeat() }
        }
    }

    private func heartbeat() {
        guard let sid = sessionId else { return }
        Task {
            struct Body: Encodable { let sessionId: String }
            _ = try? await api.request(
                "sessions/heartbeat", method: "POST",
                body: Body(sessionId: sid), authorized: api.isAuthenticated, retries: 0
            ) as EmptyResponse
        }
    }

    private func end() {
        guard let sid = sessionId else { return }
        Task {
            // Flush anything queued first so we don't lose the tail of a session.
            await flush(force: true)
            struct Body: Encodable { let sessionId: String }
            _ = try? await api.request(
                "sessions/end", method: "POST",
                body: Body(sessionId: sid), authorized: api.isAuthenticated, retries: 0
            ) as EmptyResponse
        }
    }

    // MARK: - Events

    /// Log a typed event. `name` is a short slug like `listing.view`,
    /// `chat.send`, `visit.request`. `payload` is small JSON — ids, categories,
    /// counts. No free-form text, no PII beyond what the record already has.
    func log(_ name: String, _ payload: [String: Any] = [:]) {
        let evt = PendingEvent(
            name: name,
            payload: payload,
            at: ISO8601DateFormatter().string(from: Date())
        )
        queue.append(evt)
        // Coalesce bursts: cancel any pending flush and start a fresh 2s timer.
        // At 25+ queued events we flush immediately so the batch stays small.
        if queue.count >= 25 {
            Task { await flush() }
        } else {
            scheduleFlush()
        }
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await self?.flush()
        }
    }

    func flush(force: Bool = false) async {
        guard let sid = sessionId else { return }
        guard !queue.isEmpty else { return }
        // Take at most 100 events per POST — the server rejects larger batches.
        let batch = Array(queue.prefix(100))
        struct WireEvent: Encodable {
            let name: String
            let payload: AnyCodableDict
            let at: String
        }
        struct Body: Encodable { let sessionId: String; let events: [WireEvent] }
        let events = batch.map {
            WireEvent(name: $0.name, payload: AnyCodableDict($0.payload), at: $0.at)
        }
        do {
            _ = try await api.request(
                "events", method: "POST",
                body: Body(sessionId: sid, events: events),
                authorized: api.isAuthenticated, retries: force ? 0 : 1
            ) as EmptyResponse
            queue.removeFirst(min(batch.count, queue.count))
        } catch {
            // Keep the queue for the next attempt — but cap at 500 pending so
            // a long offline stretch can't grow unbounded.
            if queue.count > 500 {
                queue.removeFirst(queue.count - 500)
            }
        }
    }

    // MARK: - Lifecycle wiring

    private var observed = false
    private func observeLifecycle() {
        guard !observed else { return }
        observed = true
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.end() } }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.sessionId = nil
                await self?.start()
            }
        }
    }
}

// MARK: - Small helpers

private struct PendingEvent {
    let name: String
    let payload: [String: Any]
    let at: String
}

/// Small JSON payload wrapper — event payloads are typed on the client side
/// as `[String: Any]` for convenience but must serialize as a plain object.
struct AnyCodableDict: Encodable {
    let dict: [String: Any]
    init(_ dict: [String: Any]) { self.dict = dict }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        for (k, v) in dict {
            let key = DynamicKey(stringValue: k)!
            switch v {
            case let s as String:  try c.encode(s, forKey: key)
            case let i as Int:     try c.encode(i, forKey: key)
            case let d as Double:  try c.encode(d, forKey: key)
            case let b as Bool:    try c.encode(b, forKey: key)
            case let arr as [String]: try c.encode(arr, forKey: key)
            case let arr as [Int]:    try c.encode(arr, forKey: key)
            default:               try c.encode(String(describing: v), forKey: key)
            }
        }
    }
    private struct DynamicKey: CodingKey {
        var stringValue: String; var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
        init?(intValue: Int) { self.stringValue = "\(intValue)"; self.intValue = intValue }
    }
}
