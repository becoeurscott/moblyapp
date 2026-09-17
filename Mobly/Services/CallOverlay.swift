import SwiftUI
import UIKit
import Combine

/// Hosts every call screen in its own window above the app, so a call survives
/// navigation and can be shrunk to a bar while the user keeps using Mobly.
///
/// A sheet- or cover-based call screen dies with whatever presented it, and a
/// cover presented from under another cover never shows. A separate window
/// sidesteps both: it is full screen while the call is expanded, and shrinks to
/// a strip at the top (with the app pushed down to make room) when minimized.
@MainActor
final class CallOverlay {
    static let shared = CallOverlay()

    private var window: UIWindow?
    private var cancellables = Set<AnyCancellable>()
    /// Extra room given to the app under the bar, on top of the status bar.
    static let barHeight: CGFloat = 32

    func start() {
        guard cancellables.isEmpty else { return }
        let call = CallService.shared
        call.$state.combineLatest(call.$minimized)
            .receive(on: RunLoop.main)
            .sink { [weak self] state, minimized in
                self?.update(active: state != .idle, minimized: minimized)
            }
            .store(in: &cancellables)
    }

    private var appWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0 !== window && $0.windowLevel == .normal }
    }

    private func update(active: Bool, minimized: Bool) {
        guard active else {
            window?.isHidden = true
            window = nil
            setAppInset(0)
            return
        }
        guard let scene = appWindow?.windowScene else { return }
        if window == nil {
            let w = UIWindow(windowScene: scene)
            w.windowLevel = .alert + 1
            w.backgroundColor = .clear
            let host = UIHostingController(rootView: CallOverlayRoot())
            host.view.backgroundColor = .clear
            w.rootViewController = host
            w.isHidden = false
            window = w
        }
        let bounds = scene.screen.bounds
        let top = appWindow?.safeAreaInsets.top ?? 0
        window?.frame = minimized
            ? CGRect(x: 0, y: 0, width: bounds.width, height: top + Self.barHeight)
            : bounds
        setAppInset(minimized ? Self.barHeight : 0)
    }

    private func setAppInset(_ value: CGFloat) {
        guard let root = appWindow?.rootViewController,
              root.additionalSafeAreaInsets.top != value else { return }
        UIView.animate(withDuration: 0.25) {
            root.additionalSafeAreaInsets.top = value
            root.view.layoutIfNeeded()
        }
    }
}

private struct CallOverlayRoot: View {
    @ObservedObject private var call = CallService.shared

    var body: some View {
        Group {
            if call.state == .idle {
                Color.clear
            } else if call.minimized {
                CallMiniBar()
            } else if call.state == .incoming {
                IncomingCallView()
            } else {
                CallView(thread: call.peerThread, isVideo: call.isVideo)
            }
        }
        .preferredColorScheme(.light)
    }
}

/// The green strip shown while a call runs in the background. Tap to return.
private struct CallMiniBar: View {
    @ObservedObject private var call = CallService.shared

    private var status: String {
        switch call.state {
        case .connected: return call.timeString
        case .outgoing: return "Appel en cours…"
        case .ended: return "Appel terminé"
        default: return ""
        }
    }

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { call.minimized = false }
        } label: {
            ZStack(alignment: .bottom) {
                Color(hex: 0x1F8A5B)
                HStack(spacing: 8) {
                    Image(systemName: call.isVideo ? "video.fill" : "phone.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text(call.peerName)
                        .font(.moblyBody(13, weight: .semibold))
                        .lineLimit(1)
                    Text("·").opacity(0.7)
                    Text(status)
                        .font(.moblyBody(13, weight: .medium))
                        .monospacedDigit()
                    Spacer(minLength: 8)
                    Text("Retour à l'appel")
                        .font(.moblyBody(12, weight: .medium))
                        .opacity(0.85)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .opacity(0.85)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: CallOverlay.barHeight)
            }
            .ignoresSafeArea()
        }
        .buttonStyle(.plain)
    }
}
