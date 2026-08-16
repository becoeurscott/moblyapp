import SwiftUI

struct OnboardingSlide2ListingView: View {
    var onSkip: () -> Void
    var onBack: () -> Void
    var onStart: () -> Void

    @State private var entered = false

    var body: some View {
        VStack(spacing: 0) {
            OnboardingTopBar(skipTint: Color(hex: 0x9A9DAC), onSkip: onSkip)
                .padding(.top, 12)

            BoostHero(entered: entered)
                .padding(.horizontal, 30)
                .padding(.top, 10)

            Spacer(minLength: 8)

            VStack(alignment: .leading, spacing: 0) {
                PageIndicator(count: 3, current: 2)
                    .padding(.bottom, 22)

                Text("Publiez et boostez vos annonces")
                    .font(.moblyHeading(25))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Mettez votre espace en ligne gratuitement, puis boostez-le pour passer en tête et toucher jusqu'à 3× plus de locataires — dès 500 FCFA.")
                    .font(.moblyBody(14))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                    .lineSpacing(3)
                    .padding(.top, 10)
                    .padding(.bottom, 28)

                HStack(spacing: 12) {
                    CircleBackButton(action: onBack)
                    PillButton(title: "Commencer", style: .primaryOrange, action: onStart)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 40)
        }
        .onAppear { entered = true }
        .onDisappear { entered = false }
    }
}

// MARK: - Boost hero

private struct BoostHero: View {
    var entered: Bool
    @State private var float = false
    @State private var pulse = false
    @ObservedObject private var store = ListingStore.shared

    /// Three real listings once the store has answered, else nil (falls back
    /// to the bundled sample rows below).
    private var rows: [Listing]? {
        let live = Array(store.listings.prefix(3))
        return live.count >= 3 ? live : nil
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                Circle().fill(Color.moblyAccent.opacity(0.12))
                    .frame(width: w * 1.05, height: w * 1.05).blur(radius: 32)

                resultsCard(w: w)
                    .frame(width: w * 0.84)
                    .scaleEffect(entered ? 1 : 0.92)
                    .opacity(entered ? 1 : 0)
                    .animation(.spring(response: 0.6, dampingFraction: 0.82), value: entered)

                // Floating cues: publish (free) + boost (×3 views)
                publishPill
                    .position(x: w * 0.30, y: w * 0.05 + (float ? -6 : 6))
                    .opacity(entered ? 1 : 0)
                    .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true), value: float)

                chip("bolt.fill", "×3 plus de vues", tint: 0xFF6B35)
                    .position(x: w * 0.78, y: w * 0.90 + (float ? 7 : -5))
                    .opacity(entered ? 1 : 0)
                    .animation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true), value: float)

                // Boost seal pops in
                boltBadge
                    .position(x: w * 0.82, y: w * 0.10)
                    .scaleEffect(entered ? (pulse ? 1.06 : 1) : 0.3)
                    .opacity(entered ? 1 : 0)
                    .animation(.spring(response: 0.5, dampingFraction: 0.55).delay(0.4), value: entered)
            }
            .frame(width: w, height: geo.size.height)
        }
        .aspectRatio(0.9, contentMode: .fit)
        .onAppear {
            float = true
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private func resultsCard(w: CGFloat) -> some View {
        // Heading location comes from the first (boosted) row when we have
        // real data, so the "Résultats · <city>" header matches the property
        // actually being featured below.
        let headerCity: String = {
            if let r = rows?.first, let city = r.location.split(separator: ",").first {
                return String(city).trimmingCharacters(in: .whitespaces)
            }
            return "Akwa, Douala"
        }()
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .bold))
                Text("Résultats · \(headerCity)").font(.moblyBody(11.5, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(Color(hex: 0x9A9DAC))

            if let rows {
                resultRow(listing: rows[0], boosted: true)
                    .scaleEffect(1.02)
                    .shadow(color: Color.moblyAccent.opacity(0.28), radius: 14, y: 8)
                resultRow(listing: rows[1], boosted: false).opacity(0.7)
                resultRow(listing: rows[2], boosted: false).opacity(0.5)
            } else {
                fallbackRow(image: "ListingGreen", title: "Studio · Akwa",
                            sub: "Meublé · 1 ch", boosted: true)
                    .scaleEffect(1.02)
                    .shadow(color: Color.moblyAccent.opacity(0.28), radius: 14, y: 8)
                fallbackRow(image: "ListingYellow", title: "Bureau · Bonanjo",
                            sub: "Open space", boosted: false).opacity(0.7)
                fallbackRow(image: "ListingPink", title: "Villa · Bonapriso",
                            sub: "4 ch · Piscine", boosted: false).opacity(0.5)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 22).fill(.white))
        .shadow(color: Color(hex: 0x14152A).opacity(0.16), radius: 24, y: 16)
    }

    private func resultRow(listing: Listing, boosted: Bool) -> some View {
        HStack(spacing: 11) {
            ListingCover(listing: listing)
                .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text(listing.title).font(.moblyHeading(13.5)).foregroundStyle(Color(hex: 0x14152A)).lineLimit(1)
                Text(listing.subtitle.isEmpty ? listing.location : listing.subtitle)
                    .font(.moblyBody(11)).foregroundStyle(Color(hex: 0x9A9DAC)).lineLimit(1)
            }
            Spacer()
            if boosted { boostedBadge }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 15)
            .fill(boosted ? Color(hex: 0xFFF3EC) : Color(hex: 0xF7F8FA)))
        .overlay(RoundedRectangle(cornerRadius: 15)
            .stroke(boosted ? Color.moblyAccent.opacity(0.35) : .clear, lineWidth: 1.5))
    }

    private func fallbackRow(image: String, title: String, sub: String, boosted: Bool) -> some View {
        HStack(spacing: 11) {
            Image(image).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text(LT(title)).font(.moblyHeading(13.5)).foregroundStyle(Color(hex: 0x14152A)).lineLimit(1)
                Text(LT(sub)).font(.moblyBody(11)).foregroundStyle(Color(hex: 0x9A9DAC))
            }
            Spacer()
            if boosted { boostedBadge }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 15)
            .fill(boosted ? Color(hex: 0xFFF3EC) : Color(hex: 0xF7F8FA)))
        .overlay(RoundedRectangle(cornerRadius: 15)
            .stroke(boosted ? Color.moblyAccent.opacity(0.35) : .clear, lineWidth: 1.5))
    }

    private var boostedBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "bolt.fill").font(.system(size: 9, weight: .bold))
            Text("BOOSTÉE").font(.moblyBody(9, weight: .bold)).fixedSize()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Capsule().fill(Color.moblyAccent))
    }

    private var boltBadge: some View {
        ZStack {
            Image(systemName: "seal.fill").font(.system(size: 58)).foregroundStyle(Color.moblyAccent)
                .shadow(color: Color.moblyAccent.opacity(0.45), radius: 10, y: 5)
            Image(systemName: "bolt.fill").font(.system(size: 24)).foregroundStyle(.white)
        }
    }

    private var publishPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus").font(.system(size: 11, weight: .bold))
            Text("Publier gratuit").font(.moblyHeading(12))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 13).padding(.vertical, 9)
        .background(Capsule().fill(Color.moblyAccent))
        .shadow(color: Color.moblyAccent.opacity(0.35), radius: 9, y: 5)
    }

    private func chip(_ icon: String, _ text: String, tint: UInt32) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundStyle(Color(hex: tint))
            Text(LT(text)).font(.moblyHeading(11.5)).foregroundStyle(Color(hex: 0x14152A))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Capsule().fill(.white))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
    }
}
