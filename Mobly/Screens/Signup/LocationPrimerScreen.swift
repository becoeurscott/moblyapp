import SwiftUI

/// Mobly's own location screen, outside signup: the only place besides the
/// signup step and the Home card from which iOS's location dialog may appear.
///
/// - `.reoffer`: before Home, for someone who chose "Allow Once" last time.
/// - `.action`: an action that needs the position (share it in chat, centre
///   the map, pin a listing) while iOS hasn't been asked yet.
struct LocationPrimerScreen: View {
    enum Context { case reoffer, action }

    var context: Context
    /// Whether location ended up allowed.
    var onDone: (Bool) -> Void

    @ObservedObject private var location = LocationService.shared
    @State private var waiting = false

    var body: some View {
        VStack(spacing: 0) {
            PrimerContent(art: .location, eyebrow: eyebrow, title: title, message: message)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 6) {
                PillButton(title: L("Autoriser la localisation"), style: .primaryBlue,
                           trailingIcon: nil) {
                    guard location.canAskPermission else { finish(location.isAuthorized); return }
                    waiting = true
                    location.askForPermission()
                }
                .opacity(waiting ? 0.6 : 1)
                .disabled(waiting)
                Button {
                    if context == .reoffer { location.snoozeReoffer() }
                    finish(false)
                } label: {
                    Text("Plus tard")
                        .font(.moblyHeading(16))
                        .foregroundStyle(Color.moblyTextPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                }
                .buttonStyle(.plain)
                .disabled(waiting)
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 16)
        }
        .background(Color.white.ignoresSafeArea())
        .onChange(of: location.authorization) { _, status in
            guard waiting, status != .notDetermined else { return }
            finish(location.isAuthorized)
        }
        .onAppear { SessionTracker.shared.log("location.primer.shown", ["context": "\(context)"]) }
    }

    private func finish(_ granted: Bool) {
        waiting = false
        SessionTracker.shared.log("location.primer.answered",
                                  ["context": "\(context)", "granted": granted])
        onDone(granted)
    }

    private var eyebrow: LocalizedStringKey? {
        context == .reoffer ? "Votre position" : nil
    }

    private var title: LocalizedStringKey {
        context == .reoffer ? "On garde les espaces près de vous ?" : "Voyez d'abord ce qui est près de vous"
    }

    private var message: LocalizedStringKey {
        context == .reoffer
            ? "La dernière fois, vous l'aviez autorisée une seule fois. Autorisez-la pendant l'utilisation pour retrouver les annonces les plus proches à chaque visite. Votre position exacte n'est jamais partagée avec les propriétaires."
            : "Mobly a besoin de votre position pour cette action. Votre position exacte n'est jamais partagée avec les propriétaires."
    }
}
