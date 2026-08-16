import SwiftUI

/// Renders a listing's cover — priority: owner-uploaded data → remote URL → bundled asset.
/// Use everywhere a cover is shown so all listing sources look identical.
struct ListingCover: View {
    let listing: Listing
    var contentMode: ContentMode = .fill
    /// Requested CDN width — pass a bigger slot for full-width heroes.
    var width: Int = ImageSlot.card

    var body: some View {
        if let data = listing.customImageData, let ui = UIImage(data: data) {
            Image(uiImage: ui).resizable().aspectRatio(contentMode: contentMode)
        } else if let urlString = listing.coverUrl {
            RemoteImage(source: urlString, width: width,
                        contentMode: contentMode, fallbackAsset: listing.imageName)
        } else {
            Image(listing.imageName).resizable().aspectRatio(contentMode: contentMode)
        }
    }
}
