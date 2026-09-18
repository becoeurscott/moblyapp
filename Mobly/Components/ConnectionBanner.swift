import SwiftUI

/// Connection state strip at the top of the app.
///
/// Sits in the layout (a top safe-area inset), not over it, so it pushes the
/// screen down when it slides in and lets it back up when it leaves — an
/// overlay used to hide the top of whatever screen was open. Offline and slow
/// are shown in red with the time of the last successful sync; when the
/// connection comes back it turns green for a moment, then slides away.
struct ConnectionBanner: View {
    @ObservedObject private var net = NetworkMonitor.shared

    /// Last moment the app was known to be online, for "Dernière synchronisation".
    @State private var lastOnline = Date()
    @State private var showRestored = false

    private enum Mode: Equatable { case offline, slow, restored }

    private var mode: Mode? {
        if !net.isConnected { return .offline }
        if showRestored { return .restored }
        if net.isSlow { return .slow }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if let mode {
                content(mode)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
        .clipped()
        .animation(.spring(response: 0.4, dampingFraction: 0.9), value: mode)
        .onChange(of: net.isConnected) { was, now in
            if !now { lastOnline = Date() }
            if now && !was {
                showRestored = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showRestored = false }
            }
        }
    }

    @ViewBuilder
    private func content(_ mode: Mode) -> some View {
        let red = Color(hex: 0xD92D20)
        let green = Color(hex: 0x1F8A5B)
        switch mode {
        case .offline:
            strip(icon: "icloud.slash.fill", title: "Vous n'êtes pas connecté à Internet.",
                  tint: red, background: Color(hex: 0xFDE7E7), showSync: true)
        case .slow:
            strip(icon: "tortoise.fill", title: "Connexion lente…",
                  tint: red, background: Color(hex: 0xFDE7E7), showSync: false)
        case .restored:
            strip(icon: "checkmark.icloud.fill", title: "Connexion rétablie",
                  tint: green, background: Color(hex: 0xE3F6EC), showSync: false)
        }
    }

    private func strip(icon: String, title: String, tint: Color, background: Color,
                       showSync: Bool) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                Text(title).font(.moblyBody(13, weight: .medium))
            }
            .foregroundStyle(tint)
            if showSync {
                (Text("Dernière synchronisation le \(lastOnline.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year())) à ")
                    + Text(lastOnline.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))
                        .fontWeight(.bold))
                    .font(.moblyBody(12))
                    .foregroundStyle(Color(hex: 0x3A3D4A))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(background.ignoresSafeArea(edges: .top))
    }
}
