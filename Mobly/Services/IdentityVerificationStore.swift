import Foundation
import SwiftUI

/// Drives the "badge vérifié" flow (Didit hosted KYC).
///
/// The phone never handles the ID photos: we ask the backend for a one-shot
/// hosted URL, open it in a Safari sheet, and poll for the outcome when the
/// sheet closes. The decision itself arrives on the backend by webhook, so the
/// poll is only there to refresh the UI promptly.
@MainActor
final class IdentityVerificationStore: ObservableObject {
    static let shared = IdentityVerificationStore()

    enum Status: String {
        case none = "NONE"
        case pending = "PENDING"
        case inReview = "IN_REVIEW"
        case approved = "APPROVED"
        case declined = "DECLINED"
        case abandoned = "ABANDONED"

        /// A check is running — show the amber "en cours" state, not a CTA.
        var isOpen: Bool { self == .pending || self == .inReview }
    }

    @Published private(set) var status: Status = .none
    @Published private(set) var isBusy = false
    @Published private(set) var reason: String?
    @Published var errorMessage: String?

    /// The backend reports the service as not configured (503 / INTERNAL).
    @Published private(set) var unavailable = false

    /// The hosted sheet was closed with the check still open and polling never
    /// resolved it — i.e. the user abandoned the flow (or the provider is slow).
    /// Without this the screen sat on a spinner forever with the start button
    /// disabled, and there was no way back into the flow.
    @Published private(set) var incomplete = false

    /// A user-initiated status re-check is running.
    @Published private(set) var isRefreshing = false

    /// Seconds left to resume the SAME provider session. Past zero, starting
    /// again mints a new one, so the screen warns before it lapses.
    /// Nil when nothing is open.
    @Published private(set) var resumeSecondsLeft: TimeInterval?

    /// The resume window has lapsed on an unfinished check.
    var resumeExpired: Bool { incomplete && (resumeSecondsLeft ?? 1) <= 0 }

    /// Set when a session is ready; presenting this opens the Safari sheet.
    @Published var hostedFlow: HostedFlowLink?

    private let api = MoblyAPI.shared

    /// True only for the few seconds right after the hosted sheet closes, while
    /// we wait for the webhook. Without it a check would be branded "non
    /// terminée" one second after the user finished it.
    private var isPollingAfterFlow = false

    /// Absolute deadline, plus the server/device clock offset it is measured
    /// against so a wrong device clock cannot skew the countdown.
    private var resumeDeadline: Date?
    private var clockSkew: TimeInterval = 0
    private var ticker: Task<Void, Never>?

    /// True once the account carries the badge, from the server.
    @Published private(set) var isVerified = false

    // MARK: - Account lifecycle

    /// Wipe every trace of the previous account's check.
    ///
    /// This store is a singleton holding one user's KYC state, and none of it
    /// is namespaced by user id. Without this, signing out and signing in as
    /// someone else on the same handset — routine in this market — left the
    /// new account looking at the old one's verification:
    ///
    ///   * a leftover `isVerified = true` hides the "Commencer" button
    ///     entirely (`if !store.isVerified { startButton }`), so the second
    ///     account simply cannot start a check;
    ///   * a leftover PENDING shows "reprendre" with the previous user's
    ///     countdown, and `hostedFlow` still holds their one-shot provider
    ///     URL — a link into someone else's identity flow.
    ///
    /// Called from `AuthStore` on sign-out and whenever a session ends.
    func clear() {
        stopTicker()
        status = .none
        isVerified = false
        isBusy = false
        isRefreshing = false
        reason = nil
        errorMessage = nil
        unavailable = false
        incomplete = false
        hostedFlow = nil
        resumeDeadline = nil
        resumeSecondsLeft = nil
        clockSkew = 0
        isPollingAfterFlow = false
    }

    // MARK: - Actions

    /// Ask the backend for a session and hand back the hosted URL to present.
    func start() async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        incomplete = false
        defer { isBusy = false }

        do {
            let session = try await api.startIdentityVerification()
            guard let url = URL(string: session.url) else {
                errorMessage = "Lien de vérification invalide."
                return
            }
            status = .pending
            hostedFlow = HostedFlowLink(url: url)
        } catch let err as MoblyAPI.APIError {
            if err.status == 409 {
                // "Votre identité est déjà vérifiée" — the only 409 this route
                // raises. Refreshing alone left the button looking broken: the
                // user taps, nothing visibly happens, and they tap again (the
                // server logs show exactly that, right up to the rate limit).
                // Re-read the truth AND say what happened.
                await refresh()
                if !isVerified { errorMessage = err.message }
            } else if err.status == 503 || err.code == .internalError {
                unavailable = true
            } else {
                errorMessage = err.message
            }
        } catch {
            errorMessage = "Vérification indisponible. Réessayez."
        }
    }

    /// Re-read the status from the server.
    func refresh(surfaceErrors: Bool = false) async {
        do {
            let dto = try await api.identityVerificationStatus()
            status = Status(rawValue: dto.status) ?? .none
            reason = dto.reason

            // The Profil identity card reads `AuthStore.user.identityVerified`,
            // so the badge would stay red until the next launch unless the
            // cached user is refetched the moment the check passes.
            let justVerified = dto.identityVerified && !isVerified
            isVerified = dto.identityVerified
            if justVerified { await AuthStore.shared.bootstrap() }

            // PENDING means a session exists that the user never carried to the
            // end — Didit only leaves it here while the flow is unfinished.
            // Deriving it from the status (rather than from a flag set once,
            // in-session, by pollAfterFlow) is what lets someone come back
            // hours later and still be offered a resume instead of a spinner.
            // IN_REVIEW is different: that one really is being decided, so it
            // keeps its progress indicator.
            if status == .pending, !isPollingAfterFlow, !isBusy {
                incomplete = true
            } else if !status.isOpen {
                incomplete = false
            }

            if let serverTime = MoblyDate.parse(dto.serverTime) {
                clockSkew = serverTime.timeIntervalSinceNow
            }
            resumeDeadline = MoblyDate.parse(dto.resumableUntil)
            tick()
            if status.isOpen { startTicker() } else { stopTicker() }
        } catch let err as MoblyAPI.APIError {
            // Silent on the automatic paths (screen appear, post-sheet polling),
            // where a transient failure should not raise an alert. Loud when the
            // user asked, otherwise "Actualiser" looks like it does nothing.
            if surfaceErrors {
                errorMessage = err.code == .offline
                    ? "Pas de connexion. Vérifiez votre réseau."
                    : err.message
            }
        } catch {
            if surfaceErrors { errorMessage = "Impossible de récupérer le statut. Réessayez." }
        }
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await self?.tick()
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel(); ticker = nil
        resumeSecondsLeft = nil
    }

    private func tick() {
        guard let deadline = resumeDeadline else {
            resumeSecondsLeft = nil
            return
        }
        resumeSecondsLeft = max(0, deadline.timeIntervalSinceNow - clockSkew)
    }

    /// "Actualiser" — user asked for the current status.
    func recheck() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        await refresh(surfaceErrors: true)
        // Resolved in the meantime: drop the stalled state so the screen stops
        // offering to resume a check that is finished.
        if !status.isOpen { incomplete = false }
        try? await Task.sleep(nanoseconds: 300_000_000)
        isRefreshing = false
    }

    /// Called when the hosted sheet is dismissed. The webhook usually lands
    /// within a couple of seconds, so poll a few times before giving up and
    /// leaving the user on "en cours de vérification".
    func pollAfterFlow() async {
        isPollingAfterFlow = true
        defer { isPollingAfterFlow = false }
        for delay in [1.0, 3.0, 6.0] {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await refresh()
            if !status.isOpen {
                incomplete = false
                return
            }
        }
        // Still open after ~10s. Either the user backed out of the provider's
        // flow or the decision is genuinely slow; both are indistinguishable
        // from here, so say so honestly and let them resume. Resuming is cheap:
        // the server hands back the same in-flight session rather than minting
        // (and billing) a new one.
        incomplete = true
    }
}
