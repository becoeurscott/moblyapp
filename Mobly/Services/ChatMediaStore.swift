import Foundation
import CryptoKit

/// Permanent on-device home for chat photos and voice notes.
///
/// These used to live in `Caches`, which iOS is free to empty whenever the
/// device is short on space. That was survivable while the server still held
/// the file — the app just re-downloaded it. It stopped being survivable once
/// `cleanupChatMedia` started deleting chat media from Cloudinary after
/// `CHAT_MEDIA_RETENTION_DAYS`: past that point the copy on the handset is the
/// only copy in existence, so an eviction destroyed the photo for good and the
/// conversation silently became "média expiré". Worse, it destroyed it on one
/// participant's phone and not the other's, so the same thread disagreed with
/// itself depending on which device iOS had squeezed.
///
/// Application Support is the correct home: it survives storage pressure, it
/// is included in backups (so a restored phone keeps the history), and it is
/// not surfaced to the user as documents they are expected to manage.
///
/// Listing covers and avatars deliberately do NOT come here. Those are always
/// re-downloadable from Cloudinary, so `URLCache` remains right for them and
/// keeping them out stops this directory growing without bound.
enum ChatMediaStore {

    /// `Application Support/ChatMedia`, created on first use.
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("ChatMedia", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: Keys

    /// Filename for a remote URL.
    ///
    /// Hashed rather than using the last path component: Cloudinary public ids
    /// repeat across folders, so two different photos can share a basename and
    /// would otherwise overwrite each other.
    static func fileURL(for remote: URL) -> URL {
        let digest = SHA256.hash(data: Data(remote.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        let ext = remote.pathExtension.isEmpty ? "bin" : remote.pathExtension
        return root.appendingPathComponent("\(name).\(ext)")
    }

    /// Filename for something already keyed by message id (voice notes).
    static func fileURL(id: String, ext: String) -> URL {
        // Message ids are cuid/uuid, so they are filesystem-safe as they are.
        root.appendingPathComponent("\(id).\(ext.isEmpty ? "m4a" : ext)")
    }

    // MARK: Read / write

    static func data(for remote: URL) -> Data? {
        try? Data(contentsOf: fileURL(for: remote))
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Write bytes, replacing anything already there. Silent on failure: a
    /// full disk must not break sending or viewing, it only means this item
    /// has to be fetched again next time.
    @discardableResult
    static func store(_ data: Data, at url: URL) -> Bool {
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func store(_ data: Data, for remote: URL) -> Bool {
        store(data, at: fileURL(for: remote))
    }

    // MARK: Housekeeping

    /// Bytes currently held, for a "stockage" screen.
    static func totalBytes() -> Int64 {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return items.reduce(into: Int64(0)) { total, url in
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// Delete everything. Only ever call this from an explicit user action —
    /// anything older than the server's retention window cannot be recovered.
    static func clear() {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }
        for url in items { try? FileManager.default.removeItem(at: url) }
    }
}
