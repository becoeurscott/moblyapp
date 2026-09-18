import SwiftUI

struct CallView: View {
    let thread: ChatThread
    var isVideo: Bool

    @ObservedObject private var call = CallService.shared
    @StateObject private var camera = CameraPreviewController()

    // Video call UI state.
    @Namespace private var feedSpace
    @State private var localIsMain = false
    @State private var cameraOn = true
    @State private var controlsVisible = true
    @State private var hideTask: DispatchWorkItem?
    @State private var pipCorner: PiPCorner = .topTrailing
    @State private var pipDrag: CGSize = .zero

    enum PiPCorner {
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        var alignment: Alignment {
            switch self {
            case .topLeading: return .topLeading
            case .topTrailing: return .topTrailing
            case .bottomLeading: return .bottomLeading
            case .bottomTrailing: return .bottomTrailing
            }
        }
        var isLeading: Bool { self == .topLeading || self == .bottomLeading }
        var isTop: Bool { self == .topLeading || self == .topTrailing }

        static func make(leading: Bool, top: Bool) -> PiPCorner {
            switch (leading, top) {
            case (true, true): return .topLeading
            case (false, true): return .topTrailing
            case (true, false): return .bottomLeading
            case (false, false): return .bottomTrailing
            }
        }
    }

    private var shouldRunCamera: Bool {
        isVideo && cameraOn && (call.state == .connected || call.state == .outgoing)
    }

    var body: some View {
        Group {
            if isVideo && call.state == .connected {
                videoCallLayout
            } else {
                classicLayout
            }
        }
        .onAppear { if shouldRunCamera { camera.start() } }
        .onDisappear { camera.stop() }
        .onChange(of: shouldRunCamera) { _, run in
            if run { camera.start() } else { camera.stop() }
        }
        .onChange(of: call.state) { _, state in
            if state == .connected && isVideo { scheduleAutoHide() }
        }
    }

    // MARK: - Video call (connected)

    private var videoCallLayout: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Main feed
            Group {
                if localIsMain {
                    localFeed(compact: false)
                        .matchedGeometryEffect(id: "local", in: feedSpace)
                } else {
                    remoteFeed(compact: false)
                        .matchedGeometryEffect(id: "remote", in: feedSpace)
                }
            }
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { toggleControls() }

            // Picture in picture
            pipTile
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: pipCorner.alignment)
                .padding(.horizontal, 16)
                .padding(.top, controlsVisible ? 64 : 12)
                .padding(.bottom, controlsVisible ? 190 : 16)

            if controlsVisible {
                VStack {
                    HStack {
                        minimizeButton
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    Spacer()
                    videoControlPanel
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                }
                .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var pipTile: some View {
        Group {
            if localIsMain {
                remoteFeed(compact: true)
                    .matchedGeometryEffect(id: "remote", in: feedSpace)
            } else {
                localFeed(compact: true)
                    .matchedGeometryEffect(id: "local", in: feedSpace)
            }
        }
        .frame(width: 110, height: 160)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(.white.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .offset(pipDrag)
        .onTapGesture {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { localIsMain.toggle() }
            scheduleAutoHide()
        }
        .gesture(
            DragGesture()
                .onChanged { pipDrag = $0.translation }
                .onEnded { value in
                    let dx = value.predictedEndTranslation.width
                    let dy = value.predictedEndTranslation.height
                    var leading = pipCorner.isLeading
                    var top = pipCorner.isTop
                    if leading && dx > 120 { leading = false } else if !leading && dx < -120 { leading = true }
                    if top && dy > 200 { top = false } else if !top && dy < -200 { top = true }
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        pipCorner = .make(leading: leading, top: top)
                        pipDrag = .zero
                    }
                }
        )
    }

    /// Local camera feed, or the avatar when the camera is off or not allowed.
    @ViewBuilder
    private func localFeed(compact: Bool) -> some View {
        if cameraOn && camera.authorized {
            CameraPreview(session: camera.session)
                .scaleEffect(x: -1, y: 1) // mirror like FaceTime
        } else {
            ZStack {
                Color(hex: 0x1C1C24)
                VStack(spacing: 8) {
                    UserAvatar(me: AuthStore.shared.user, size: compact ? 48 : 110)
                    Image(systemName: "video.slash.fill")
                        .font(.system(size: compact ? 12 : 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
    }

    /// Remote feed placeholder. Swap this for a real remote video view once
    /// CallService transports video.
    @ViewBuilder
    private func remoteFeed(compact: Bool) -> some View {
        ZStack {
            LinearGradient(colors: [thread.color.opacity(0.9), Color(hex: 0x14152A)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            UserAvatar(name: thread.name, userId: thread.peerId ?? thread.id,
                       avatarUrl: thread.avatarUrl, avatarColor: thread.avatarColor,
                       size: compact ? 200 : 520)
                .blur(radius: compact ? 20 : 60)
                .opacity(0.55)
            VStack(spacing: compact ? 6 : 14) {
                UserAvatar(name: thread.name, userId: thread.peerId ?? thread.id,
                           avatarUrl: thread.avatarUrl, avatarColor: thread.avatarColor,
                           size: compact ? 52 : 120)
                if !compact {
                    Text("Vidéo bientôt disponible")
                        .font(.moblyBody(12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .clipped()
    }

    private var videoControlPanel: some View {
        VStack(spacing: 14) {
            VStack(spacing: 2) {
                Text(thread.name)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(call.timeString)
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
            controlRow
        }
        .padding(.top, 16)
        .padding(.bottom, 18)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var controlRow: some View {
        HStack(spacing: 14) {
            panelButton(call.muted ? "mic.slash.fill" : "mic.fill", active: call.muted,
                        label: "Micro") { call.toggleMute() }
            panelButton(call.speaker ? "speaker.wave.2.fill" : "speaker.fill", active: call.speaker,
                        label: "Haut-parleur") { call.toggleSpeaker() }
            if isVideo {
                panelButton(cameraOn ? "video.fill" : "video.slash.fill", active: !cameraOn,
                            label: "Caméra") {
                    withAnimation(.easeInOut(duration: 0.2)) { cameraOn.toggle() }
                }
            }
            Button {
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                call.endCall()
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(Circle().fill(Color(hex: 0xE5484D)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Raccrocher")
            panelButton("ellipsis", active: false, label: "Plus") {}
                .disabled(true)
                .opacity(0.5)
        }
    }

    private var minimizeButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { call.minimized = true }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel("Réduire l'appel")
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.25)) { controlsVisible.toggle() }
        if controlsVisible { scheduleAutoHide() } else { hideTask?.cancel() }
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        let task = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.25)) { controlsVisible = false }
        }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: task)
    }

    // MARK: - Ringing / audio layout

    private var classicLayout: some View {
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
                ZStack {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill").font(.system(size: 11, weight: .semibold))
                        Text("Appel Mobly chiffré")
                            .font(.moblyBody(12, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.7))

                    // Shrink to the top bar and keep using the app.
                    HStack {
                        minimizeButton
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                }
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
                    UserAvatar(name: thread.name, userId: thread.peerId ?? thread.id,
                               avatarUrl: thread.avatarUrl, avatarColor: thread.avatarColor,
                               size: 120)
                        .shadow(color: thread.color.opacity(0.5), radius: 30)
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

                if isVideo && call.state == .outgoing {
                    HStack {
                        Spacer()
                        localFeed(compact: true)
                            .frame(width: 110, height: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                            .padding(.trailing, 20)
                    }
                    .padding(.bottom, 20)
                }

                Group {
                    if call.state == .connected || call.state == .outgoing {
                        controlRow
                            .padding(.vertical, 16)
                            .padding(.horizontal, 16)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    } else {
                        Button {
                            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                            call.endCall()
                        } label: {
                            Image(systemName: "phone.down.fill")
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 68, height: 68)
                                .background(Circle().fill(Color(hex: 0xE5484D)))
                                .shadow(color: Color(hex: 0xE5484D).opacity(0.5), radius: 16, y: 6)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 40)
            }
        }
    }

    private var statusText: String {
        switch call.state {
        case .idle: return ""
        case .outgoing: return isVideo ? "Appel vidéo…" : "Appel en cours…"
        case .incoming: return "Appel entrant…"
        case .connected: return call.timeString
        case .ended: return call.failureMessage ?? "Appel terminé"
        }
    }

    private func panelButton(_ icon: String, active: Bool, label: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(active ? Color(hex: 0x14152A) : .white)
                .frame(width: 54, height: 54)
                .background(Circle().fill(active ? Color.white : Color.white.opacity(0.18)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

#Preview {
    CallView(thread: ChatThread.preview, isVideo: false)
}
