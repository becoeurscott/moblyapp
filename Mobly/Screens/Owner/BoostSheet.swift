import SwiftUI

/// Boost purchase flow. Pick a plan → confirm → processing beat → success, then
/// the annonce is boosted via `onActivate(days)`. No real payment (prototype,
/// no backend) — this simulates the mobile-money purchase step.
struct BoostSheet: View {
    let annonce: OwnerAnnonce
    var onActivate: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    struct Plan: Identifiable {
        let id = UUID()
        let days: Int
        let price: Int          // FCFA
        let tagline: String
        let popular: Bool
        var perDay: Int { Int((Double(price) / Double(days)).rounded()) }
    }
    private let plans = [
        Plan(days: 3,  price: 500,   tagline: "×2 plus de vues", popular: false),
        Plan(days: 7,  price: 1_000, tagline: "×3 plus de vues", popular: true),
        Plan(days: 30, price: 3_000, tagline: "×5 plus de vues · en tête", popular: false),
    ]
    @State private var selected: Int = 1     // index; default the popular plan

    /// Most expensive per-day rate (the shortest plan) — the savings baseline.
    private var baselinePerDay: Int { plans.map(\.perDay).max() ?? 1 }
    /// % cheaper per day than the baseline, for a given plan.
    private func savings(_ plan: Plan) -> Int {
        Int((1 - Double(plan.perDay) / Double(baselinePerDay)) * 100)
    }

    private enum Phase { case choose, processing, done }
    @State private var phase: Phase = .choose

    var body: some View {
        ZStack {
            Color.moblySurface.ignoresSafeArea()
            switch phase {
            case .choose:     chooseView.transition(.opacity)
            case .processing: processingView.transition(.opacity)
            case .done:       doneView.transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: phase)
    }

    // MARK: Choose

    private var chooseView: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    listingRow
                    VStack(spacing: 12) {
                        ForEach(Array(plans.enumerated()), id: \.offset) { i, plan in
                            planCard(plan, index: i)
                        }
                    }
                    benefits
                }
                .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 20)
            }
            footer
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill").font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.moblyAccent)
                Text("Booster cette annonce").font(.moblyHeading(21)).foregroundStyle(Color.moblyTextPrimary)
            }
            Text("Passez en tête des résultats et touchez plus de locataires.")
                .font(.moblyBody(13)).foregroundStyle(Color(hex: 0x9A9DAC))
        }
    }

    private var listingRow: some View {
        HStack(spacing: 12) {
            ListingCover(listing: annonce.listing)
                .frame(width: 48, height: 48).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(annonce.listing.title).font(.moblyHeading(14.5)).foregroundStyle(Color.moblyTextPrimary)
                Text(annonce.listing.location).font(.moblyBody(11.5)).foregroundStyle(Color(hex: 0x9A9DAC))
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white))
    }

    private func planCard(_ plan: Plan, index: Int) -> some View {
        let isSel = selected == index
        return Button {
            UISelectionFeedbackGenerator().selectionChanged()
            selected = index
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle().stroke(isSel ? Color.moblyPrimary : Color(hex: 0xD5D8E2), lineWidth: 2)
                        .frame(width: 22, height: 22)
                    if isSel { Circle().fill(Color.moblyPrimary).frame(width: 12, height: 12) }
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("\(plan.days) jours").font(.moblyHeading(16)).foregroundStyle(Color.moblyTextPrimary)
                        if plan.popular {
                            Text("POPULAIRE").font(.moblyBody(9, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Capsule().fill(Color.moblyAccent))
                        }
                        if savings(plan) > 0 {
                            Text("-\(savings(plan))%").font(.moblyBody(9, weight: .bold))
                                .foregroundStyle(Color(hex: 0x1F8A5B))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Capsule().fill(Color(hex: 0xE9F9EF)))
                        }
                    }
                    Text(plan.tagline).font(.moblyBody(12)).foregroundStyle(Color(hex: 0x9A9DAC))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(plan.price.formattedGrouped) FCFA")
                        .font(.moblyHeading(15)).foregroundStyle(Color.moblyPrimary)
                    Text("≈ \(plan.perDay) FCFA/jour")
                        .font(.moblyBody(10.5)).foregroundStyle(Color(hex: 0x9A9DAC))
                }
            }
            .padding(15)
            .background(RoundedRectangle(cornerRadius: 16).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .stroke(isSel ? Color.moblyPrimary : Color(hex: 0xE2E4EC), lineWidth: isSel ? 2 : 1.5))
        }
        .buttonStyle(.plain)
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 10) {
            benefitRow("arrow.up.circle.fill", "En tête des résultats et de la carte")
            benefitRow("sparkles", "Badge « Boostée » plus visible")
            benefitRow("chart.line.uptrend.xyaxis", "Statistiques de performance détaillées")
        }
        .padding(.top, 2)
    }

    private func benefitRow(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.moblyAccent).frame(width: 22)
            Text(LT(text)).font(.moblyBody(13)).foregroundStyle(Color.moblyTextSecondary)
            Spacer()
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            PillButton(title: "Activer le boost · \(plans[selected].price.formattedGrouped) FCFA",
                       style: .primaryOrange, trailingIcon: "bolt.fill") {
                startProcessing()
            }
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 10)
            Text("Paiement Mobile Money · sans engagement")
                .font(.moblyBody(11)).foregroundStyle(Color(hex: 0x9A9DAC))
                .padding(.bottom, 10)
        }
        .background(Color.moblySurface)
    }

    // MARK: Processing

    private var processingView: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView().scaleEffect(1.6).tint(Color.moblyAccent)
            VStack(spacing: 6) {
                Text("Activation du boost…").font(.moblyHeading(17)).foregroundStyle(Color.moblyTextPrimary)
                Text("Confirmation du paiement Mobile Money")
                    .font(.moblyBody(13)).foregroundStyle(Color(hex: 0x9A9DAC))
            }
            Spacer()
        }
    }

    // MARK: Done

    private var doneView: some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                Circle().fill(Color(hex: 0xFFF3EC)).frame(width: 96, height: 96)
                Image(systemName: "checkmark").font(.system(size: 40, weight: .bold))
                    .foregroundStyle(Color.moblyAccent)
            }
            VStack(spacing: 8) {
                Text("Boost activé !").font(.moblyHeading(22)).foregroundStyle(Color.moblyTextPrimary)
                Text("« \(annonce.listing.title) » est boostée pour \(plans[selected].days) jours.")
                    .font(.moblyBody(13.5)).foregroundStyle(Color(hex: 0x9A9DAC))
                    .multilineTextAlignment(.center)
            }
            Spacer()
            PillButton(title: "Terminé", style: .primaryBlue, trailingIcon: nil) { dismiss() }
                .padding(.horizontal, 20).padding(.bottom, 16)
        }
        .padding(.horizontal, 20)
    }

    // MARK: Logic

    private func startProcessing() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation { phase = .processing }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            onActivate(plans[selected].days)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation { phase = .done }
        }
    }
}
