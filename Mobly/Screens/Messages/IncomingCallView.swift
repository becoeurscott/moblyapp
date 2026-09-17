import SwiftUI

struct IncomingCallView: View {
    @ObservedObject private var call = CallService.shared
    @State private var pulse = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x1A1A2E), Color(hex: 0x2A2E45)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(Color.moblyPrimary.opacity(0.15))
                        .frame(width: 160, height: 160)
                        .scaleEffect(pulse ? 1.15 : 1)
                        .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true),
                                   value: pulse)
                    UserAvatar(name: call.peerName,
                               userId: call.peerId.isEmpty ? nil : call.peerId,
                               avatarUrl: call.peerThread.avatarUrl,
                               avatarColor: call.peerThread.avatarColor,
                               size: 120)
                        .shadow(color: Color.moblyPrimary.opacity(0.5), radius: 30)
                }

                Text(call.peerName)
                    .font(.moblyHeading(26)).foregroundStyle(.white)
                    .padding(.top, 24)

                Text(call.isVideo ? "Appel vidéo entrant…" : "Appel vocal entrant…")
                    .font(.moblyBody(14)).foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 6)

                Spacer()

                HStack(spacing: 60) {
                    Button {
                        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                        call.rejectCall()
                    } label: {
                        VStack(spacing: 10) {
                            Image(systemName: "phone.down.fill")
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 68, height: 68)
                                .background(Circle().fill(Color(hex: 0xE5484D)))
                            Text("Refuser").font(.moblyBody(12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }

                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        call.acceptCall()
                    } label: {
                        VStack(spacing: 10) {
                            Image(systemName: "phone.fill")
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 68, height: 68)
                                .background(Circle().fill(Color(hex: 0x25D366)))
                            Text("Accepter").font(.moblyBody(12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
                .padding(.bottom, 80)
            }
        }
        .onAppear { pulse = true }
        .onChange(of: call.state) { _, newState in
            if newState == .idle || newState == .connected || newState == .ended {
                // Dismiss handled by the binding in MainTabView
            }
        }
    }
}

#Preview {
    IncomingCallView()
}
