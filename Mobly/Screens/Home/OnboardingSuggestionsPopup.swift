import SwiftUI

/// Three real spaces matching what a new user asked for during onboarding,
/// offered once on Home a few seconds after they arrive — the moment the
/// answers they gave turn into something they can open.
enum OnboardingSuggestions {
    struct Result {
        let listings: [Listing]
        /// What the picks actually match, said plainly — it widens when the
        /// exact request had nothing ("Studios dans le Littoral" → "Espaces
        /// dans le Littoral").
        let label: String
    }

    /// Tightest match first, then looser ones; never past the région the
    /// user chose, so nothing shown is unrelated to what they asked.
    static func find(for answers: OnboardingAnswers) async -> Result? {
        let types = Set(answers.spaceTypes)
        let region = answers.region
        let budget = answers.budget

        func fetch(region: String?, budget: OnboardingAnswers.Budget?, types: Set<String>) async -> [Listing] {
            // The API takes one category; several are filtered here instead.
            let category = types.count == 1 ? types.first : nil
            let dtos = (try? await MoblyAPI.shared.searchListings(
                category: category, region: region,
                minPrice: budget?.min, maxPrice: budget?.max, limit: 40)) ?? []
            let listings = dtos.map(\.asListing)
            let ofStay = listings.filter {
                $0.matchesStay(answers.stay, minDuration: answers.stay == "long" ? answers.minDuration : nil)
            }
            let matching = types.isEmpty ? ofStay : ofStay.filter { types.contains($0.category) }
            return Array(matching.prefix(3))
        }

        var attempts: [(OnboardingAnswers.Budget?, Set<String>)] = [(budget, types)]
        if budget != nil { attempts.append((nil, types)) }
        if !types.isEmpty, region != nil { attempts.append((nil, [])) }

        for (b, t) in attempts {
            let found = await fetch(region: region, budget: b, types: t)
            guard !found.isEmpty else { continue }
            var parts: [String] = []
            let typeWord = t.count == 1 ? t.first! : L("Espaces")
            parts.append(region.map { typeWord + " " + OnboardingAnswers.inRegion($0) } ?? typeWord)
            if let b, b.min != nil || b.max != nil { parts.append(L(b.label)) }
            return Result(listings: found, label: parts.joined(separator: " · "))
        }
        return nil
    }
}

struct OnboardingSuggestionsPopup: View {
    var firstName: String
    var result: OnboardingSuggestions.Result
    var onOpen: (Listing) -> Void
    var onSeeMore: () -> Void
    var onDismiss: () -> Void

    @State private var shown = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(shown ? 0.35 : 0)
                .ignoresSafeArea()
                .onTapGesture(perform: close)

            if shown {
                card
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { shown = true }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .bold))
                Text("Pour vous")
                    .font(.moblyBody(12, weight: .bold))
            }
            .foregroundStyle(Color.moblyPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.moblySurfaceTint))
            .padding(.bottom, 12)

            Text(firstName.isEmpty
                 ? "Nous avons trouvé des espaces pour vous"
                 : "\(firstName), nous avons trouvé des espaces pour vous")
                .font(.moblyHeading(21))
                .foregroundStyle(Color.moblyTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)
            Text(result.label)
                .font(.moblyBody(13.5))
                .foregroundStyle(Color(hex: 0x6B6F80))
                .padding(.bottom, 16)

            VStack(spacing: 10) {
                ForEach(result.listings) { listing in
                    Button { onOpen(listing) } label: { row(listing) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 18)

            PillButton(title: L("Voir plus d'espaces"), style: .primaryBlue,
                       trailingIcon: "arrow.right", height: 52, action: onSeeMore)
            Button(action: close) {
                Text("Plus tard")
                    .font(.moblyHeading(15))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.white)
                .shadow(color: Color(hex: 0x14152A).opacity(0.18), radius: 24, y: 8)
        )
    }

    private func row(_ listing: Listing) -> some View {
        HStack(spacing: 12) {
            ListingCover(listing: listing, width: ImageSlot.card)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(listing.title)
                        .font(.moblyBody(14.5, weight: .semibold))
                        .foregroundStyle(Color.moblyTextPrimary)
                        .lineLimit(1)
                    // Only an owner actually verified gets the seal.
                    if listing.ownerVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.moblyPrimary)
                    }
                }
                Text(listing.location)
                    .font(.moblyBody(12.5))
                    .foregroundStyle(Color(hex: 0x6B6F80))
                    .lineLimit(1)
                Text(listing.price + LT(listing.priceUnit))
                    .font(.moblyBody(13.5, weight: .bold))
                    .foregroundStyle(Color.moblyPrimary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(hex: 0xC4C7D2))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(hex: 0xF7F8FB)))
    }

    private func close() {
        withAnimation(.easeInOut(duration: 0.25)) { shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { onDismiss() }
    }
}
