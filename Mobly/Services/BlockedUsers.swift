import Foundation
import Combine

/// Locally-stored set of blocked user ids. No server endpoint yet — this is a
/// client-side hide/silence: filters the peer out of the inbox and hides the
/// composer inside their chat thread. Persisted to UserDefaults.
@MainActor
final class BlockedUsers: ObservableObject {
    static let shared = BlockedUsers()
    @Published private(set) var ids: Set<String> = []
    private let key = "chat.blocked.users.v1"

    private init() {
        if let arr = UserDefaults.standard.array(forKey: key) as? [String] {
            ids = Set(arr)
        }
    }

    func isBlocked(_ id: String) -> Bool { ids.contains(id) }

    func block(_ id: String) {
        ids.insert(id); persist()
    }
    func unblock(_ id: String) {
        ids.remove(id); persist()
    }

    /// Wipe on sign-out. The key isn't namespaced by user, so without this the
    /// next account on the device inherits the previous user's block list —
    /// silently hiding conversations they never blocked.
    func clearAll() {
        ids = []
        UserDefaults.standard.removeObject(forKey: key)
    }

    private func persist() {
        UserDefaults.standard.set(Array(ids), forKey: key)
    }
}
