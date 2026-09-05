import SwiftUI

struct CallView: View {
    let thread: ChatThread
    var isVideo: Bool
    var onEnd: () -> Void = {}

    @ObservedObject private var call = CallService.shared

    var body: some View {
        ZStack {
            if isVideo {
                LinearGradient(colors: [Color(hex: 0x1A1A2E), Color(hex: 0x3A4FF0)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            } else {
                LinearGradient(colors: [Color(hex: 0x2A2E45), Color(hex: 0x14152A)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.system(size: 11, weight: .semibold))
                    Text("Appel Mobly chiffré")
                        .font(.moblyBody(12, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.7))
                .padding(.top, 60)

                Spacer()

                ZStack {
                    if call.state == .outgoing || call.state == .incoming {
                        Circle().fill(thread.color.opacity(0.15))
                            .frame(width: 160, height: 160)
                            .scaleEffect(call.state == .outgoing ? 1.3 : 1)
                            .opacity(call.state == .outgoing ? 0 : 0.5)
                            .animation(.easeOut(duration: 1.5).repeatForever(autoreverses: false),
                                       value: call.state == .outgoing)
                        Circle().fill(thread.color.opacity(0.25))
                            .frame(width: 145, height: 145)
                            .scaleEffect(call.state == .outgoing ? 1.15 : 1)
                            .opacity(call.state == .outgoing ? 0.2 : 0.6)
                            .animation(.easeOut(duration: 1.5).repeatForever(autoreverses: false).delay(0.3),
                                       value: call.state == .outgoing)
                    }
                    Circle().fill(thread.color).frame(width: 120, height: 120)
                        .shadow(color: thread.color.opacity(0.5), radius: 30)
                    Text(thread.initial).font(.moblyHeading(48)).foregroundStyle(.white)
                }
                .scaleEffect(call.state == .outgoing ? 1.05 : 1)
                .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                           value: call.state == .outgoing)

                Text(thread.name)
                    .font(.moblyHeading(26)).foregroundStyle(.white)
                    .padding(.top, 22)
                Text(statusText)
                    .font(.moblyBody(14)).foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 6)

                Spacer()

                if isVideo {
                    HStack {
                        Spacer()
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.white.opacity(0.12))
                            .frame(width: 90, height: 130)
                            .overlay(Image(systemName: "person.fill")
                                .font(.system(size: 30)).foregroundStyle(.white.opacity(0.5)))
                            .overlay(RoundedRectangle(cornerRadius: 16)
                                .stroke(.white.opacity(0.2), lineWidth: 1))
                            .padding(.trailing, 20)
                    }
                    .padding(.bottom, 20)
                }

                if call.state == .connected || call.state == .outgoing {
                    HStack(spacing: 22) {
                        controlButton(call.muted ? "mic.slash.fill" : "mic.fill",
                                      active: call.muted) { call.toggleMute() }
                        if isVideo {
                            controlButton("video.fill", active: false) {}
                        } else {
                            controlButton(call.speaker ? "speaker.wave.2.fill" : "speaker.fill",
                                          active: call.speaker) { call.toggleSpeaker() }
                        }
                        controlButton("plus.message.fill", active: false) {}
                    }
                    .padding(.bottom, 26)
                }

                Button {
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                    call.endCall()
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
        .onAppear {
            if call.state == .idle {
                call.startCall(thread: thread, isVideo: isVideo)
            }
        }
        .onChange(of: call.state) { _, newState in
            if newState == .idle { onEnd() }
        }
    }

    private var statusText: String {
        switch call.state {
        case .idle: return ""
        case .outgoing: return isVideo ? "Appel vidéo…" : "Appel en cours…"
        case .incoming: return "Appel entrant…"
        case .connected: return call.timeString
        case .ended: return "Appel terminé"
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
}

#Preview {
    CallView(thread: ChatThread.preview, isVideo: false)
}
