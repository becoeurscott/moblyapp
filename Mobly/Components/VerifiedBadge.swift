import SwiftUI

/// The one "vérifié" mark for the whole app.
///
/// This exists because four screens each drew their own. The annonce showed a
/// blue `checkmark.seal.fill`, while the inbox row, the chat header and the
/// peer profile each drew a bare checkmark inside a pale circle — so the same
/// guarantee looked like two unrelated things depending on where you met it.
/// Anything marking a verified identity now uses this, and nothing draws its
/// own.
///
/// Blue rather than green on purpose: "vérifié" is a Mobly guarantee about the
/// person, not a status they set for themselves.
struct VerifiedBadge: View {
    var size: CGFloat = 16
    /// Blue everywhere by default. Overridden to white only where the badge
    /// sits on a dark photo, where the blue loses too much contrast to read.
    var tint: Color = .moblyPrimary

    var body: some View {
        Image(systemName: "checkmark.seal.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(tint)
    }
}

/// The same mark sitting on the corner of an avatar, where it needs a plate
/// behind it so the seal's cut-outs don't pick up the photo underneath.
struct VerifiedAvatarBadge: View {
    var size: CGFloat = 26
    var ring: Color = Color(hex: 0xF7F8FA)

    var body: some View {
        ZStack {
            Circle().fill(ring).frame(width: size + 4, height: size + 4)
            Circle().fill(.white).frame(width: size * 0.62, height: size * 0.62)
            VerifiedBadge(size: size)
        }
    }
}
