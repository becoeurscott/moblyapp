import SwiftUI
import UIKit

/// Wraps any full-screen-cover content and adds interactive dismiss gestures:
/// left-edge swipe (like navigation back) and top-down swipe (since covers
/// slide up). Visual drag feedback during the gesture; the actual dismiss is
/// handed back to SwiftUI's fullScreenCover so the native animation plays.
struct SwipeToDismissContainer<Content: View>: UIViewControllerRepresentable {
    let onDismiss: () -> Void
    var ignoreTopSafeArea: Bool = false
    @ViewBuilder let content: () -> Content

    func makeUIViewController(context: Context) -> SwipeDismissHostController<Content> {
        let vc = SwipeDismissHostController(rootView: content(), onDismiss: onDismiss)
        vc.ignoreTopSafeArea = ignoreTopSafeArea
        return vc
    }

    func updateUIViewController(_ vc: SwipeDismissHostController<Content>, context: Context) {
        vc.updateContent(content())
        vc.onDismiss = onDismiss
    }
}

final class SwipeDismissHostController<Content: View>: UIViewController,
    UIGestureRecognizerDelegate {
    private let hostingController: UIHostingController<Content>
    var onDismiss: () -> Void
    var ignoreTopSafeArea = false
    private var edgeGesture: UIScreenEdgePanGestureRecognizer!
    private var downGesture: UIPanGestureRecognizer!
    private var isDismissing = false

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

    // MARK: - UIGestureRecognizerDelegate

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        if gestureRecognizer === edgeGesture { return true }
        return false
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === downGesture else { return true }
        let vel = downGesture.velocity(in: view)
        return vel.y > 0 && abs(vel.y) > abs(vel.x) * 1.5
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
        case .changed:
            hostingController.view.transform = CGAffineTransform(translationX: max(0, tx), y: 0)
            hostingController.view.alpha = 1 - progress * 0.3
        case .ended, .cancelled:
            let vx = gesture.velocity(in: view).x
            if progress > 0.25 || vx > 600 {
                fireDismiss()
            } else {
                snapBack()
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
        case .changed:
            guard ty > 0 else { return }
            hostingController.view.transform = CGAffineTransform(translationX: 0, y: ty)
            hostingController.view.alpha = 1 - progress * 0.3
        case .ended, .cancelled:
            let vy = gesture.velocity(in: view).y
            if progress > 0.2 || vy > 500 {
                fireDismiss()
            } else {
                snapBack()
            }
        default: break
        }
    }

    // MARK: - Helpers

    private func fireDismiss() {
        guard !isDismissing else { return }
        isDismissing = true
        hostingController.view.transform = .identity
        hostingController.view.alpha = 1
        onDismiss()
    }

    private func snapBack() {
        UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.85,
                       initialSpringVelocity: 0) {
            self.hostingController.view.transform = .identity
            self.hostingController.view.alpha = 1
        }
    }
}

extension View {
    func swipeToDismiss(onDismiss: @escaping () -> Void, ignoreTopSafeArea: Bool = false) -> some View {
        SwipeToDismissContainer(onDismiss: onDismiss, ignoreTopSafeArea: ignoreTopSafeArea) { self }
            .ignoresSafeArea(edges: ignoreTopSafeArea ? .top : [])
    }
}
