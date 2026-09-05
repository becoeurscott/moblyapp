import SwiftUI
import UIKit

/// Wraps any full-screen-cover content and adds an interactive left-edge
/// swipe-to-dismiss, mimicking the native navigation back gesture.
struct SwipeToDismissContainer<Content: View>: UIViewControllerRepresentable {
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content

    func makeUIViewController(context: Context) -> SwipeDismissHostController<Content> {
        let vc = SwipeDismissHostController(rootView: content(), onDismiss: onDismiss)
        return vc
    }

    func updateUIViewController(_ vc: SwipeDismissHostController<Content>, context: Context) {
        vc.updateContent(content())
    }
}

final class SwipeDismissHostController<Content: View>: UIViewController {
    private let hostingController: UIHostingController<Content>
    private let onDismiss: () -> Void
    private var panGesture: UIScreenEdgePanGestureRecognizer!

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
        view.addSubview(hostingController.view)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        hostingController.didMove(toParent: self)

        panGesture = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handlePan))
        panGesture.edges = .left
        view.addGestureRecognizer(panGesture)
    }

    @objc private func handlePan(_ gesture: UIScreenEdgePanGestureRecognizer) {
        let translation = gesture.translation(in: view).x
        let width = view.bounds.width
        let progress = max(0, min(1, translation / width))

        switch gesture.state {
        case .changed:
            hostingController.view.transform = CGAffineTransform(translationX: translation, y: 0)
            hostingController.view.alpha = 1 - progress * 0.3
        case .ended, .cancelled:
            let velocity = gesture.velocity(in: view).x
            if progress > 0.35 || velocity > 800 {
                UIView.animate(withDuration: 0.22, delay: 0, options: .curveEaseOut) {
                    self.hostingController.view.transform = CGAffineTransform(translationX: width, y: 0)
                    self.hostingController.view.alpha = 0
                } completion: { _ in
                    self.onDismiss()
                }
            } else {
                UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.8,
                               initialSpringVelocity: 0) {
                    self.hostingController.view.transform = .identity
                    self.hostingController.view.alpha = 1
                }
            }
        default: break
        }
    }
}

extension View {
    func swipeToDismiss(onDismiss: @escaping () -> Void) -> some View {
        SwipeToDismissContainer(onDismiss: onDismiss) { self }
    }
}
