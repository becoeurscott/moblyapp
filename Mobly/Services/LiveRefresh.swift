import Foundation
import SwiftUI
import UIKit

/// Keeps the app's data current on its own, with no visible sign that it is
/// doing so.
///
/// The rule: **the user never learns a refresh happened.** No spinner, no
/// skeleton, no banner, no scroll jump — content that changed simply eases into
/// its new value (`Motion.content`), and content that didn't change is left
/// completely alone, because re-publishing an identical array still rebuilds
/// every card and that hitch is visible.
///
/// Three triggers, deliberately no more:
///   1. **Foreground** — the moment the app comes back, before the user can
///      read a stale price.
///   2. **Poll** — every `interval` while the app is in front. Paused the
///      instant it backgrounds, so nothing burns a Douala data plan in a pocket.
///   3. **Reconnect** — the network came back; whatever failed silently while
///      offline gets another go.
///
/// Chat is *not* in here: it already receives over a socket, and polling it
/// would fight the socket for the same rows.
@MainActor
final class LiveRefresh: ObservableObject {
    static let shared = LiveRefresh()

    /// 45s: a marketplace where listings change hourly does not need faster,
    /// and a Cameroon data plan should not pay for faster.
    private let interval: TimeInterval = 45

    private var ticker: Task<Void, Never>?
    private var inFlight = false
    private var observers: [NSObjectProtocol] = []

    private init() {}

    /// Called once from the root view.
    func start() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default

        observers.append(nc.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshNow()
                self?.startTicking()
            }
        })

        observers.append(nc.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stopTicking() }
        })

        observers.append(nc.addObserver(
            forName: NetworkMonitor.didReconnect, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        })

        startTicking()
    }

    /// Refresh right now, silently. Safe to call from anywhere (`.task`, a
    /// sheet dismissing, a push arriving).
    func refreshNow() {
        Task { await refresh() }
    }

    // MARK: - Internals

    private func startTicking() {
        stopTicking()
        ticker = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { return }
                await self.refresh()
            }
        }
    }

    private func stopTicking() {
        ticker?.cancel()
        ticker = nil
    }

    private func refresh() async {
        // Offline: skip entirely rather than pile up failing requests. The
        // reconnect observer will fire the catch-up.
        guard NetworkMonitor.shared.isConnected else { return }
        // A slow link means the previous tick is still running; a second one
        // would only queue behind it and land as a double update.
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        await ListingStore.shared.fetch(silent: true)

        guard AuthStore.shared.isSignedIn else { return }
        await UserDataStore.shared.loadAll(silent: true)
        await VisitRequestStore.shared.refresh(silent: true)
    }
}
