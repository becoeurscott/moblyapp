import SwiftUI

/// Visitor-side "Demander une visite" flow: pick a date/time, add an optional
/// note, and POST /listings/:id/visits.
struct RequestVisitSheet: View {
    let listing: Listing
    @Environment(\.dismiss) private var dismiss

    @State private var date: Date = {
        // Default = tomorrow at 15:00.
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: .now) ?? .now
        return cal.date(bySettingHour: 15, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }()
    @State private var note: String = ""
    @State private var isSubmitting = false
    @State private var submitError: String?
    @State private var didSubmit = false

    var body: some View {
        VStack(spacing: 0) {
            if didSubmit { successView } else { formView }
        }
        .background(Color.moblySurface)
    }

    private var formView: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Demander une visite")
                    .font(.moblyHeading(20))
                    .foregroundStyle(Color.moblyTextPrimary)
                Spacer()
            }
            .padding(.top, 12)

            listingChip

            VStack(alignment: .leading, spacing: 8) {
                Text("Date et heure").font(.moblyHeading(14))
                    .foregroundStyle(Color.moblyTextPrimary)
                DatePicker("", selection: $date, in: Date.now...,
                           displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .environment(\.locale, Locale(identifier: "fr_FR"))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Message au propriétaire (optionnel)")
                    .font(.moblyHeading(14))
                    .foregroundStyle(Color.moblyTextPrimary)
                TextField("Bonjour, je souhaite visiter…",
                          text: $note, axis: .vertical)
                    .lineLimit(3...5)
                    .font(.moblyBody(14))
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.white)
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(hex: 0xE2E4EC), lineWidth: 1)))
            }

            if let err = submitError {
                Text(err).font(.moblyBody(12))
                    .foregroundStyle(Color(hex: 0xE5484D))
            }

            Spacer(minLength: 0)

            Button(action: submit) {
                HStack(spacing: 8) {
                    if isSubmitting {
                        ProgressView().tint(.white)
                    }
                    Text(isSubmitting ? "Envoi…" : "Envoyer la demande")
                        .font(.moblyHeading(15))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 52)
                .background(RoundedRectangle(cornerRadius: 15)
                    .fill(isSubmitting ? Color(hex: 0x9BA6F8) : Color.moblyPrimary))
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting)
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 20)
    }

    private var listingChip: some View {
        HStack(spacing: 12) {
            ListingCover(listing: listing)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(listing.title).font(.moblyHeading(14))
                    .foregroundStyle(Color.moblyTextPrimary).lineLimit(1)
                Text(listing.location).font(.moblyBody(12))
                    .foregroundStyle(Color.moblyTextSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white))
    }

    private var successView: some View {
        VStack(spacing: 16) {
            Spacer()
            ZStack {
                Circle().fill(Color(hex: 0xE9F9EF)).frame(width: 84, height: 84)
                Image(systemName: "checkmark")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Color(hex: 0x1F8A5B))
            }
            Text("Demande envoyée")
                .font(.moblyHeading(20))
                .foregroundStyle(Color.moblyTextPrimary)
            Text("Le propriétaire recevra une notification et pourra confirmer ou proposer un autre créneau.")
                .font(.moblyBody(13.5))
                .foregroundStyle(Color.moblyTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            Spacer()
            Button {
                dismiss()
            } label: {
                Text("Terminé")
                    .font(.moblyHeading(15))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(RoundedRectangle(cornerRadius: 15).fill(Color.moblyPrimary))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    private func submit() {
        submitError = nil
        isSubmitting = true
        Task {
            do {
                _ = try await MoblyAPI.shared.requestVisit(
                    listingId: listing.id,
                    scheduledAt: date,
                    note: note.isEmpty ? nil : note
                )
                await MainActor.run {
                    isSubmitting = false
                    didSubmit = true
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    SessionTracker.shared.log("visit.request", [
                        "listingId": listing.id,
                        "source": "listing_detail"
                    ])
                }
            } catch let e as MoblyAPI.APIError {
                await MainActor.run {
                    isSubmitting = false
                    submitError = e.message
                }
            } catch {
                await MainActor.run {
                    isSubmitting = false
                    submitError = error.localizedDescription
                }
            }
        }
    }
}
