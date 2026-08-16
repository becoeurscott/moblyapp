import SwiftUI
import Combine

/// Global chrome visibility.
///
/// Mobly draws its own tab bar (`MoblyTabBar`) instead of using a system
/// `TabView`, so SwiftUI's `.toolbar(.hidden, for: .tabBar)` has no effect.
/// Screens that need a full-bleed presentation flip `hideTabBar` here and
/// `MainTabView` reacts.
@MainActor
final class AppChrome: ObservableObject {
    static let shared = AppChrome()
    @Published var hideTabBar = false
    private init() {}
}

extension View {
    /// Hide Mobly's custom tab bar for as long as this view is on screen.
    /// Restores it on disappear, so a screen can't leak the hidden state if
    /// the user swipes back instead of tapping a button.
    func hidesMoblyTabBar() -> some View {
        self
            .onAppear  { AppChrome.shared.hideTabBar = true }
            .onDisappear { AppChrome.shared.hideTabBar = false }
    }
}
