import SwiftUI

/// A user's avatar, rendered identically everywhere: their uploaded photo when
/// there is one, otherwise their initial on their identity colour.
///
/// The colour goes through `AvatarPalette` keyed on the **user** id (never a
/// thread or listing id), so the fallback matches the Profile screen.
struct UserAvatar: View {
    let name: String
    let userId: String?
    var avatarUrl: String? = nil
    var avatarColor: String? = nil
    var size: CGFloat = 44

    private var initial: String {
        String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    }

    private var fill: Color {
        AvatarPalette.color(for: userId ?? name, stored: avatarColor)
    }

    var body: some View {
        ZStack {
            Circle().fill(fill)
            Text(initial.isEmpty ? "?" : initial)
                .font(.moblyHeading(size * 0.4))
                .foregroundStyle(.white)
            if let avatarUrl, let url = URL(string: avatarUrl), avatarUrl.hasPrefix("http") {
                // Initials stay underneath so a slow or failed load never
                // leaves an empty or grey circle.
                AvatarPhoto(url: url).id(url)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

extension UserAvatar {
    /// The signed-in user's own avatar, straight from `AuthStore` so an edit
    /// in Edit Profile shows up immediately.
    init(me user: UserDTO?, size: CGFloat = 44) {
        self.init(name: user?.fullName ?? "", userId: user?.id ?? "self",
                  avatarUrl: user?.avatarUrl, avatarColor: user?.avatarColor, size: size)
    }
}

/// Photo layer: renders nothing until the image is actually there.
private struct AvatarPhoto: View {
    let url: URL
    @StateObject private var loader = CachedImageLoader()

    var body: some View {
        Color.clear
            .overlay {
                if let img = loader.image {
                    Image(uiImage: img).resizable().scaledToFill()
                }
            }
            .onAppear { loader.load(url) }
    }
}
