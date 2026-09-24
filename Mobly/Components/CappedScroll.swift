import SwiftUI

/// A vertical list that grows with its content up to `maxHeight`, then stops
/// growing and scrolls inside that height.
///
/// `.frame(maxHeight:)` on a ScrollView isn't enough: a ScrollView has no
/// natural height, so it either fills all the space it's offered or, with
/// `.fixedSize`, grows to fit every row. This measures the content and sizes
/// the scroll view to exactly `min(content, maxHeight)`.
struct CappedScroll<Content: View>: View {
    var maxHeight: CGFloat
    @ViewBuilder var content: () -> Content

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView(showsIndicators: contentHeight > maxHeight) {
            content()
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: CappedScrollHeightKey.self, value: geo.size.height)
                    }
                )
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(contentHeight, maxHeight))
        .clipped()
        // Grow/shrink smoothly as rows arrive or leave, including the first
        // measurement: the panel opens from 0 to its height instead of
        // appearing at full size in one frame.
        .onPreferenceChange(CappedScrollHeightKey.self) { h in
            withAnimation(SearchDropdown.animation) { contentHeight = h }
        }
    }
}
private struct CappedScrollHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Six suggestion rows (≈52pt each) — the most a search dropdown shows before
/// it scrolls.
enum SearchDropdown {
    static let maxHeight: CGFloat = 6 * 52

    /// Opens and closes the dropdown: it grows down from the search bar and
    /// fades, instead of popping in.
    static let transition: AnyTransition = .asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)),
        // Closing: a short fade while drifting up into the search bar — no
        // resizing, no content change, so nothing jumps.
        removal: .opacity.combined(with: .offset(y: -8))
    )

    static let animation = Animation.spring(response: 0.34, dampingFraction: 0.9)
    static let closeAnimation = Animation.smooth(duration: 0.3)
}
