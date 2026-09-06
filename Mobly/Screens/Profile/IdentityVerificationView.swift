import SwiftUI
import SafariServices

/// "Vérification d'identité" — explains the check, then opens the provider's
/// hosted flow (Didit) in a Safari sheet.
///
/// Deliberately thin: the ID photo and the selfie are captured by the provider
/// inside that sheet, so Mobly never holds a document scan. The verdict reaches
/// the backend by webhook; this screen just polls for it.
struct IdentityVerificationView: View {
    @StateObject private var store = IdentityVerificationStore.shared

    var body: some View {
        ProfileScaffold(title: "Vérification d'identité") {
            VStack(spacing: 16) {
                hero
                statusCard
                if store.status == .declined, let reason = store.reason {
                    refusalCard(reason)
                }
                if store.incomplete { incompleteCard }
                if !store.isVerified {
                    stepsCard
                    if store.unavailable { unavailableBanner } else { startButton }
                }
                privacyNote
            }
        }
        .task { await store.refresh() }
        .sheet(item: $store.hostedFlow) { flow in
            SafariSheet(url: flow.url)
                .ignoresSafeArea()
                .onDisappear { Task { await store.pollAfterFlow() } }
        }
        .alert(LT("Erreur"), isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button(LT("OK"), role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(statusTint.opacity(0.14)).frame(width: 84, height: 84)
                Image(systemName: store.isVerified ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                    .font(.system(size: 40))
                    .foregroundStyle(statusTint)
            }
            Text(LT(statusTitle))
                .font(.moblyHeading(19))
                .foregroundStyle(Color.moblyTextPrimary)
            Text(LT(statusSubtitle))
                .font(.moblyBody(13))
                .foregroundStyle(Color(hex: 0x9A9DAC))
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: Cards

    private var statusCard: some View {
        cardBox {
            HStack(spacing: 12) {
                Circle().fill(statusTint).frame(width: 10, height: 10)
                Text(LT(statusRowLabel))
                    .font(.moblyBody(14, weight: .medium))
                    .foregroundStyle(Color.moblyTextPrimary)
                Spacer()
                if store.isRefreshing {
                    ProgressView().tint(Color.moblyPrimary)
                } else if store.status.isOpen && !store.incomplete {
                    ProgressView().tint(Color.moblyPrimary)
                }
                if store.status.isOpen {
                    Button { Task { await store.recheck() } } label: {
                        Text(LT("Actualiser"))
                            .font(.moblyBody(12.5, weight: .semibold))
                            .foregroundStyle(Color.moblyPrimary)
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isRefreshing)
                }
            }
        }
    }

    private var stepsCard: some View {
        cardBox {
            VStack(alignment: .leading, spacing: 14) {
                Text(LT("Comment ça marche"))
                    .font(.moblyBody(14.5, weight: .semibold))
                    .foregroundStyle(Color.moblyTextPrimary)
                step(1, "Photographiez votre pièce d'identité (CNI, passeport ou permis).")
                step(2, "Prenez un selfie pour confirmer que c'est bien vous.")
                step(3, "Le résultat arrive en quelques minutes.")
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.moblyBody(12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.moblyPrimary))
            Text(LT(text))
                .font(.moblyBody(13.5))
                .foregroundStyle(Color(hex: 0x666666))
            Spacer(minLength: 0)
        }
    }

    private func refusalCard(_ reason: String) -> some View {
        cardBox {
            VStack(alignment: .leading, spacing: 6) {
                Text(LT("Motif du refus"))
                    .font(.moblyBody(13, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xE5484D))
                Text(reason)
                    .font(.moblyBody(13))
                    .foregroundStyle(Color(hex: 0x666666))
            }
        }
    }

    /// Shown when the hosted flow closed without a decision. Explains what
    /// happened instead of leaving a spinner running, and the CTA below turns
    /// back on so the user can pick up where they left off.
    private var incompleteCard: some View {
        cardBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color(hex: 0xF5A524))
                VStack(alignment: .leading, spacing: 4) {
                    Text(LT("Vérification non terminée"))
                        .font(.moblyBody(14, weight: .semibold))
                        .foregroundStyle(Color.moblyTextPrimary)
                    Text(LT(store.resumeExpired
                            ? "La session précédente a expiré. Une nouvelle vérification sera lancée."
                            : "La vérification n'a pas été finalisée. Reprenez-la pour obtenir votre badge — vous reprendrez là où vous vous êtes arrêté."))
                        .font(.moblyBody(12.5))
                        .foregroundStyle(Color(hex: 0x666666))
                        .fixedSize(horizontal: false, vertical: true)

                    if let left = store.resumeSecondsLeft, left > 0 {
                        HStack(spacing: 6) {
                            Image(systemName: "clock.fill")
                                .font(.system(size: 11, weight: .semibold))
                            Text(LT("Reprise possible encore ") + Self.mmss(left))
                                .font(.moblyBody(12, weight: .semibold))
                                .monospacedDigit()
                        }
                        .foregroundStyle(Color(hex: 0xC24E10))
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Capsule().fill(Color(hex: 0xFFF3EC)))
                        .padding(.top, 2)
                        .accessibilityLabel(Text("Reprise possible encore \(Int(left) / 60) minutes"))
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var startButton: some View {
        Button {
            Task { await store.start() }
        } label: {
            HStack(spacing: 8) {
                if store.isBusy { ProgressView().tint(.white) }
                Text(LT(startLabel))
                    .font(.moblyBody(15.5, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.moblyPrimary))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        // Never permanently disabled. Any open check must stay actionable —
        // that was the dead end. Retrying is safe: the server hands back the
        // same in-flight session for 30 minutes rather than billing a new one.
        .disabled(store.isBusy)
        .opacity(store.isBusy ? 0.55 : 1)
    }

    private var unavailableBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: 22))
                .foregroundStyle(Color(hex: 0xF5A524))
            VStack(alignment: .leading, spacing: 2) {
                Text(LT("Bientôt disponible"))
                    .font(.moblyBody(14, weight: .semibold))
                    .foregroundStyle(Color.moblyTextPrimary)
                Text(LT("La vérification d'identité sera activée prochainement."))
                    .font(.moblyBody(12.5))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(hex: 0xFFF8EC)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(hex: 0xF5A524).opacity(0.3)))
    }

    private var privacyNote: some View {
        Text(LT("Vos documents sont transmis directement à notre partenaire de "
                + "vérification. Mobly n'en conserve aucune copie."))
            .font(.moblyBody(11.5))
            .foregroundStyle(Color(hex: 0x9A9DAC))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)
    }

    private func cardBox<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c().frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 18).fill(.white))
            .shadow(color: Color(hex: 0x14152A).opacity(0.05), radius: 8, y: 2)
    }

    // MARK: Status copy

    /// "24:31" — the resume window is always under an hour.
    static func mmss(_ interval: TimeInterval) -> String {
        let t = max(0, Int(interval.rounded(.down)))
        return String(format: "%02d:%02d", t / 60, t % 60)
    }

    private var startLabel: String {
        if store.resumeExpired { return "Recommencer la vérification" }
        if store.incomplete { return "Reprendre la vérification" }
        if store.status == .declined { return "Réessayer" }
        if store.status == .abandoned { return "Relancer la vérification" }
        if store.status == .inReview { return "Recommencer la vérification" }
        return "Commencer la vérification"
    }

    private var statusTint: Color {
        switch store.status {
        case .approved: return Color(hex: 0x1F8A5B)
        case .pending, .inReview: return Color(hex: 0xF5A524)
        case .declined: return Color(hex: 0xE5484D)
        case .none, .abandoned: return Color(hex: 0x9A9DAC)
        }
    }

    private var statusTitle: String {
        store.isVerified ? "Identité vérifiée" : "Identité non vérifiée"
    }

    private var statusSubtitle: String {
        // A stalled check must not claim to be running — that is the message
        // that made the screen look like it was stuck loading.
        if store.incomplete {
            return "Vous avez quitté avant la fin.\nReprenez pour obtenir votre badge."
        }
        switch store.status {
        case .approved:
            return "Votre profil affiche le badge vérifié.\nCela renforce la confiance des hôtes."
        case .pending, .inReview:
            return "Vérification en cours. Nous vous préviendrons\ndès qu'elle est terminée."
        case .declined:
            return "Vous pouvez recommencer avec un document\nplus lisible."
        case .abandoned:
            return "La session a expiré avant la fin.\nRelancez la vérification."
        case .none:
            return "Vérifiez votre identité pour rassurer\nles propriétaires."
        }
    }

    private var statusRowLabel: String {
        if store.incomplete { return "Vérification non terminée" }
        switch store.status {
        case .approved: return "Pièce d'identité et selfie vérifiés"
        case .pending: return "Vérification en cours"
        case .inReview: return "En cours d'examen"
        case .declined: return "Vérification refusée"
        case .abandoned: return "Vérification interrompue"
        case .none: return "Aucune vérification effectuée"
        }
    }
}

/// `SFSafariViewController` in a sheet, rather than an in-app `WKWebView`, so
/// the provider's flow runs in a real browser with camera access and a visible
/// address bar — the user can see who they are handing their ID to.
private struct SafariSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        return SFSafariViewController(url: url, configuration: config)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// Wrapper so a URL can drive `.sheet(item:)` without conforming `URL` itself
/// to `Identifiable` app-wide.
struct HostedFlowLink: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
