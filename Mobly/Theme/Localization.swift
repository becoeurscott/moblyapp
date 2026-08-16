import SwiftUI

/// App-wide language state. Changing `code` re-renders the whole app (the root
/// view keys its content on this), so every string wrapped in `L(...)` updates.
final class AppLang: ObservableObject {
    static let shared = AppLang()

    /// Master switch for in-app language selection.
    ///
    /// Set to `false` for now: the English String Catalog is complete (618
    /// strings) but the product is French-first for the Douala pilot, and a
    /// half-used language picker is one more thing to keep honest. Flip this
    /// to `true` to bring the Langue row back — nothing else needs changing,
    /// the catalog and the `.environment(\.locale)` wiring stay in place.
    static let selectionEnabled = false

    @Published var code: String = {
        // Pinned to French while selection is disabled. This also resets any
        // account that had already switched to English before the picker was
        // withdrawn — otherwise they'd be stuck in a language they can no
        // longer change.
        guard selectionEnabled else {
            UserDefaults.standard.set("fr", forKey: "appLang")
            return "fr"
        }
        return UserDefaults.standard.string(forKey: "appLang") ?? "fr"
    }() {
        didSet { UserDefaults.standard.set(code, forKey: "appLang") }
    }
    /// True while a switch is in progress — RootView shows a full-app
    /// loading overlay so the user knows the change is being applied
    /// everywhere, not just on the Language screen.
    @Published var switching: Bool = false
    private init() {}
}

/// Translate a French source string to the active language.
///
/// Backed by `Localizable.xcstrings` — the same String Catalog SwiftUI uses for
/// `Text("…")`, `Button("…")` and friends, so there is exactly one place
/// translations live. French is the source language, so a missing entry falls
/// back to the French key, which is what we want.
///
/// Most call sites don't need this: any SwiftUI view that takes a
/// `LocalizedStringKey` localises itself from the environment locale that
/// `RootView` sets. Reach for `L(...)` only when you need a plain `String` —
/// string interpolation, or a custom helper whose parameter is `String`.
func L(_ fr: String) -> String {
    let code = AppLang.shared.code
    if code == "fr" { return fr }
    return String(localized: String.LocalizationValue(fr),
                  locale: Locale(identifier: code))
}

/// Translate canonical domain labels while keeping the stored/API value French.
/// Use this for category chips, filters, and deal names.
func LT(_ frName: String) -> String {
    L(frName)
}

// The old hand-maintained dictionary lived here. It is gone on purpose: it was a
// second, competing source of truth that only ever covered 28 phrases, and a
// string translated in one place but not the other is how you ship a half-English
// screen. `Localizable.xcstrings` is now the only translation table.
