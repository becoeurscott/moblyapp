import Foundation
import Combine

/// Per-thread client-side preferences (pin, mute, archive, manually-unread).
///
/// None of these have a server endpoint yet — the backend only stores unread
/// counts and message state — so they live in UserDefaults so they at least
/// survive relaunches on the same device. When the backend grows real
/// endpoints for these, swap the read/write paths without touching callers.
@MainActor
final class ThreadPrefs: ObservableObject {
    static let shared = ThreadPrefs()

    struct Flags: Codable, Equatable {
        var pinned: Bool = false
        var muted: Bool = false
        var archived: Bool = false
        /// User explicitly marked the conversation as unread from the row's
        /// context menu. Cleared the next time they open the thread.
        var manuallyUnread: Bool = false
    }

    @Published private(set) var flags: [String: Flags] = [:]
    /// Thread ids the user has deleted from the inbox. Only hides them from
    /// the list — messages themselves stay on the server.
    @Published private(set) var deleted: Set<String> = []

    private let flagsKey  = "chat.thread.flags.v1"
    private let deletedKey = "chat.thread.deleted.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: flagsKey),
           let decoded = try? JSONDecoder().decode([String: Flags].self, from: data) {
            flags = decoded
        }
        if let arr = UserDefaults.standard.array(forKey: deletedKey) as? [String] {
            deleted = Set(arr)
        }
    }

    func flags(for id: String) -> Flags { flags[id] ?? Flags() }

    func togglePin(_ id: String)     { update(id) { $0.pinned.toggle() } }
    func toggleMute(_ id: String)    { update(id) { $0.muted.toggle() } }
    func toggleArchive(_ id: String) { update(id) { $0.archived.toggle() } }
    func markUnread(_ id: String)    { update(id) { $0.manuallyUnread = true } }
    /// Called from the thread view when the user opens the conversation, so
    /// the manual-unread flag doesn't stick around after the thread is read.
    func clearManualUnread(_ id: String) {
        guard var f = flags[id], f.manuallyUnread else { return }
        f.manuallyUnread = false
        flags[id] = f
        persist()
    }

    func delete(_ id: String) {
        deleted.insert(id)
        UserDefaults.standard.set(Array(deleted), forKey: deletedKey)
        // A previously-deleted thread should not carry stale flags forward
        // if it ever comes back (e.g. new message from the same peer).
        flags.removeValue(forKey: id)
        persist()
    }

    func undelete(_ id: String) {
        deleted.remove(id)
        UserDefaults.standard.set(Array(deleted), forKey: deletedKey)
    }

    /// Wipe on sign-out. Thread ids are server-side and shared between the
    /// two participants, so a flag set by one user applies to the *same*
    /// thread id for the next account on this device — a conversation the
    /// previous user archived or deleted would silently vanish from the new
    /// user's inbox.
    func clearAll() {
        flags = [:]
        deleted = []
        UserDefaults.standard.removeObject(forKey: flagsKey)
        UserDefaults.standard.removeObject(forKey: deletedKey)
    }

    private func update(_ id: String, _ mut: (inout Flags) -> Void) {
        var f = flags[id] ?? Flags()
        mut(&f)
        flags[id] = f
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(flags) else { return }
        UserDefaults.standard.set(data, forKey: flagsKey)
    }
}
