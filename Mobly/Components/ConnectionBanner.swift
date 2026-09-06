import SwiftUI

struct ConnectionBanner: View {
    @ObservedObject private var net = NetworkMonitor.shared

    var body: some View {
        Group {
            if !net.isConnected {
                banner(icon: "wifi.slash", text: "Pas de connexion internet",
                       color: Color(hex: 0xE5484D))
            } else if net.isSlow {
                banner(icon: "tortoise.fill", text: "Connexion lente…",
                       color: Color(hex: 0xFF6B35))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: net.isConnected)
        .animation(.easeInOut(duration: 0.3), value: net.isSlow)
    }

    private func banner(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
            Text(text)
                .font(.moblyBody(12.5, weight: .medium))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color)
    }
}
