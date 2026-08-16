import Foundation
import UIKit

/// Where owner-uploaded photos are written on disk so the gallery pipeline
/// (`RemoteImage(source:)` → `AsyncImage` / `UIImage(contentsOfFile:)`) can
/// load them the same way it loads remote URLs.
///
/// - Photos go to `Caches/mobly_owner_photos/<listingId>/<index>.jpg`
/// - Not in `Documents/` on purpose: these images are trivially regeneratable
///   from the source Data (which lives on `Listing.customPhotos` until we
///   ship the real Cloudinary upload), so they belong in Caches — the OS can
///   evict them under storage pressure without losing user data.
/// - Files aren't versioned or hashed. On re-publish of the same listing id
///   we simply overwrite; on a brand-new listing id we write fresh.
enum OwnerPhotoStore {
    /// Root directory. Created lazily.
    private static let root: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("mobly_owner_photos", isDirectory: true)
    }()

    /// Persist `photos` (in the order they were passed) and return their file
    /// URLs. Silent on failure — the caller keeps the in-memory `Data` on
    /// `Listing.customPhotos` regardless, so worst case the gallery falls
    /// back to the cover-only render.
    @discardableResult
    static func save(_ photos: [Data], id: String) -> [URL] {
        guard !photos.isEmpty else { return [] }
        let dir = root.appendingPathComponent(id, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return []
        }
        var urls: [URL] = []
        for (i, data) in photos.enumerated() {
            let jpeg = normalizeToJPEG(data) ?? data
            let file = dir.appendingPathComponent("\(i).jpg")
            do {
                try jpeg.write(to: file, options: .atomic)
                urls.append(file)
            } catch {
                continue
            }
        }
        return urls
    }

    /// Wipe the on-disk copy for a listing. Used by `remove(_:)` on the
    /// dashboard so evicted listings don't leave orphan bytes behind.
    static func clear(id: String) {
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    /// Re-encode as JPEG at ~0.85 quality. The picker hands us HEIC/PNG/RAW
    /// blobs of wildly varying sizes; normalising up-front keeps disk usage
    /// predictable and playback smooth.
    private static func normalizeToJPEG(_ data: Data) -> Data? {
        guard let ui = UIImage(data: data) else { return nil }
        return ui.jpegData(compressionQuality: 0.85)
    }
}
