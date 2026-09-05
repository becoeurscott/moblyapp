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

    /// Set when a session is ready; presenting this opens the Safari sheet.
    @Published var hostedFlow: HostedFlowLink?

    private let api = MoblyAPI.shared

    /// True once the account carries the badge, from the server.
    @Published private(set) var isVerified = false

    // MARK: - Actions

    /// Ask the backend for a session and hand back the hosted URL to present.
    func start() async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
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
            // A 409 means the badge is already granted — reconcile rather than
            // showing an error for something that is really good news.
            if err.status == 409 {
                await refresh()
            } else {
                errorMessage = err.message
            }
        } catch {
            errorMessage = "Vérification indisponible. Réessayez."
        }
    }

    /// Re-read the status from the server.
    func refresh() async {
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
        } catch {
            // Silent: this runs on screen appear and after the sheet closes,
            // where a transient failure should not raise an alert.
        }
    }

    /// Called when the hosted sheet is dismissed. The webhook usually lands
    /// within a couple of seconds, so poll a few times before giving up and
    /// leaving the user on "en cours de vérification".
    func pollAfterFlow() async {
        for delay in [1.0, 3.0, 6.0] {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await refresh()
            if !status.isOpen { return }
        }
    }
}
