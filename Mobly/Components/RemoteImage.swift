import SwiftUI

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

// MARK: - Remote image

/// Loads a remote URL at a CDN-appropriate size, showing a shimmer while it
/// arrives and an optional local asset if it fails. Strings that aren't URLs
/// are treated as bundled asset names.
struct RemoteImage: View {
    let source: String
    var width: Int = ImageSlot.card
    var contentMode: ContentMode = .fill
    /// Asset name rendered if the remote load fails.
    var fallbackAsset: String? = nil

    var body: some View {
        if source.hasPrefix("http"), let url = URL(string: source.cdnSized(width)) {
            AsyncImage(url: url, transaction: Transaction(animation: .easeIn(duration: 0.25))) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().aspectRatio(contentMode: contentMode)
                case .failure:
                    if let fallbackAsset {
                        Image(fallbackAsset).resizable().aspectRatio(contentMode: contentMode)
                    } else {
                        Rectangle().fill(Color(hex: 0xEEF0FE))
                            .overlay(Image(systemName: "photo")
                                .font(.system(size: 20))
                                .foregroundStyle(Color(hex: 0xB9BECF)))
                    }
                default:
                    ShimmerPlaceholder()
                }
            }
        } else if source.hasPrefix("file://"), let url = URL(string: source),
                  let data = try? Data(contentsOf: url),
                  let ui = UIImage(data: data) {
            // Owner-uploaded photos live in Caches/mobly_owner_photos as JPGs
            // and are referenced by `file://` URL in Listing.photos. No cache
            // logic needed — the OS caches disk reads for us, and images are
            // typically <500 KB after JPEG compression.
            Image(uiImage: ui).resizable().aspectRatio(contentMode: contentMode)
        } else {
            Image(source).resizable().aspectRatio(contentMode: contentMode)
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
