import SwiftUI
import UIKit
import ImageIO

// MARK: - CDN resizing

extension String {
    /// Airbnb's CDN resizes on the fly via `?im_w=`. Requesting a width close to
    /// the on-screen size cuts payloads ~6x (349 KB → 57 KB at 720px), which is
    /// the difference between usable and not on a Douala mobile connection.
    ///
    /// Owner photos live on Cloudinary, which resizes through a path segment.
    /// They used to be fetched as the 12-megapixel camera original — several
    /// MB per card, decoded at full size.
    /// Other URLs are returned untouched.
    func cdnSized(_ width: Int) -> String {
        if contains("muscache.com") {
            guard !contains("im_w=") else { return self }
            return contains("?") ? "\(self)&im_w=\(width)" : "\(self)?im_w=\(width)"
        }
        if contains("res.cloudinary.com"), contains("/image/upload/"),
           !contains("/upload/c_"), !contains("/upload/w_") {
            return replacingOccurrences(of: "/image/upload/",
                                        with: "/image/upload/c_limit,w_\(width),q_auto/")
        }
        return self
    }
}

/// On-screen slot widths, used to pick a CDN size. Values are generous enough
/// for @3x without pulling the full-resolution original.
enum ImageSlot {
    static let thumb = 240     // 84pt photo-strip squares
    static let card = 480      // recommended / similar cards
    static let hero = 960      // full-width hero + gallery
    static let full = 1440     // pinch-zoom viewer
}

// MARK: - Shimmer placeholder

/// Animated placeholder shown while a remote image loads. A moving highlight
/// reads as "loading" far better than a flat grey block.
struct ShimmerPlaceholder: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            Rectangle()
                .fill(Color(hex: 0xEEF0FE))
                .overlay(
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.55), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: max(w, 1) * 0.6)
                    .offset(x: phase * max(w, 1) * 1.6)
                )
                .clipped()
        }
        .onAppear {
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }
}

// MARK: - Decoding

/// Decoded images, keyed by URL. A hit paints on the first frame with no
/// shimmer; anything else is decoded off the main thread.
private let decodedImages: NSCache<NSURL, UIImage> = {
    let c = NSCache<NSURL, UIImage>()
    c.totalCostLimit = 80 * 1024 * 1024
    return c
}()

/// Decode `data` downsampled to `maxPixel` and force the bitmap now, so the
/// cost lands on a background thread instead of on the main thread at first
/// draw — where a full-size decode per card is what made scrolling and taps lag.
private func decodeForDisplay(_ data: Data, maxPixel: Int) -> UIImage? {
    let options = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
    let thumbOptions = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ] as CFDictionary
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions) else {
        return UIImage(data: data)?.preparingForDisplay()
    }
    return UIImage(cgImage: cg)
}

private func cacheCost(_ image: UIImage) -> Int {
    guard let cg = image.cgImage else { return 1 }
    return cg.bytesPerRow * cg.height
}

// MARK: - Cached image loader

/// Loads images checking URLCache synchronously first, so cached images render
/// on the first frame with no shimmer flash. Only shows the shimmer when the
/// image is genuinely being fetched from the network.
@MainActor
final class CachedImageLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var failed = false

    private var url: URL?
    private var task: Task<Void, Never>?

    /// - Parameter persistent: keep the bytes in `ChatMediaStore` (Application
    ///   Support) instead of `URLCache`. Chat photos pass true because the
    ///   server deletes chat media after its retention window, which makes the
    ///   handset copy the only one left — an iOS cache eviction would destroy
    ///   it permanently. Listing covers and avatars pass false: they can always
    ///   be re-fetched, so caching them is correct and keeps the permanent
    ///   directory from growing without bound.
    /// - Parameter maxPixel: longest side to decode at. Bigger than the slot
    ///   only wastes memory and decode time.
    func load(_ url: URL, persistent: Bool = false, maxPixel: Int = 1600) {
        guard self.url != url else { return }
        self.url = url
        task?.cancel()
        failed = false

        if let hit = decodedImages.object(forKey: url as NSURL) {
            image = hit
            return
        }

        image = nil
        task = Task {
            // Disk reads and decoding happen off the main thread; only the
            // finished bitmap comes back.
            let cached: UIImage? = await Task.detached(priority: .userInitiated) {
                let data: Data? = persistent
                    ? ChatMediaStore.data(for: url)
                    : URLCache.shared.cachedResponse(for: URLRequest(url: url))?.data
                return data.flatMap { decodeForDisplay($0, maxPixel: maxPixel) }
            }.value
            guard !Task.isCancelled else { return }
            if let cached {
                decodedImages.setObject(cached, forKey: url as NSURL, cost: cacheCost(cached))
                image = cached
                return
            }
            do {
                let request = URLRequest(url: url)
                let (data, response) = try await URLSession.shared.data(for: request)
                guard !Task.isCancelled else { return }
                let img = await Task.detached(priority: .userInitiated) {
                    decodeForDisplay(data, maxPixel: maxPixel)
                }.value
                guard !Task.isCancelled else { return }
                if let img {
                    decodedImages.setObject(img, forKey: url as NSURL, cost: cacheCost(img))
                    withAnimation(Motion.instant) { image = img }
                    if persistent {
                        ChatMediaStore.store(data, for: url)
                    } else {
                        let cached = CachedURLResponse(response: response, data: data)
                        URLCache.shared.storeCachedResponse(cached, for: request)
                    }
                } else {
                    failed = true
                }
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
    }
}

// MARK: - Remote image

/// Loads a remote URL at a CDN-appropriate size, showing a shimmer only when
/// the image is not in the disk cache. Cached images paint on the first frame.
struct RemoteImage: View {
    let source: String
    var width: Int = ImageSlot.card
    var contentMode: ContentMode = .fill
    var fallbackAsset: String? = nil

    @StateObject private var loader = CachedImageLoader()

    var body: some View {
        if source.hasPrefix("http"), let url = URL(string: source.cdnSized(width)) {
            content
                .onAppear { loader.load(url, maxPixel: width) }
                .onChange(of: source) { _, _ in
                    if let newURL = URL(string: source.cdnSized(width)) {
                        loader.load(newURL, maxPixel: width)
                    }
                }
        } else if source.hasPrefix("file://"), let url = URL(string: source),
                  let data = try? Data(contentsOf: url),
                  let ui = UIImage(data: data) {
            Image(uiImage: ui).resizable().aspectRatio(contentMode: contentMode)
        } else {
            Image(source).resizable().aspectRatio(contentMode: contentMode)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let img = loader.image {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: contentMode)
        } else if loader.failed {
            if let fallbackAsset {
                Image(fallbackAsset).resizable().aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(Color(hex: 0xEEF0FE))
                    .overlay(Image(systemName: "photo")
                        .font(.system(size: 20))
                        .foregroundStyle(Color(hex: 0xB9BECF)))
            }
        } else {
            ShimmerPlaceholder()
        }
    }
}

// MARK: - Image cache

enum MoblyImageCache {
    /// AsyncImage goes through URLSession.shared, which honours the shared
    /// URLCache. The default disk cache is far too small for photo grids, so
    /// images get re-downloaded on every launch — costly on metered data.
    static func configure() {
        URLCache.shared = URLCache(
            memoryCapacity: 64 * 1024 * 1024,    // 64 MB
            diskCapacity: 512 * 1024 * 1024,     // 512 MB
            diskPath: "mobly_images"
        )
        purgeLegacyAPIResponses()
    }

    /// Builds before the API session opted out of HTTP caching stored
    /// authenticated JSON in this same cache, keyed by URL only — so a handset
    /// that has already been through a sign-out still holds another account's
    /// `/verification/me`, `/favorites` and friends on disk. There is no way to
    /// evict by prefix, so this drops the cache wholesale, exactly once. The
    /// cost is one round of image re-downloads; the alternative is leaving one
    /// user's data answerable to the next.
    private static func purgeLegacyAPIResponses() {
        let key = "urlCachePurgedForAPILeak_v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        URLCache.shared.removeAllCachedResponses()
        UserDefaults.standard.set(true, forKey: key)
    }
}

// MARK: - Prefetch

enum ImagePrefetch {
    /// Warm URLCache with a list of image URLs in the background. Returns
    /// immediately; the downloads run at utility priority.
    static func warm(_ urls: [String], width: Int = ImageSlot.hero) {
        let targets = urls.prefix(6).compactMap { URL(string: $0.cdnSized(width)) }
        guard !targets.isEmpty else { return }
        Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                for url in targets {
                    group.addTask {
                        let req = URLRequest(url: url)
                        guard URLCache.shared.cachedResponse(for: req) == nil else { return }
                        _ = try? await URLSession.shared.data(for: req)
                    }
                }
            }
        }
    }
}
