import Foundation
import Combine

/// Emoji reactions on chat messages, kept on the device.
///
/// There is no reactions table on the server yet, so a reaction lives in
/// the user's own storage: it survives relaunches and shows on the bubble
/// every time the thread opens, but the other person does not see it. When
/// the server grows reactions this store becomes the local cache.
@MainActor
final class ReactionStore: ObservableObject {
    static let shared = ReactionStore()

    /// messageId → emoji
    @Published private(set) var reactions: [String: String] = [:]

    private let key = "chat.reactions.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            reactions = saved
        }
    }

    func reaction(for messageId: String) -> String? { reactions[messageId] }

    /// Tapping the same emoji again removes it, like WhatsApp.
    func toggle(_ emoji: String, on messageId: String) {
        if reactions[messageId] == emoji {
            reactions[messageId] = nil
        } else {
            reactions[messageId] = emoji
        }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(reactions) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
