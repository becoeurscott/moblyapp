import SwiftUI
import StoreKit

struct AppRatingPrompt: View {
    let onClose: () -> Void
    @Environment(\.requestReview) private var requestReview
    @State private var rating = 5
    @State private var submitting = false
    @State private var thankYou = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.48).ignoresSafeArea()
            VStack(spacing: 18) {
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color(hex: 0x777A88))
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color(hex: 0xF1F2F6)))
                    }
                    .accessibilityLabel("Fermer")
                }
                if thankYou {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 42))
                        .foregroundStyle(Color.moblyPrimary)
                        .symbolEffect(.bounce, value: thankYou)
                    Text("Merci pour votre avis !")
                        .font(.moblyHeading(20))
                        .foregroundStyle(Color.moblyTextPrimary)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Image(systemName: "star.circle.fill")
                        .font(.system(size: 42))
                        .foregroundStyle(Color.moblyAccent)
                    Text("Vous aimez Mobly ?")
                        .font(.moblyHeading(20))
                        .foregroundStyle(Color.moblyTextPrimary)
                    Text("Votre note nous aide à améliorer l’application.")
                        .font(.moblyBody(14))
                        .foregroundStyle(Color(hex: 0x777A88))
                        .multilineTextAlignment(.center)
                    HStack(spacing: 8) {
                        ForEach(1...5, id: \.self) { value in
                            Button {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.65)) {
                                    rating = value
                                }
                            } label: {
                                Image(systemName: value <= rating ? "star.fill" : "star")
                                    .font(.system(size: 31))
                                    .foregroundStyle(Color.moblyAccent)
                                    .scaleEffect(value == rating ? 1.12 : 1)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(value) étoile\(value > 1 ? "s" : "")")
                        }
                    }
                    Button(action: submit) {
                        HStack {
                            if submitting { ProgressView().tint(.white) }
                            Text("Envoyer").font(.moblyHeading(15))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .background(Capsule().fill(Color.moblyPrimary))
                    }
                    .disabled(submitting)
                    .padding(.top, 4)
                }
            }
            .padding(22)
            .frame(maxWidth: 340)
            .background(RoundedRectangle(cornerRadius: 24).fill(.white))
            .shadow(color: .black.opacity(0.18), radius: 28, y: 14)
            .padding(.horizontal, 26)
            .animation(.spring(response: 0.38, dampingFraction: 0.82), value: thankYou)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .interactiveDismissDisabled()
    }

    private func submit() {
        guard !submitting else { return }
        submitting = true
        Task {
            struct Body: Encodable { let rating: Int }
            struct Reply: Decodable { let rating: Value }
            struct Value: Decodable { let rating: Int }
            do {
                let _: Reply = try await MoblyAPI.shared.request(
                    "app-rating", method: "POST", body: Body(rating: rating), authorized: true
                )
                UserDefaults.standard.set(Date().addingTimeInterval(90 * 24 * 60 * 60),
                                          forKey: "appRatingNextPromptAt")
                if rating == 5 {
                    onClose()
                    requestReview()
                } else {
                    withAnimation { thankYou = true }
                    try? await Task.sleep(nanoseconds: 1_450_000_000)
                    onClose()
                }
            } catch {
                submitting = false
            }
        }
    }
}
