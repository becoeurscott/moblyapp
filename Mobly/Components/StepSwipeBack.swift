import SwiftUI
import UIKit

/// Swipe from the left edge to go back one step in a flow that changes its
/// steps in place — signup, the onboarding questions, "Devenez propriétaire",
/// the listing wizard. Those aren't navigation pushes, so iOS has no back
/// gesture for them on its own.
///
/// The content follows the finger; past a third of the screen (or on a quick
/// flick) it slides off and `action` runs, otherwise it springs back.
///
/// Inside a screen that closes with a swipe (`swipeToDismiss`), this takes
/// priority while a step is available: the edge swipe goes back one step
/// instead of throwing the whole flow away.
extension View {
    func stepSwipeBack(enabled: Bool, action: @escaping () -> Void) -> some View {
        modifier(StepSwipeBackModifier(enabled: enabled, action: action))
    }
}

private struct StepSwipeBackModifier: ViewModifier {
    var enabled: Bool
    var action: () -> Void

    @State private var dragX: CGFloat = 0

    func body(content: Content) -> some View {
        content
            // The page edge casts a soft shadow while it's pulled aside, as
            // on iOS's own back swipe.
            // One flattened layer, so the shadow follows the page's outline
            // instead of being cast by every card inside it.
            .compositingGroup()
            .shadow(color: .black.opacity(dragX > 0 ? 0.14 : 0), radius: 14, x: -4)
            .offset(x: dragX)
            .background(
                EdgeSwipeInstaller(
                    enabled: enabled,
                    onChange: { dragX = max(0, $0) },
                    onEnd: { commit, width in
                        if commit {
                            withAnimation(.easeOut(duration: 0.18)) { dragX = width }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                                var t = Transaction()
                                t.disablesAnimations = true
                                withTransaction(t) { dragX = 0 }
                                action()
                            }
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) { dragX = 0 }
                        }
                    }
                )
                .allowsHitTesting(false)
            )
    }
}

/// Hosts the edge recognizer. It sits on the window, because a background
/// view never receives the touches that land on the content above it.
private struct EdgeSwipeInstaller: UIViewRepresentable {
    var enabled: Bool
    var onChange: (CGFloat) -> Void
    var onEnd: (_ commit: Bool, _ width: CGFloat) -> Void

    func makeUIView(context: Context) -> EdgeSwipeAnchorView {
        let view = EdgeSwipeAnchorView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: EdgeSwipeAnchorView, context: Context) {
        view.enabled = enabled
        view.onChange = onChange
        view.onEnd = onEnd
    }

    static func dismantleUIView(_ view: EdgeSwipeAnchorView, coordinator: ()) {
        view.uninstall()
    }
}

final class EdgeSwipeAnchorView: UIView, UIGestureRecognizerDelegate {
    var enabled = false
    var onChange: (CGFloat) -> Void = { _ in }
    var onEnd: (Bool, CGFloat) -> Void = { _, _ in }

    private var recognizer: UIScreenEdgePanGestureRecognizer?
    /// Live anchors, so a `swipeToDismiss` screen can tell that a step-back
    /// inside it should win the edge swipe.
    private static let live = NSHashTable<EdgeSwipeAnchorView>.weakObjects()

    /// True when an enabled step-back lives inside `container` and is on the
    /// screen the user is looking at.
    static func claimsEdge(within container: UIView) -> Bool {
        live.allObjects.contains { $0.isActive && $0.isDescendant(of: container) }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        uninstall()
        guard let window else { return }
        let r = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handle))
        r.edges = .left
        r.delegate = self
        window.addGestureRecognizer(r)
        recognizer = r
        Self.live.add(self)
    }

    func uninstall() {
        if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
        recognizer = nil
        Self.live.remove(self)
    }

    /// Enabled, and on the topmost presented screen — a flow left underneath
    /// a cover (e.g. "Devenez propriétaire" under the listing wizard) must not
    /// react to swipes meant for the one on top.
    fileprivate var isActive: Bool {
        guard enabled, let window, !isHidden, alpha > 0.01 else { return false }
        var top = window.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        guard let topView = top?.view else { return false }
        return isDescendant(of: topView)
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === recognizer ? isActive : super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    @objc private func handle(_ g: UIScreenEdgePanGestureRecognizer) {
        guard let window else { return }
        let width = window.bounds.width
        let tx = g.translation(in: window).x
        switch g.state {
        case .changed:
            onChange(tx)
        case .ended:
            let vx = g.velocity(in: window).x
            onEnd(tx > width / 3 || vx > 600, width)
        case .cancelled, .failed:
            onEnd(false, width)
        default: break
        }
    }
}
