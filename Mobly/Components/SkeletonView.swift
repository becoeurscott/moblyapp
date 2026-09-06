import SwiftUI

struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(
                    colors: [.clear, Color.white.opacity(0.4), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .scaleEffect(x: 2)
                .offset(x: phase * 300)
                .mask(content)
            )
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

extension View {
    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }
}

struct SkeletonBox: View {
    var width: CGFloat? = nil
    var height: CGFloat = 16
    var radius: CGFloat = 8

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color(hex: 0xE8E9EF))
            .frame(width: width, height: height)
            .shimmer()
    }
}

// MARK: - Listing card skeleton

struct ListingCardSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SkeletonBox(height: 180, radius: 20)
            VStack(alignment: .leading, spacing: 8) {
                SkeletonBox(width: 160, height: 14)
                SkeletonBox(width: 100, height: 12)
                SkeletonBox(width: 80, height: 14)
            }
            .padding(.horizontal, 4)
            .padding(.top, 12)
        }
        .frame(width: 240)
    }
}

struct FeaturedCardSkeleton: View {
    var body: some View {
        SkeletonBox(height: 210, radius: 24)
            .padding(.horizontal, 22)
    }
}

// MARK: - Thread row skeleton

struct ThreadRowSkeleton: View {
    var body: some View {
        HStack(spacing: 12) {
            SkeletonBox(width: 52, height: 52, radius: 26)
            VStack(alignment: .leading, spacing: 8) {
                SkeletonBox(width: 120, height: 14)
                SkeletonBox(height: 12)
            }
            Spacer()
            SkeletonBox(width: 36, height: 10)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
    }
}

struct ThreadListSkeleton: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<5, id: \.self) { _ in
                ThreadRowSkeleton()
            }
        }
    }
}

// MARK: - Home section skeleton

struct RecommendedRowSkeleton: View {
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(0..<3, id: \.self) { _ in
                    ListingCardSkeleton()
                }
            }
            .padding(.horizontal, 22)
        }
        .disabled(true)
    }
}
