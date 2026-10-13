import SwiftUI
import UIKit

/// Wraps any full-screen-cover content and adds interactive dismiss gestures:
/// left-edge swipe (like navigation back) and top-down swipe (since covers
/// slide up).
///
/// The page tracks the finger with the previous screen visible behind it, and
/// on release keeps going the way the finger went, then the cover is removed
/// without an animation of its own. Handing the dismiss to SwiftUI's default
/// animation instead snapped the page back to full screen and then dropped it
/// downward — even after a sideways swipe.
struct SwipeToDismissContainer<Content: View>: UIViewControllerRepresentable {
    let onDismiss: () -> Void
    var ignoreTopSafeArea: Bool = false
    var allowDownSwipe: Bool = true
    @ViewBuilder let content: () -> Content

    func makeUIViewController(context: Context) -> SwipeDismissHostController<Content> {
        let vc = SwipeDismissHostController(rootView: content(), onDismiss: onDismiss)
        vc.ignoreTopSafeArea = ignoreTopSafeArea
        vc.allowDownSwipe = allowDownSwipe
        return vc
    }

    func updateUIViewController(_ vc: SwipeDismissHostController<Content>, context: Context) {
        vc.updateContent(content())
        vc.onDismiss = onDismiss
        vc.allowDownSwipe = allowDownSwipe
    }
}

final class SwipeDismissHostController<Content: View>: UIViewController,
    UIGestureRecognizerDelegate {
    private let hostingController: UIHostingController<Content>
    var onDismiss: () -> Void
    var ignoreTopSafeArea = false
    var allowDownSwipe = true
    private var edgeGesture: UIScreenEdgePanGestureRecognizer!
    private var downGesture: UIPanGestureRecognizer!
    private var isDismissing = false
    /// The screen under this cover, captured just before the cover appeared.
    /// A full-screen presentation takes the presenter out of the window, so
    /// without this the drag would reveal an empty background.
    private var backdrop: UIView?
    private let backdropDim = UIView()

    init(rootView: Content, onDismiss: @escaping () -> Void) {
        self.hostingController = UIHostingController(rootView: rootView)
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func updateContent(_ rootView: Content) {
        hostingController.rootView = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        addChild(hostingController)
        hostingController.view.backgroundColor = .clear
        if ignoreTopSafeArea {
            hostingController.safeAreaRegions = .keyboard
        }
        view.addSubview(hostingController.view)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        hostingController.didMove(toParent: self)

        edgeGesture = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdge))
        edgeGesture.edges = .left
        edgeGesture.delegate = self
        view.addGestureRecognizer(edgeGesture)

        downGesture = UIPanGestureRecognizer(target: self, action: #selector(handleDown))
        downGesture.delegate = self
        view.addGestureRecognizer(downGesture)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The presenter is still on screen at this point (the cover hasn't
        // slid in yet), so the window shows exactly what lies underneath.
        // The cover itself isn't in a window yet; the presenter's window is.
        if backdrop == nil, !isBeingDismissedChain,
           let window = presenterWindow,
           let snap = window.snapshotView(afterScreenUpdates: false) {
            backdrop = snap
        }
    }

    /// True while this cover (or one it sits in) is going away — no point
    /// capturing then.
    private var isBeingDismissedChain: Bool {
        var vc: UIViewController? = self
        while let c = vc {
            if c.isBeingDismissed { return true }
            vc = c.parent
        }
        return false
    }

    private var presenterWindow: UIWindow? {
        var vc: UIViewController = self
        while let p = vc.parent { vc = p }
        return vc.presentingViewController?.view.window
            ?? view.window
    }

    /// The view the cover's content lives in — the presented controller's
    /// root. The backdrop goes at the bottom of it so it shows through
    /// wherever the dragged page has moved away.
    private var coverRootView: UIView? {
        var vc: UIViewController = self
        while let p = vc.parent { vc = p }
        return vc.view
    }

    private func showBackdrop() {
        guard let backdrop, let root = coverRootView, backdrop.superview == nil,
              let window = view.window ?? presenterWindow else { return }
        backdrop.frame = root.convert(window.bounds, from: window)
        backdropDim.backgroundColor = .black
        backdropDim.frame = backdrop.bounds
        backdropDim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backdrop.addSubview(backdropDim)
        root.insertSubview(backdrop, at: 0)
    }

    private func hideBackdrop() {
        backdrop?.removeFromSuperview()
        backdrop?.transform = .identity
    }

    /// Where the backdrop sits for a given drag progress (0 = page fully
    /// covering it, 1 = page gone): slightly behind and dimmed, catching up
    /// as the page leaves — the native back-swipe parallax.
    private func layoutBackdrop(progress: CGFloat, horizontal: Bool) {
        guard let backdrop else { return }
        let p = max(0, min(1, progress))
        backdrop.transform = horizontal
            ? CGAffineTransform(translationX: -0.3 * backdrop.bounds.width * (1 - p), y: 0)
            : CGAffineTransform(scaleX: 0.94 + 0.06 * p, y: 0.94 + 0.06 * p)
        backdropDim.alpha = 0.25 * (1 - p)
    }

    // MARK: - UIGestureRecognizerDelegate

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        if gestureRecognizer === edgeGesture { return true }
        return false
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // A flow inside with a step to go back to (`stepSwipeBack`) gets the
        // edge swipe: going back one step, not closing the whole screen.
        if gestureRecognizer === edgeGesture {
            // A NavigationStack hosted inside this full-screen cover owns
            // the edge gesture whenever it has pushed a destination. If the
            // cover handler also begins, a stats/detail swipe closes the
            // entire dashboard and lands back on the underlying profile.
            if hasPushedNavigationDestination { return false }
            return !EdgeSwipeAnchorView.claimsEdge(within: hostingController.view)
        }
        guard gestureRecognizer === downGesture else { return true }
        guard allowDownSwipe else { return false }
        let vel = downGesture.velocity(in: view)
        return vel.y > 0 && abs(vel.y) > abs(vel.x) * 1.5
    }

    /// SwiftUI's NavigationStack installs a UINavigationController below the
    /// hosting controller. Walk its controller subtree so the cover gesture
    /// can yield to UIKit's interactive-pop gesture while a page is pushed.
    private var hasPushedNavigationDestination: Bool {
        func containsPushedStack(_ controller: UIViewController) -> Bool {
            if let navigation = controller as? UINavigationController,
               navigation.viewControllers.count > 1 {
                return true
            }
            return controller.children.contains(where: containsPushedStack)
        }
        return containsPushedStack(hostingController)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        false
    }

    // MARK: - Edge swipe (left → right)

    @objc private func handleEdge(_ gesture: UIScreenEdgePanGestureRecognizer) {
        let tx = gesture.translation(in: view).x
        let width = view.bounds.width
        let progress = max(0, min(1, tx / width))

        switch gesture.state {
        case .began:
            showBackdrop()
            addEdgeShadow()
        case .changed:
            hostingController.view.transform = CGAffineTransform(translationX: max(0, tx), y: 0)
            layoutBackdrop(progress: progress, horizontal: true)
        case .ended, .cancelled:
            let vx = gesture.velocity(in: view).x
            if gesture.state == .ended, progress > 0.33 || vx > 600 {
                finishDismiss(horizontal: true, velocity: vx, remaining: width - max(0, tx))
            } else {
                snapBack(horizontal: true)
            }
        default: break
        }
    }

    // MARK: - Down swipe

    @objc private func handleDown(_ gesture: UIPanGestureRecognizer) {
        let ty = gesture.translation(in: view).y
        let height = view.bounds.height
        let progress = max(0, min(1, ty / height))

        switch gesture.state {
        case .began:
            showBackdrop()
        case .changed:
            hostingController.view.transform = CGAffineTransform(translationX: 0, y: max(0, ty))
            layoutBackdrop(progress: progress, horizontal: false)
        case .ended, .cancelled:
            let vy = gesture.velocity(in: view).y
            if gesture.state == .ended, ty > 0, progress > 0.2 || vy > 500 {
                finishDismiss(horizontal: false, velocity: vy, remaining: height - max(0, ty))
            } else {
                snapBack(horizontal: false)
            }
        default: break
        }
    }

    // MARK: - Helpers

    /// The page's left edge casts a soft shadow onto the screen behind it.
    private func addEdgeShadow() {
        let layer = hostingController.view.layer
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: -4, height: 0)
        layer.shadowPath = UIBezierPath(rect: hostingController.view.bounds).cgPath
    }

    private func removeEdgeShadow() {
        hostingController.view.layer.shadowOpacity = 0
    }

    /// Carry the page off screen in the direction of the swipe, at the
    /// finger's speed, then remove the cover with no animation of its own —
    /// the screen behind is already in place.
    private func finishDismiss(horizontal: Bool, velocity: CGFloat, remaining: CGFloat) {
        guard !isDismissing else { return }
        isDismissing = true
        let distance = max(remaining, 1)
        let duration = min(0.32, max(0.16, Double(distance / max(abs(velocity), 1))))
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseOut]) {
            self.hostingController.view.transform = horizontal
                ? CGAffineTransform(translationX: self.view.bounds.width, y: 0)
                : CGAffineTransform(translationX: 0, y: self.view.bounds.height)
            self.layoutBackdrop(progress: 1, horizontal: horizontal)
        } completion: { _ in
            self.removeCoverWithoutAnimation()
        }
    }

    /// The page is already off screen; the cover must now vanish on the spot.
    /// Whatever dismissal animation iOS or SwiftUI then plays (the default
    /// slide-down), it must not be visible: the cover — including the
    /// snapshot of the screen behind — is made fully transparent first, so
    /// the real screen underneath, identical to the snapshot, simply stays.
    private func removeCoverWithoutAnimation() {
        var presented: UIViewController = self
        while let p = presented.parent { presented = p }
        presented.view.alpha = 0
        hideBackdrop()
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { self.onDismiss() }
    }

    private func snapBack(horizontal: Bool) {
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.88,
                       initialSpringVelocity: 0) {
            self.hostingController.view.transform = .identity
            self.layoutBackdrop(progress: 0, horizontal: horizontal)
        } completion: { _ in
            self.hideBackdrop()
            self.removeEdgeShadow()
        }
    }
}

extension View {
    func swipeToDismiss(onDismiss: @escaping () -> Void, ignoreTopSafeArea: Bool = false,
                        allowDownSwipe: Bool = true) -> some View {
        // The container always spans the whole screen. Its hosting controller
        // still hands the window's insets to the page (unless
        // ignoreTopSafeArea), so content stays clear of the notch and home
        // indicator while page backgrounds reach the edges — stopping at the
        // safe area left white bands over and under every cover.
        SwipeToDismissContainer(onDismiss: onDismiss, ignoreTopSafeArea: ignoreTopSafeArea,
                                allowDownSwipe: allowDownSwipe) { self }
            .ignoresSafeArea()
    }
}
