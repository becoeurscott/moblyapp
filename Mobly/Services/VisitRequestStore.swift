import Foundation
import SwiftUI

/// Owner-side inbox of visit requests. Lightweight — no on-disk cache.
/// The list is refreshed on view appear and after every action.
@MainActor
final class VisitRequestStore: ObservableObject {
    static let shared = VisitRequestStore()

    @Published private(set) var items: [VisitRequestDTO] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?

    private init() {}

    /// Count of pending requests — drives the dashboard badge.
    var pendingCount: Int {
        items.filter { $0.status == "REQUESTED" }.count
    }

    /// Drop the in-memory inbox on sign-out. These rows carry the visitor's
    /// name and phone number, and the dashboard renders them before its own
    /// `refresh()` completes — so without this the next owner to sign in on
    /// the device briefly sees the previous owner's visit requests.
    func clearAll() {
        items = []
        lastError = nil
    }

    /// `silent` = a background poll: no spinner, no error surfaced, and the
    /// inbox only animates when a request actually appeared or changed state.
    func refresh(silent: Bool = false) async {
        guard MoblyAPI.shared.isAuthenticated else { return }
        if !silent { isLoading = true }
        defer { if !silent { isLoading = false } }
        do {
            let fresh = try await MoblyAPI.shared.ownerVisits()
            if fresh.map({ "\($0.id)\($0.status)" }) != items.map({ "\($0.id)\($0.status)" }) {
                withAnimation(Motion.content) { items = fresh }
            } else {
                items = fresh
            }
            lastError = nil
        } catch let e as MoblyAPI.APIError {
            // A cancelled fetch means the screen went away, not that anything
            // failed — surfacing it would show an error nobody caused.
            if !silent && !e.isCancelled { lastError = e.message }
        } catch {
            if !silent { lastError = error.localizedDescription }
        }
    }

    func update(id: String, status: String? = nil, scheduledAt: Date? = nil) async {
        do {
            let updated = try await MoblyAPI.shared.updateVisit(
                id: id, status: status, scheduledAt: scheduledAt
            )
            if let idx = items.firstIndex(where: { $0.id == id }) {
                items[idx] = updated
            }
            lastError = nil
        } catch let e as MoblyAPI.APIError {
            lastError = e.message
        } catch {
            lastError = error.localizedDescription
        }
    }
}
