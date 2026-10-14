import SwiftUI

/// Swipe a card left to remove it — notifications, favourites. The card
/// follows the finger over a red backdrop; past a third of its width (or on
/// a quick flick) it slides off and `onRemove` runs, short of that it springs
/// back. The first few points of travel decide the axis, so vertical drags
/// stay with the scroll view.
///
/// Simultaneous rather than `.gesture`: inside a ScrollView a plain gesture
/// never received the drag on iOS 18. Use `onTapGesture` (not a `Button`) for
/// the card's own tap, so the touch-up that ends a swipe doesn't also open it.
struct SwipeToRemove: ViewModifier {
    var icon: String = "trash.fill"
    var label: String = "Supprimer"
    var cornerRadius: CGFloat = 18
    let onRemove: () -> Void

    @State private var offset: CGFloat = 0
    @State private var width: CGFloat = 0
    @State private var horizontal: Bool?

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .background(alignment: .trailing) {
                if offset < 0 {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.moblyAlert)
                        .overlay(alignment: .trailing) {
                            VStack(spacing: 3) {
                                Image(systemName: icon)
                                    .font(.system(size: 17, weight: .semibold))
                                Text(LT(label))
                                    .font(.moblyBody(11, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.trailing, 20)
                            .opacity(min(1, -offset / 60))
                        }
                }
            }
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { width = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in width = w }
            })
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { v in
                        if horizontal == nil {
                            horizontal = abs(v.translation.width) > abs(v.translation.height)
                        }
                        guard horizontal == true else { return }
                        offset = min(0, v.translation.width)
                    }
                    .onEnded { v in
                        defer { horizontal = nil }
                        guard horizontal == true else { return }
                        let w = max(width, 1)
                        if offset < -w / 3 || v.predictedEndTranslation.width < -w * 0.8 {
                            withAnimation(Motion.quick) { offset = -w - 40 }
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: onRemove)
                        } else {
                            withAnimation(Motion.quick) { offset = 0 }
                        }
                    }
            )
            .accessibilityAction(named: Text(LT(label)), onRemove)
    }
}

extension View {
    func swipeToRemove(icon: String = "trash.fill", label: String = "Supprimer",
                       cornerRadius: CGFloat = 18,
                       _ onRemove: @escaping () -> Void) -> some View {
        modifier(SwipeToRemove(icon: icon, label: label, cornerRadius: cornerRadius,
                               onRemove: onRemove))
    }
}
