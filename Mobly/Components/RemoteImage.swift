import SwiftUI
import UIKit

// MARK: - CDN resizing

extension String {
    /// Airbnb's CDN resizes on the fly via `?im_w=`. Requesting a width close to
    /// the on-screen size cuts payloads ~6x (349 KB → 57 KB at 720px), which is
    /// the difference between usable and not on a Douala mobile connection.
    /// Non-muscache URLs are returned untouched.
    func cdnSized(_ width: Int) -> String {
        guard contains("muscache.com"), !contains("im_w=") else { return self }
        return contains("?") ? "\(self)&im_w=\(width)" : "\(self)?im_w=\(width)"
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

    func load(_ url: URL) {
        guard self.url != url else { return }
        self.url = url
        task?.cancel()
        failed = false

        let request = URLRequest(url: url)
        if let cached = URLCache.shared.cachedResponse(for: request),
           let img = UIImage(data: cached.data) {
            image = img
            return
        }

        image = nil
        task = Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard !Task.isCancelled else { return }
                if let img = UIImage(data: data) {
                    withAnimation(.easeIn(duration: 0.2)) { image = img }
                    let cached = CachedURLResponse(response: response, data: data)
                    URLCache.shared.storeCachedResponse(cached, for: request)
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
                .onAppear { loader.load(url) }
                .onChange(of: source) { _, _ in
                    if let newURL = URL(string: source.cdnSized(width)) {
                        loader.load(newURL)
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
