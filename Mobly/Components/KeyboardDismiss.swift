import SwiftUI
import UIKit

/// Closes the keyboard when the user taps anywhere outside a text input,
/// and (via `.scrollDismissesKeyboard`) when they scroll.
///
/// The tap is caught by one window-level recognizer that never cancels
/// touches, so buttons, links, rows and the fields themselves keep working.
/// Taps on a text field / text view are ignored (they move focus instead),
/// and so are taps in the strip just above the keyboard, where chat
/// composers and their send buttons live.
extension View {
    func dismissKeyboardOnTap() -> some View {
        background(KeyboardDismissInstaller().frame(width: 0, height: 0))
    }
}

enum Keyboard {
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

private struct KeyboardDismissInstaller: UIViewRepresentable {
    func makeUIView(context: Context) -> InstallerView { InstallerView() }
    func updateUIView(_ uiView: InstallerView, context: Context) {}

    final class InstallerView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window else { return }
            KeyboardTapDismisser.shared.install(on: window)
        }
    }
}

private final class KeyboardTapDismisser: NSObject, UIGestureRecognizerDelegate {
    static let shared = KeyboardTapDismisser()

    private var installed = NSHashTable<UIWindow>.weakObjects()
    private var keyboardFrame: CGRect = .null
    /// Height of the band above the keyboard where taps never dismiss
    /// (chat input bars, send buttons, field toolbars).
    private let composerBand: CGFloat = 90

    override init() {
        super.init()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(kbChange(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        nc.addObserver(self, selector: #selector(kbHide), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @objc private func kbChange(_ n: Notification) {
        if let f = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect { keyboardFrame = f }
    }
    @objc private func kbHide() { keyboardFrame = .null }

    func install(on window: UIWindow) {
        guard !installed.contains(window) else { return }
        installed.add(window)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.requiresExclusiveTouchType = false
        tap.delegate = self
        window.addGestureRecognizer(tap)
    }

    @objc private func handleTap() { Keyboard.dismiss() }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard !keyboardFrame.isNull else { return false }       // no keyboard: nothing to do
        var v = touch.view
        while let cur = v {                                       // tapping a field keeps the keyboard
            if cur is UITextField || cur is UITextView || cur is UISearchBar { return false }
            v = cur.superview
        }
        if let window = touch.window {
            let p = touch.location(in: nil)
            let kb = window.convert(keyboardFrame, from: nil)
            if p.y >= kb.minY - composerBand { return false }     // composer / send button strip
        }
        return true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
