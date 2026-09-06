import Foundation
import SwiftUI

/// Tolerant ISO-8601 parsing.
///
/// The backend emits `2026-09-05T09:00:00.000Z` (JS `toISOString()`), but
/// `ISO8601DateFormatter` rejects fractional seconds unless explicitly told to
/// accept them. Try both shapes so neither format breaks the countdown.
enum MoblyDate {
    private static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return withFractional.date(from: s) ?? plain.date(from: s)
    }
}

/// Owns the app-wide maintenance state.
///
/// Two things drive it:
///  - any API call that comes back `503 MAINTENANCE` flips it on immediately,
///    so a user already deep in the app is stopped at the first request rather
///    than seeing empty screens;
///  - once on, this store polls `GET /maintenance` so the app lets itself back
///    in the moment the window is lifted — no relaunch, no pull-to-refresh.
///
/// It deliberately does NOT poll while the app is healthy. A background poll on
/// every launch would cost a request per session for a state that is almost
/// always "off"; the bootstrap check plus the 503 path cover it.
@MainActor
final class MaintenanceStore: ObservableObject {
    static let shared = MaintenanceStore()

    /// True while the app should be blocked behind the maintenance screen.
    @Published private(set) var isActive = false
    /// Server-supplied copy. Nil falls back to the screen's default French text.
    @Published private(set) var message: String?
    /// When the app is expected back. Nil = indefinite, no countdown shown.
    @Published private(set) var endsAt: Date?
    /// Seconds left, recomputed every tick. Nil when there is no `endsAt`.
    @Published private(set) var remaining: TimeInterval?
    /// True once the countdown has run out but the window is still open — the
    /// screen swaps the timer for "d'un instant à l'autre".
    @Published private(set) var overdue = false
    /// A recheck is in flight (drives the spinner on the "Réessayer" button).
    @Published private(set) var checking = false

    /// Offset between the server clock and this device's, in seconds. Applied
    /// to every countdown so a phone with a wrong clock still shows the right
    /// remaining time.
    private var clockSkew: TimeInterval = 0

    private var ticker: Task<Void, Never>?
    private var poller: Task<Void, Never>?

    private init() {}

    // MARK: - Entry points

    /// Called from `MoblyAPI` when a request is refused with 503 MAINTENANCE.
    func activate(with info: MoblyAPI.MaintenanceInfo?) {
        apply(
            enabled: info?.enabled ?? true,
            message: info?.message,
            endsAtRaw: info?.endsAt,
            serverTimeRaw: info?.serverTime
        )
    }

    /// One-shot check at launch, so a user opening the app during a window sees
    /// the maintenance screen instead of a half-loaded home feed. Silent on
    /// failure: an unreachable server is an offline problem, not a maintenance
    /// one, and must not lock anybody out.
    func checkAtLaunch() async {
        // Debug hook: `MAINTENANCE_DEMO=<seconds>` forces the screen on with a
        // synthetic countdown so it can be screenshotted without opening a real
        // window on the server. `0` = indefinite. Dev-only, like START_AT.
        if let raw = ProcessInfo.processInfo.environment["MAINTENANCE_DEMO"],
           let secs = TimeInterval(raw) {
            let ends = secs > 0
                ? ISO8601DateFormatter().string(from: Date().addingTimeInterval(secs))
                : nil
            apply(enabled: true,
                  message: ProcessInfo.processInfo.environment["MAINTENANCE_MSG"],
                  endsAtRaw: ends,
                  serverTimeRaw: nil)
            return
        }
        await probe()
    }

    /// User tapped "Réessayer".
    func recheck() async {
        guard !checking else { return }
        checking = true
        await probe()
        // A visible beat, otherwise the spinner flashes and the user cannot
        // tell whether anything happened.
        try? await Task.sleep(nanoseconds: 400_000_000)
        checking = false
    }

    // MARK: - Polling

    private func probe() async {
        struct Status: Decodable {
            let enabled: Bool
            let message: String?
            let endsAt: String?
            let serverTime: String?
        }
        do {
            let s: Status = try await MoblyAPI.shared.request("maintenance", retries: 0)
            apply(enabled: s.enabled, message: s.message,
                  endsAtRaw: s.endsAt, serverTimeRaw: s.serverTime)
        } catch {
            // Network failure tells us nothing about the window. Leave the
            // current state alone.
        }
    }

    private func apply(enabled: Bool, message: String?,
                       endsAtRaw: String?, serverTimeRaw: String?) {
        if let serverTime = MoblyDate.parse(serverTimeRaw) {
            clockSkew = serverTime.timeIntervalSinceNow
        }
        self.message = message
        self.endsAt = MoblyDate.parse(endsAtRaw)

        guard enabled else {
            if isActive {
                withAnimation(Motion.standard) { isActive = false }
            }
            stopTimers()
            remaining = nil
            overdue = false
            return
        }

        if !isActive {
            withAnimation(Motion.standard) { isActive = true }
        }
        tick()
        startTimers()
    }

    private func startTimers() {
        if ticker == nil {
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    await self?.tick()
                }
            }
        }
        if poller == nil {
            // Every 15 s: frequent enough that the app reopens promptly when
            // the window is lifted, sparse enough to respect Cameroon data
            // costs on a screen the user may leave open for a long time.
            poller = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    await self?.probe()
                }
            }
        }
    }

    private func stopTimers() {
        ticker?.cancel(); ticker = nil
        poller?.cancel(); poller = nil
    }

    private func tick() {
        guard let endsAt else {
            remaining = nil
            overdue = false
            return
        }
        let left = endsAt.timeIntervalSinceNow - clockSkew
        remaining = max(0, left)
        overdue = left <= 0
    }
}
