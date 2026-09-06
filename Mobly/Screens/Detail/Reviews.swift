import SwiftUI

struct Review: Identifiable {
    let id = UUID()
    let author: String
    let initial: String
    let stars: Int
    let timeAgo: String
    let text: String

    /// Empty. Seeded reviews rendered on *every* listing, attributing praise to
    /// real properties from people who never wrote it.
    static let samples: [Review] = []
}

struct StarRow: View {
    var count: Int
    var size: CGFloat = 12
    var color: Color = .moblyPrimary
    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: i <= count ? "star.fill" : "star")
                    .font(.system(size: size))
                    .foregroundStyle(i <= count ? color : Color(hex: 0xD5D8E2))
            }
        }
    }
}

struct ReviewRow: View {
    let review: Review
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color.moblySurfaceTint)
                    Text(review.initial)
                        .font(.moblyHeading(15))
                        .foregroundStyle(Color.moblyPrimary)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text(review.author)
                        .font(.moblyHeading(14))
                        .foregroundStyle(Color.moblyTextPrimary)
                    Text(review.timeAgo)
                        .font(.moblyBody(11.5))
                        .foregroundStyle(Color(hex: 0x9A9DAC))
                }
                Spacer()
                StarRow(count: review.stars, size: 11)
            }
            Text(review.text)
                .font(.moblyBody(13))
                .foregroundStyle(Color(hex: 0x4A4E5A))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Card version of a review for the horizontal slider.
struct ReviewCard: View {
    let review: Review
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color.moblySurfaceTint)
                    Text(review.initial)
                        .font(.moblyHeading(14))
                        .foregroundStyle(Color.moblyPrimary)
                }
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(review.author)
                        .font(.moblyHeading(13.5))
                        .foregroundStyle(Color.moblyTextPrimary)
                    Text(review.timeAgo)
                        .font(.moblyBody(11))
                        .foregroundStyle(Color(hex: 0x9A9DAC))
                }
                Spacer()
            }
            StarRow(count: review.stars, size: 11)
            Text(review.text)
                .font(.moblyBody(12.5))
                .foregroundStyle(Color(hex: 0x4A4E5A))
                .lineSpacing(2)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 260, height: 170, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(hex: 0xF7F8FA)))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: 0xEFF0F4), lineWidth: 1))
    }
}

// MARK: - Leave a review sheet

struct LeaveReviewSheet: View {
    var onSubmit: (Int, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var stars = 0
    @State private var text = ""
    @FocusState private var focused: Bool

    private var canSubmit: Bool { stars > 0 && !text.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Laisser un avis")
                    .font(.moblyHeading(20))
                    .foregroundStyle(Color.moblyTextPrimary)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.moblyTextPrimary)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color(hex: 0xF4F5F8)))
                }
            }
            .padding(.top, 22)
            .padding(.bottom, 22)

            Text("Votre note")
                .font(.moblyBody(13, weight: .semibold))
                .foregroundStyle(Color(hex: 0x6B6F80))
                .padding(.bottom, 10)

            // Tappable star rating
            HStack(spacing: 10) {
                ForEach(1...5, id: \.self) { i in
                    Button {
                        stars = i
                        UISelectionFeedbackGenerator().selectionChanged()
                    } label: {
                        Image(systemName: i <= stars ? "star.fill" : "star")
                            .font(.system(size: 32))
                            .foregroundStyle(i <= stars ? Color.moblyPrimary : Color(hex: 0xD5D8E2))
                            .scaleEffect(i == stars ? 1.15 : 1)
                            .animation(.spring(response: 0.3, dampingFraction: 0.5), value: stars)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 24)

            Text("Votre commentaire")
                .font(.moblyBody(13, weight: .semibold))
                .foregroundStyle(Color(hex: 0x6B6F80))
                .padding(.bottom, 10)

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Partagez votre expérience…")
                        .font(.moblyBody(14))
                        .foregroundStyle(Color(hex: 0xB0B3BF))
                        .padding(.horizontal, 15)
                        .padding(.vertical, 14)
                }
                TextEditor(text: $text)
                    .font(.moblyBody(14))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .focused($focused)
            }
            .frame(height: 120)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0xF4F5F8)))

            Spacer()

            PillButton(title: "Publier mon avis", style: .primaryBlue, trailingIcon: nil) {
                onSubmit(stars, text.trimmingCharacters(in: .whitespaces))
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
            }
            .opacity(canSubmit ? 1 : 0.5)
            .disabled(!canSubmit)
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 24)
        .background(Color.white)
    }
}

// MARK: - All reviews page (with star filter)

struct AllReviewsView: View {
    let reviews: [Review]

    enum SortOption: String, CaseIterable {
        case recent = "Récents"
        case highToLow = "Meilleures"
        case lowToHigh = "Moins bonnes"
    }

    @Environment(\.dismiss) private var dismiss
    @State private var selectedFilter: Int? = nil
    @State private var sortOption: SortOption = .recent

    private var filtered: [Review] {
        var result: [Review]
        if let star = selectedFilter {
            result = reviews.filter { $0.stars == star }
        } else {
            result = reviews
        }
        switch sortOption {
        case .recent: break
        case .highToLow: result.sort { $0.stars > $1.stars }
        case .lowToHigh: result.sort { $0.stars < $1.stars }
        }
        return result
    }

    private var averageRating: Double {
        guard !reviews.isEmpty else { return 0 }
        return Double(reviews.map(\.stars).reduce(0, +)) / Double(reviews.count)
    }

    private func count(for star: Int) -> Int {
        reviews.filter { $0.stars == star }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Tous les avis")
                    .font(.moblyHeading(20))
                    .foregroundStyle(Color.moblyTextPrimary)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.moblyTextPrimary)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color(hex: 0xF4F5F8)))
                }
            }
            .padding(.top, 22)
            .padding(.horizontal, 22)

            // Average rating summary
            HStack(spacing: 12) {
                VStack(spacing: 4) {
                    Text(String(format: "%.1f", averageRating))
                        .font(.moblyHeading(36))
                        .foregroundStyle(Color.moblyTextPrimary)
                    StarRow(count: Int(averageRating.rounded()), size: 14)
                    Text("\(reviews.count) avis")
                        .font(.moblyBody(12))
                        .foregroundStyle(Color(hex: 0x9A9DAC))
                }
                .frame(width: 90)

                VStack(spacing: 6) {
                    ForEach((1...5).reversed(), id: \.self) { star in
                        HStack(spacing: 8) {
                            Text("\(star)")
                                .font(.moblyBody(12, weight: .semibold))
                                .foregroundStyle(Color(hex: 0x9A9DAC))
                                .frame(width: 14)
                            Image(systemName: "star.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.moblyPrimary)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color(hex: 0xEFF0F4))
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.moblyPrimary)
                                        .frame(width: reviews.isEmpty ? 0 :
                                            geo.size.width * CGFloat(count(for: star)) / CGFloat(reviews.count))
                                }
                            }
                            .frame(height: 6)
                            Text("\(count(for: star))")
                                .font(.moblyBody(11))
                                .foregroundStyle(Color(hex: 0x9A9DAC))
                                .frame(width: 20, alignment: .trailing)
                        }
                    }
                }
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 18).fill(Color(hex: 0xF8F8FA)))
            .padding(.horizontal, 22)
            .padding(.top, 20)

            // Star filter chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterChip(label: "Tous", selected: selectedFilter == nil) {
                        selectedFilter = nil
                    }
                    ForEach((1...5).reversed(), id: \.self) { star in
                        FilterChip(
                            label: "\(star) ★",
                            count: count(for: star),
                            selected: selectedFilter == star
                        ) {
                            selectedFilter = selectedFilter == star ? nil : star
                        }
                    }
                }
                .padding(.horizontal, 22)
            }
            .padding(.top, 16)
            .padding(.bottom, 8)

            // Sort picker
            HStack {
                Text("Trier par")
                    .font(.moblyBody(12))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                Menu {
                    ForEach(SortOption.allCases, id: \.self) { opt in
                        Button {
                            sortOption = opt
                        } label: {
                            HStack {
                                Text(opt.rawValue)
                                if sortOption == opt {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(sortOption.rawValue)
                            .font(.moblyBody(12.5, weight: .semibold))
                            .foregroundStyle(Color.moblyTextPrimary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color(hex: 0x9A9DAC))
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: 0xF4F5F8)))
                }
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 8)

            // Review list
            if filtered.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "star.slash")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(Color(hex: 0xD5D8E2))
                    Text("Aucun avis avec cette note")
                        .font(.moblyBody(14, weight: .medium))
                        .foregroundStyle(Color(hex: 0x9A9DAC))
                }
                Spacer()
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { review in
                            ReviewRow(review: review)
                                .padding(.horizontal, 22)
                                .padding(.vertical, 14)
                            Divider().padding(.leading, 22)
                        }
                    }
                }
            }
        }
        .background(Color.white)
    }

    private struct FilterChip: View {
        let label: String
        var count: Int? = nil
        let selected: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                HStack(spacing: 4) {
                    Text(LT(label))
                        .font(.moblyBody(13, weight: .semibold))
                    if let count {
                        Text("(\(count))")
                            .font(.moblyBody(11))
                    }
                }
                .foregroundStyle(selected ? .white : Color.moblyTextPrimary)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Color.moblyPrimary : .white))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? Color.clear : Color(hex: 0xE2E4EC), lineWidth: 1.2))
            }
            .buttonStyle(.plain)
        }
    }
}
