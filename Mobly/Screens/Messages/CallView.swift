import SwiftUI

struct CallView: View {
    let thread: ChatThread
    var isVideo: Bool
    var onEnd: () -> Void = {}

    @State private var seconds = 0
    @State private var connected = false
    @State private var muted = false
    @State private var speaker = false
    @State private var videoOn = true

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // Background
            if isVideo && videoOn {
                LinearGradient(colors: [Color(hex: 0x1A1A2E), Color(hex: 0x3A4FF0)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            } else {
                LinearGradient(colors: [Color(hex: 0x2A2E45), Color(hex: 0x14152A)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                // Encrypted badge
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.system(size: 11, weight: .semibold))
                    Text("Appel Mobly chiffré")
                        .font(.moblyBody(12, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.7))
                .padding(.top, 60)

                Spacer()

                // Avatar + name + status
                ZStack {
                    Circle().fill(thread.color).frame(width: 120, height: 120)
                        .shadow(color: thread.color.opacity(0.5), radius: 30)
                    Text(thread.initial).font(.moblyHeading(48)).foregroundStyle(.white)
                }
                .scaleEffect(connected ? 1 : 1.05)
                .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: connected)

                Text(thread.name)
                    .font(.moblyHeading(26)).foregroundStyle(.white)
                    .padding(.top, 22)
                Text(connected ? timeString(seconds) : (isVideo ? "Appel vidéo…" : "Appel en cours…"))
                    .font(.moblyBody(14)).foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 6)

                Spacer()

                // Small self preview (video)
                if isVideo && videoOn {
                    HStack {
                        Spacer()
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.white.opacity(0.12))
                            .frame(width: 90, height: 130)
                            .overlay(Image(systemName: "person.fill")
                                .font(.system(size: 30)).foregroundStyle(.white.opacity(0.5)))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.2), lineWidth: 1))
                            .padding(.trailing, 20)
                    }
                    .padding(.bottom, 20)
                }

                // Controls
                HStack(spacing: 22) {
                    controlButton(muted ? "mic.slash.fill" : "mic.fill", active: muted) { muted.toggle() }
                    if isVideo {
                        controlButton(videoOn ? "video.fill" : "video.slash.fill", active: !videoOn) { videoOn.toggle() }
                    } else {
                        controlButton(speaker ? "speaker.wave.2.fill" : "speaker.fill", active: speaker) { speaker.toggle() }
                    }
                    controlButton("plus.message.fill", active: false) {}
                }
                .padding(.bottom, 26)

                // End call
                Button {
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                    onEnd()
                } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 68, height: 68)
                        .background(Circle().fill(Color(hex: 0xE5484D)))
                        .shadow(color: Color(hex: 0xE5484D).opacity(0.5), radius: 16, y: 6)
                }
                .padding(.bottom, 50)
            }
        }
        .onReceive(timer) { _ in if connected { seconds += 1 } }
        .onAppear {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                withAnimation { connected = true }
            }
        }
    }

    private func controlButton(_ icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(active ? Color(hex: 0x14152A) : .white)
                .frame(width: 62, height: 62)
                .background(Circle().fill(active ? .white : Color.white.opacity(0.18)))
        }
        .buttonStyle(.plain)
    }

    private func timeString(_ s: Int) -> String {
        String(format: "%02d:%02d", s / 60, s % 60)
    }
}

#Preview {
    CallView(thread: ChatThread.preview, isVideo: false)
}
