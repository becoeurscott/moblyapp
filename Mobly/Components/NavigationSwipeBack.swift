import UIKit

/// Keeps iOS's swipe-from-the-left-edge "back" working on pushed screens.
///
/// Every pushed screen in Mobly hides the system navigation bar to draw its own
/// back button (`ProfileScaffold` and friends). UIKit disables the interactive
/// pop gesture whenever the system back button is hidden, so all of those
/// screens — Profil's sub-screens first — could only be left with the button.
///
/// Becoming the gesture's delegate lifts that: the swipe starts whenever there
/// is a screen underneath, and the native interactive animation plays (the
/// page follows the finger, the previous screen slides in behind it).
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === interactivePopGestureRecognizer else { return true }
        // Root screen: nothing to go back to. Mid-transition: a second pop
        // would corrupt the stack.
        return viewControllers.count > 1 && transitionCoordinator == nil
    }
}
