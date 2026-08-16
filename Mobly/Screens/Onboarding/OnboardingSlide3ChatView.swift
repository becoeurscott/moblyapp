import SwiftUI

struct OnboardingSlide3ChatView: View {
    var onSkip: () -> Void
    var onBack: () -> Void
    var onNext: () -> Void

    @State private var entered = false

    var body: some View {
        VStack(spacing: 0) {
            OnboardingTopBar(skipTint: Color(hex: 0x9A9DAC), onSkip: onSkip)
                .padding(.top, 12)

            ChatHero(entered: entered)
                .padding(.horizontal, 28)
                .padding(.top, 8)

            Spacer(minLength: 8)

            VStack(alignment: .leading, spacing: 0) {
                PageIndicator(count: 3, current: 1)
                    .padding(.bottom, 22)

                Text("Échangez et planifiez sans quitter l'app")
                    .font(.moblyHeading(25))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Contactez le propriétaire, convenez d'une visite et gardez votre numéro privé — tout se passe dans Mobly.")
                    .font(.moblyBody(14))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                    .lineSpacing(3)
                    .padding(.top, 10)
                    .padding(.bottom, 28)

                HStack(spacing: 12) {
                    CircleBackButton(action: onBack)
                    PillButton(title: "Suivant", style: .primaryBlue, action: onNext)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 40)
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.15)) { entered = true }
        }
        .onDisappear { entered = false }
    }
}

// MARK: - Chat hero

private struct ChatHero: View {
    var entered: Bool
    @State private var float = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                Circle().fill(Color.moblyAccent.opacity(0.10))
                    .frame(width: w * 1.05, height: w * 1.05).blur(radius: 34)

                ChatCard(show: entered)
                    .frame(width: w * 0.84)
                    .scaleEffect(entered ? 1 : 0.92)
                    .opacity(entered ? 1 : 0)
                    .animation(.spring(response: 0.6, dampingFraction: 0.82), value: entered)

                // Privacy chip (top-left)
                chip("lock.fill", "Numéro masqué")
                    .position(x: w * 0.22, y: w * 0.05 + (float ? -6 : 6))
                    .opacity(entered ? 1 : 0)
                    .animation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true), value: float)

                // Visit-confirmed card (bottom-right, pops)
                visitCard
                    .position(x: w * 0.70, y: w * 1.02)
                    .scaleEffect(entered ? 1 : 0.4)
                    .opacity(entered ? 1 : 0)
                    .animation(.spring(response: 0.5, dampingFraction: 0.6).delay(0.9), value: entered)
            }
            .frame(width: w, height: geo.size.height)
        }
        .aspectRatio(0.82, contentMode: .fit)
        .onAppear { float = true }
    }

    private func chip(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(Color.moblyPrimary)
            Text(LT(text)).font(.moblyHeading(11.5)).foregroundStyle(Color(hex: 0x14152A))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Capsule().fill(.white))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
    }

    private var visitCard: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color(hex: 0xE9F9EF))
                Image(systemName: "calendar.badge.checkmark").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x1F8A5B))
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Visite confirmée").font(.moblyHeading(13)).foregroundStyle(Color(hex: 0x14152A))
                Text("Demain · 15:00").font(.moblyBody(11)).foregroundStyle(Color(hex: 0x1F8A5B))
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 16).fill(.white))
        .shadow(color: Color(hex: 0x14152A).opacity(0.16), radius: 16, y: 8)
    }
}

// MARK: - Chat card

private struct ChatCard: View {
    var show: Bool
    @ObservedObject private var store = ListingStore.shared

    /// The listing being discussed in the chat mock — a real one if available,
    /// otherwise the bundled Akwa studio.
    private var listing: Listing? { store.listings.first }

    /// Owner name gets picked up if the real listing has one, else the
    /// historical "Paul M." keeps the mock's rhythm.
    private var ownerName: String { listing?.ownerName ?? "Paul M." }
    private var ownerInitial: String { String(ownerName.prefix(1)).uppercased() }

    /// The incoming bubble references the listing's title / neighborhood so
    /// the whole mock feels coherent instead of half real / half sample.
    private var incomingText: String {
        if let l = listing {
            let where_ = l.location.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            return where_.isEmpty
                ? "Bonjour, \(l.title.lowercased()) est-il toujours disponible ?"
                : "Bonjour, \(l.title) à \(where_) est-il toujours disponible ?"
        }
        return "Bonjour, le studio à Akwa est-il toujours disponible ?"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 10) {
                ChatBubble(text: incomingText,
                           style: .incoming, delay: 0.15, show: show)
                listingPill
                    .opacity(show ? 1 : 0).offset(y: show ? 0 : 6)
                    .animation(.spring(response: 0.5, dampingFraction: 0.85).delay(0.3), value: show)
                ChatBubble(text: "Oui ! Vous pouvez visiter demain 🙂",
                           style: .outgoing, delay: 0.5, show: show, time: "09:42")
                TypingBubble()
                    .opacity(show ? 1 : 0)
                    .animation(.easeInOut.delay(0.75), value: show)
            }
            .padding(.horizontal, 14).padding(.vertical, 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            inputBar
        }
        .background(Color(hex: 0xF4F5F8))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .shadow(color: Color(hex: 0x14152A).opacity(0.14), radius: 28, y: 20)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(LinearGradient(colors: [Color.moblyPrimary, Color(hex: 0x6D2FE0)],
                                             startPoint: .top, endPoint: .bottom))
                Text(ownerInitial).font(.moblyHeading(14)).foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(ownerName).font(.moblyHeading(13.5)).foregroundStyle(Color(hex: 0x14152A))
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 11)).foregroundStyle(Color(hex: 0x1F8A5B))
                }
                HStack(spacing: 5) {
                    Circle().fill(Color(hex: 0x1F8A5B)).frame(width: 6, height: 6)
                    Text("En ligne").font(.moblyBody(10.5)).foregroundStyle(Color(hex: 0x1F8A5B))
                }
            }
            Spacer()
            Image(systemName: "phone.fill").font(.system(size: 13)).foregroundStyle(Color.moblyPrimary)
        }
        .padding(.horizontal, 15).padding(.vertical, 13)
        .background(Color.white)
        .overlay(Rectangle().fill(Color(hex: 0xECEDF1)).frame(height: 1), alignment: .bottom)
    }

    private var listingPill: some View {
        HStack(spacing: 10) {
            Group {
                if let l = listing {
                    ListingCover(listing: l)
                } else {
                    Image("ListingGreen").resizable().aspectRatio(contentMode: .fill)
                }
            }
            .frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(listing?.title ?? "Studio meublé · Akwa")
                    .font(.moblyHeading(11.5)).foregroundStyle(Color(hex: 0x14152A))
                    .lineLimit(1)
                Text(listing?.location ?? "Douala, Cameroun")
                    .font(.moblyBody(10)).foregroundStyle(Color(hex: 0x9A9DAC))
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Color(hex: 0xC4C7D2))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 13).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color(hex: 0xE7E9F0), lineWidth: 1))
        .padding(.trailing, 30)
    }

    private var inputBar: some View {
        HStack(spacing: 9) {
            HStack {
                Text("Écrivez un message…").font(.moblyBody(11.5)).foregroundStyle(Color(hex: 0xB0B3BF))
                Spacer()
            }
            .padding(.horizontal, 13).frame(height: 32)
            .background(Capsule().fill(Color(hex: 0xF4F5F8)))
            ZStack {
                Circle().fill(Color.moblyPrimary)
                Image(systemName: "paperplane.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 32, height: 32)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(Color.white)
        .overlay(Rectangle().fill(Color(hex: 0xECEDF1)).frame(height: 1), alignment: .top)
    }
}

// MARK: - Typing indicator

private struct TypingBubble: View {
    @State private var phase = 0.0
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle().fill(Color(hex: 0x9A9DAC))
                    .frame(width: 6, height: 6)
                    .opacity(dotOpacity(i))
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .background(UnevenRoundedRectangle(cornerRadii: .init(topLeading: 4, bottomLeading: 15, bottomTrailing: 15, topTrailing: 15)).fill(.white))
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = 3 }
        }
    }
    private func dotOpacity(_ i: Int) -> Double {
        let p = (phase + Double(3 - i)).truncatingRemainder(dividingBy: 3)
        return 0.3 + 0.7 * (p < 1 ? p : (p < 2 ? 2 - p : 0))
    }
}

// MARK: - Chat bubble

private enum BubbleStyle { case incoming, outgoing }

private struct ChatBubble: View {
    var text: String
    var style: BubbleStyle
    var delay: Double
    var show: Bool
    var time: String? = nil

    var body: some View {
        HStack {
            if style == .outgoing { Spacer(minLength: 40) }
            VStack(alignment: .trailing, spacing: 3) {
                Text(LT(text))
                    .font(.moblyBody(12.5))
                    .foregroundStyle(style == .incoming ? Color(hex: 0x14152A) : .white)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let time {
                    HStack(spacing: 3) {
                        Text(time).font(.system(size: 9))
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 9))
                    }
                    .foregroundStyle(Color.white.opacity(0.75))
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 10)
            .background(bubbleShape.fill(style == .incoming ? Color.white : Color.moblyPrimary))
            .shadow(color: style == .incoming ? .black.opacity(0.05) : .clear, radius: 1, y: 1)
            if style == .incoming { Spacer(minLength: 40) }
        }
        .opacity(show ? 1 : 0)
        .offset(y: show ? 0 : 6)
        .animation(.spring(response: 0.5, dampingFraction: 0.85).delay(delay), value: show)
    }

    private var bubbleShape: some Shape {
        UnevenRoundedRectangle(cornerRadii: .init(
            topLeading: style == .incoming ? 4 : 15,
            bottomLeading: 15,
            bottomTrailing: 15,
            topTrailing: style == .incoming ? 15 : 4
        ))
    }
}
