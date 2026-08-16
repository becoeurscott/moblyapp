import SwiftUI

struct PageIndicator: View {
    var count: Int
    var current: Int
    var activeColor: Color = .moblyPrimary
    var inactiveColor: Color = Color(hex: 0xE2E4EC)

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? activeColor : inactiveColor)
                    .frame(width: i == current ? 22 : 6, height: 6)
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: current)
            }
        }
    }
}
