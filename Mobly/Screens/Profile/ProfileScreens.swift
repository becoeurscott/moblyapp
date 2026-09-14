import SwiftUI
import PhotosUI
import UIKit

enum ProfileRoute: Hashable {
    case editProfile, identity, language, notifications, savedSearches
    case help, privacy, about, becomeOwner, ownerDashboard
}

// MARK: - Shared scaffold (custom header + back)

struct ProfileScaffold<Content: View>: View {
    let title: String
    /// When false, hide the top bar (back button + centered title). The
    /// caller is expected to render its own navigation affordance — used
    /// by Modifier le profil which wants a clean, chrome-free page.
    var showsHeader: Bool = true
    @ViewBuilder var content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.moblyTextPrimary)
                            .frame(width: 42, height: 42)
                            .background(RoundedRectangle(cornerRadius: 14).fill(.white)
                                .shadow(color: Color(hex: 0x14152A).opacity(0.06), radius: 8, y: 2))
                    }
                    Spacer()
                    Text(LT(title)).font(.moblyHeading(19)).foregroundStyle(Color.moblyTextPrimary)
                    Spacer()
                    Color.clear.frame(width: 42, height: 42)
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 10)
            }

            ScrollView(showsIndicators: false) {
                content().padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 40)
            }
        }
        .background(Color.moblySurface)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
    }
}

private func card<C: View>(@ViewBuilder _ c: () -> C) -> some View {
    c().frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18).fill(.white))
        .shadow(color: Color(hex: 0x14152A).opacity(0.05), radius: 8, y: 2)
}

// MARK: - Edit profile

struct EditProfileView: View {
    @ObservedObject private var auth = AuthStore.shared
    @ObservedObject private var location = LocationService.shared

    /// Prefer what's stored on the account; fall back to a fresh reading.
    private var detectedCity: String {
        auth.user?.city ?? location.city ?? (
            location.status == .denied ? "Position non autorisée" : "Détection…"
        )
    }

    // Empty until the real user loads. Prefilling these with a sample identity
    // meant the form opened showing someone else's name and e-mail — and
    // "Enregistrer" would have written them onto the signed-in account.
    @State private var name = ""
    @State private var email = ""
    /// Currently-selected identity colour. Nil until the account loads.
    @State private var avatarColor: String?

    @State private var isSaving = false
    @State private var saveError: String?
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var uploadingAvatar = false
    @State private var uploadSpin = false
    /// Post-save success state: shows a green check + "Enregistré" for
    /// ~0.6s before dismissing back to the Profile tab.
    @State private var savedSuccess = false
    @Environment(\.dismiss) private var dismiss

    /// Read-only: the phone is the account identifier and is changed through
    /// an OTP flow, not by typing a new one into a form.
    private var phone: String { auth.user?.phone ?? "" }

    private var initials: String {
        let parts = name.split(separator: " ")
        let letters = parts.prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    var body: some View {
        ZStack {
        ProfileScaffold(title: "Modifier le profil", showsHeader: false) {
            VStack(spacing: 18) {
                // Small back chevron in the top-left. The scaffold's own
                // header is hidden and the iOS nav bar stays hidden too,
                // so this is the sole way out of the screen (besides Save).
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.moblyTextPrimary)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(.white))
                            .shadow(color: Color(hex: 0x14152A).opacity(0.06), radius: 6, y: 2)
                    }
                    Spacer()
                }
                ZStack(alignment: .bottomTrailing) {
                    ZStack {
                        if let url = auth.user?.avatarUrl, let u = URL(string: url) {
                            AsyncImage(url: u) { phase in
                                switch phase {
                                case .success(let img): img.resizable().scaledToFill()
                                default:
                                    LinearGradient(colors: AvatarPalette.gradient(
                                        for: auth.user?.id ?? "self", stored: avatarColor
                                    ), startPoint: .top, endPoint: .bottom)
                                    .overlay(Text(initials).font(.moblyHeading(28)).foregroundStyle(.white))
                                }
                            }
                            .frame(width: 92, height: 92)
                            .clipShape(Circle())
                        } else {
                            Circle().fill(
                                LinearGradient(colors: AvatarPalette.gradient(
                                    for: auth.user?.id ?? "self", stored: avatarColor
                                ), startPoint: .top, endPoint: .bottom)
                            )
                            .frame(width: 92, height: 92)
                            .overlay(Text(initials).font(.moblyHeading(28)).foregroundStyle(.white))
                        }
                        if uploadingAvatar {
                            // Dark scrim + a rotating ring around the avatar
                            // so the upload state is impossible to miss. The
                            // ring animates independently of the ProgressView
                            // so it stays visible even in Reduce Motion mode.
                            Circle().fill(.black.opacity(0.45)).frame(width: 92, height: 92)
                            Circle()
                                .trim(from: 0, to: 0.7)
                                .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .frame(width: 82, height: 82)
                                .rotationEffect(.degrees(uploadSpin ? 360 : 0))
                                .animation(.linear(duration: 1.0).repeatForever(autoreverses: false),
                                           value: uploadSpin)
                            VStack(spacing: 4) {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 22, weight: .bold))
                                    .foregroundStyle(.white)
                                Text("Envoi…")
                                    .font(.moblyBody(10.5, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                    PhotosPicker(selection: $pickerItems, maxSelectionCount: 1, matching: .images) {
                        ZStack {
                            Circle().fill(.white).frame(width: 32, height: 32)
                                .shadow(color: .black.opacity(0.1), radius: 4)
                            Image(systemName: "camera.fill").font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.moblyPrimary)
                        }
                    }
                    .disabled(uploadingAvatar)
                }
                .padding(.top, 8)
                .onChange(of: pickerItems) { _, items in
                    guard let first = items.first else { return }
                    Task { await handleAvatarPick(first) }
                }

                colorPicker

                MoblyTextField(label: "Nom complet", placeholder: "Votre nom",
                               systemIcon: "person", text: $name, autocapitalization: .words)
                MoblyTextField(label: "Adresse e-mail", placeholder: "votre@email.com",
                               systemIcon: "envelope", text: $email, keyboard: .emailAddress)

                // Phone shown but not editable here — it's the account
                // identifier, and changing it has to re-verify by SMS.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Téléphone")
                        .font(.moblyBody(12.5, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x6B6F80))
                    HStack(spacing: 10) {
                        Image(systemName: "phone")
                            .font(.system(size: 15))
                            .foregroundStyle(Color(hex: 0x9A9DAC))
                        Text(phone.isEmpty ? "—" : phone)
                            .font(.moblyBody(14, weight: .medium))
                            .foregroundStyle(Color(hex: 0x6B6F80))
                        Spacer()
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(hex: 0xC4C7D2))
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 54)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0xECEDF2)))
                }

                // Ville is detected from the device, not typed — so it stays
                // consistent with the listings shown nearby and can't be set
                // to a city the user isn't actually in.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ville")
                        .font(.moblyBody(12.5, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x6B6F80))
                    HStack(spacing: 10) {
                        Image(systemName: "mappin")
                            .font(.system(size: 15))
                            .foregroundStyle(Color(hex: 0x9A9DAC))
                        Text(detectedCity)
                            .font(.moblyBody(14, weight: .medium))
                            .foregroundStyle(detectedCity == "Position non autorisée"
                                             ? Color(hex: 0x9A9DAC) : Color(hex: 0x6B6F80))
                        Spacer()
                        if location.status == .resolving {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Image(systemName: "location.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Color(hex: 0xC4C7D2))
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 54)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0xECEDF2)))

                    if location.status == .denied {
                        Button("Autoriser la localisation") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .font(.moblyBody(11.5, weight: .semibold))
                        .foregroundStyle(Color.moblyPrimary)
                    }
                }

                if let saveError {
                    Text(saveError)
                        .font(.moblyBody(12.5, weight: .medium))
                        .foregroundStyle(Color.moblyAccent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                PillButton(title: isSaving ? "Enregistrement…" : "Enregistrer",
                           style: .primaryBlue, trailingIcon: nil) {
                    Task { await save() }
                }
                .opacity(canSave && !isSaving ? 1 : 0.5)
                .disabled(!canSave || isSaving)
                .padding(.top, 6)
            }
        }
        // Keyed on the user id so it re-runs when bootstrap finishes. A plain
        // `.task` fires once at render, before the account has loaded, and the
        // fields would stay blank on a real profile.
        .task(id: auth.user?.id) {
            guard let u = auth.user else { return }
            name = u.fullName
            email = u.email ?? ""
            avatarColor = u.avatarColor
        }
            // Mobly draws its own tab bar, so the system `.toolbar(.hidden,
            // for: .tabBar)` does nothing — use the shared chrome flag.
            .hidesMoblyTabBar()

            // Full-screen save state — spinner while POSTing, then a big
            // green checkmark that fades before dismissing to Profile.
            if isSaving || savedSuccess {
                Color.black.opacity(0.28).ignoresSafeArea()
                    .transition(.opacity)
                VStack(spacing: 12) {
                    if savedSuccess {
                        ZStack {
                            Circle().fill(Color(hex: 0x1F8A5B)).frame(width: 66, height: 66)
                            Image(systemName: "checkmark")
                                .font(.system(size: 32, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .transition(.scale.combined(with: .opacity))
                        Text("Enregistré")
                            .font(.moblyHeading(15))
                            .foregroundStyle(Color.moblyTextPrimary)
                    } else {
                        ProgressView()
                            .scaleEffect(1.4)
                            .tint(Color.moblyPrimary)
                        Text("Enregistrement…")
                            .font(.moblyHeading(14))
                            .foregroundStyle(Color.moblyTextPrimary)
                    }
                }
                .padding(28)
                .background(RoundedRectangle(cornerRadius: 20).fill(.white)
                    .shadow(color: .black.opacity(0.15), radius: 18, y: 8))
                .transition(.opacity)
            }
        }
        .animation(Motion.quick, value: isSaving)
        .animation(Motion.panel, value: savedSuccess)
    }

    /// Row of preset colour bubbles. Tap to select — the change is committed
    /// with the same "Enregistrer" button as the rest of the form so a user
    /// can preview without spending a network round-trip on every swatch.
    private var colorPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Votre couleur")
                .font(.moblyBody(12.5, weight: .semibold))
                .foregroundStyle(Color(hex: 0x6B6F80))

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5),
                spacing: 12
            ) {
                ForEach(AvatarPalette.presets, id: \.self) { hex in
                    Button {
                        UISelectionFeedbackGenerator().selectionChanged()
                        withAnimation(Motion.instant) {
                            avatarColor = hex
                        }
                    } label: {
                        ZStack {
                            Circle().fill(
                                LinearGradient(colors: [
                                    Color(hex: hex), AvatarPalette.darker(hex)
                                ], startPoint: .top, endPoint: .bottom)
                            )
                            if selectedHex.caseInsensitiveCompare(hex) == .orderedSame {
                                Circle().stroke(Color.moblyTextPrimary, lineWidth: 3)
                                    .padding(-4)
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selectedHex: String {
        AvatarPalette.hex(for: auth.user?.id ?? "self", stored: avatarColor)
    }

    private var canSave: Bool {
        name.trimmingCharacters(in: .whitespaces).count >= 2
            && (email.isEmpty || (email.contains("@") && email.contains(".")))
    }

    /// Turn the PhotosPicker selection into JPEG data, POST it to
    /// `/uploads/avatar`, and refresh the auth user so the new photo is
    /// reflected everywhere immediately. Errors surface as `saveError` so
    /// the user isn't left guessing when a slow connection drops the upload.
    private func handleAvatarPick(_ item: PhotosPickerItem) async {
        await MainActor.run {
            uploadingAvatar = true
            uploadSpin = true
        }
        defer {
            Task { @MainActor in
                uploadingAvatar = false
                uploadSpin = false
                pickerItems = []
            }
        }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let jpeg = compressAvatar(data) else {
            await MainActor.run { saveError = "Impossible de lire l'image." }
            return
        }
        do {
            let url = try await MoblyAPI.shared.uploadAvatar(jpeg)
            await MainActor.run {
                // Flip the local user immediately so the profile card /
                // edit sheet / chat rows update without waiting on /me.
                AuthStore.shared.applyAvatarUrl(url)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            // Bootstrap in the background to reconcile any drift with the
            // server (rare, but keeps everything else — verified flag,
            // rating — up to date).
            await AuthStore.shared.bootstrap()
        } catch let e as MoblyAPI.APIError {
            await MainActor.run {
                saveError = e.isOffline
                    ? "Pas de connexion. Réessayez."
                    : "Envoi impossible : \(e.message)"
            }
        } catch {
            await MainActor.run { saveError = "Envoi impossible. Réessayez." }
        }
    }

    private func compressAvatar(_ data: Data) -> Data? {
        guard let ui = UIImage(data: data) else { return nil }
        // Down-scale big camera images to a reasonable 512px square so uploads
        // are quick on mobile networks and Cloudinary storage stays small.
        let side: CGFloat = 512
        let size = CGSize(width: side, height: side)
        UIGraphicsBeginImageContextWithOptions(size, false, 1)
        let scale = max(side / ui.size.width, side / ui.size.height)
        let drawSize = CGSize(width: ui.size.width * scale, height: ui.size.height * scale)
        let origin = CGPoint(x: (side - drawSize.width) / 2,
                             y: (side - drawSize.height) / 2)
        ui.draw(in: CGRect(origin: origin, size: drawSize))
        let out = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return out?.jpegData(compressionQuality: 0.85)
    }

    private func save() async {
        isSaving = true
        saveError = nil
        do {
            _ = try await MoblyAPI.shared.updateMe(
                fullName: name.trimmingCharacters(in: .whitespaces),
                email: email.isEmpty ? nil : email.trimmingCharacters(in: .whitespaces).lowercased(),
                avatarColor: avatarColor != auth.user?.avatarColor ? avatarColor : nil
            )
            await auth.bootstrap()   // refresh the cached user
            await MainActor.run {
                isSaving = false
                savedSuccess = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            // Hold the success card just long enough to read, then bounce
            // the user back to their Profile tab.
            try? await Task.sleep(nanoseconds: 750_000_000)
            await MainActor.run {
                savedSuccess = false
                dismiss()
            }
        } catch let e as MoblyAPI.APIError {
            await MainActor.run {
                isSaving = false
                saveError = e.code == .alreadyExists
                    ? "Cet e-mail est déjà utilisé par un autre compte."
                    : e.message
            }
        } catch {
            await MainActor.run {
                isSaving = false
                saveError = "Enregistrement impossible. Réessayez."
            }
        }
    }
}

// MARK: - Language

struct LanguageView: View {
    @ObservedObject private var lang = AppLang.shared
    private let langs = [("Français", "🇫🇷", "fr"), ("English", "🇬🇧", "en")]
    @State private var switching = false
    @State private var pendingCode: String? = nil

    var body: some View {
        ProfileScaffold(title: "Langue") {
            card {
                VStack(spacing: 0) {
                    ForEach(Array(langs.enumerated()), id: \.offset) { i, l in
                        Button { select(l.2) } label: {
                            HStack(spacing: 12) {
                                Text(l.1).font(.system(size: 22))
                                Text(l.0).font(.moblyBody(14.5, weight: .medium)).foregroundStyle(Color.moblyTextPrimary)
                                Spacer()
                                if pendingCode == l.2 {
                                    ProgressView().tint(Color.moblyPrimary)
                                } else if lang.code == l.2 {
                                    Image(systemName: "checkmark.circle.fill").font(.system(size: 20))
                                        .foregroundStyle(Color.moblyPrimary)
                                }
                            }
                            .padding(.vertical, 13).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if i < langs.count - 1 { Divider().padding(.leading, 34) }
                    }
                }
            }
            .disabled(switching)
        }
        .overlay { if switching { loadingOverlay } }
        .onAppear {
            // Pidgin was removed — fold any stale selection back to French.
            if !langs.contains(where: { $0.2 == lang.code }) { lang.code = "fr" }
        }
    }

    private func select(_ code: String) {
        guard code != lang.code, !switching else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        pendingCode = code
        withAnimation(Motion.instant) { switching = true }
        // Flip the shared flag so RootView shows its app-wide overlay while
        // the switch propagates. Short delay lets the spinner render.
        lang.switching = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            lang.code = code
            pendingCode = nil
            withAnimation(Motion.quick) { switching = false }
            // Give the .id(lang.code) subtree rebuild a beat to paint,
            // then drop the overlay.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                lang.switching = false
            }
        }
    }

    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.12).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().scaleEffect(1.3).tint(Color.moblyPrimary)
                Text(L("Changement de langue…"))
                    .font(.moblyBody(13.5, weight: .medium))
                    .foregroundStyle(Color.moblyTextSecondary)
            }
            .padding(.vertical, 26).padding(.horizontal, 32)
            .background(RoundedRectangle(cornerRadius: 20).fill(.white)
                .shadow(color: Color(hex: 0x14152A).opacity(0.12), radius: 20, y: 8))
        }
        .transition(.opacity)
    }
}

// MARK: - Notifications settings

struct NotificationsSettingsView: View {
    @State private var messages = true
    @State private var visits = true
    @State private var newSpaces = true
    @State private var priceDrops = true
    @State private var alerts = false
    @State private var promos = false

    var body: some View {
        ProfileScaffold(title: "Notifications") {
            card {
                VStack(spacing: 0) {
                    toggleRow("Messages", "bubble.left.fill", $messages)
                    Divider().padding(.leading, 46)
                    toggleRow("Visites confirmées", "calendar", $visits)
                    Divider().padding(.leading, 46)
                    toggleRow("Nouveaux espaces", "sparkles", $newSpaces)
                    Divider().padding(.leading, 46)
                    toggleRow("Baisses de prix", "arrow.down.circle.fill", $priceDrops)
                    Divider().padding(.leading, 46)
                    toggleRow("Alertes de recherche", "bell.fill", $alerts)
                    Divider().padding(.leading, 46)
                    toggleRow("Promotions Mobly", "megaphone.fill", $promos)
                }
            }
        }
    }

    private func toggleRow(_ label: String, _ icon: String, _ binding: Binding<Bool>) -> some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(Color.moblySurfaceTint).frame(width: 32, height: 32)
                Image(systemName: icon).font(.system(size: 14, weight: .medium)).foregroundStyle(Color.moblyPrimary)
            }
            Text(LT(label)).font(.moblyBody(13.5, weight: .medium)).foregroundStyle(Color.moblyTextPrimary)
            Spacer()
            Toggle("", isOn: binding).labelsHidden().tint(Color.moblyPrimary)
        }
        .padding(.vertical, 9)
    }
}

// MARK: - Saved searches

struct SavedSearchesView: View {
    /// Read the real store. This screen used to render `FavoritesData.searches`
    /// — a hardcoded empty array — so it was permanently blank no matter how
    /// many searches the user had saved from Explore.
    @ObservedObject private var store = SavedSearchStore.shared

    var body: some View {
        ProfileScaffold(title: "Recherches enregistrées") {
            VStack(spacing: 12) {
                if store.items.isEmpty {
                    emptyState
                } else {
                    ForEach(store.items) { item in
                        SavedSearchManageRow(item: item) { store.remove(item) }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Color(hex: 0xD5D8E2))
            Text("Aucune recherche enregistrée")
                .font(.moblyBody(14, weight: .medium))
                .foregroundStyle(Color(hex: 0x9A9DAC))
            Text("Lancez une recherche depuis Explorer : elle sera gardée ici.")
                .font(.moblyBody(12.5))
                .foregroundStyle(Color(hex: 0xB0B3BF))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

/// One saved search, with the filters it carries and a way to delete it.
private struct SavedSearchManageRow: View {
    let item: SavedSearchItem
    var onDelete: () -> Void

    private var summary: String {
        let n = item.filters.count
        if n == 0 { return "Aucun filtre" }
        return n == 1 ? "1 filtre" : "\(n) filtres"
    }

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 13).fill(Color.moblySurfaceTint)
                    .frame(width: 48, height: 48)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.moblyPrimary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.label)
                    .font(.moblyHeading(15))
                    .foregroundStyle(Color.moblyTextPrimary)
                Text(LT(summary))
                    .font(.moblyBody(11.5))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
            }
            Spacer()
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xE5484D))
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0xFDEDED)))
            }
            .buttonStyle(.plain)
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 18).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: 0xEFF0F4), lineWidth: 1))
    }
}

// MARK: - Help center

struct HelpCenterView: View {
    /// A topic card: tapping it opens the support chat with a question about
    /// that topic already asked, so the assistant answers straight away.
    private struct Topic: Identifiable {
        let id = UUID()
        let title: String
        let icon: String
        let color: UInt32
        let question: String
    }

    private let topics: [Topic] = [
        Topic(title: "Mon compte", icon: "person.crop.circle", color: 0xFF7BB5,
              question: "J'ai une question sur mon compte."),
        Topic(title: "Paiement", icon: "creditcard", color: 0xA98BFA,
              question: "J'ai une question sur un paiement."),
        Topic(title: "Mes annonces", icon: "house", color: 0x5AD2F4,
              question: "J'ai une question sur mes annonces."),
        Topic(title: "Visites", icon: "calendar", color: 0xFFC857,
              question: "J'ai une question sur une visite."),
        Topic(title: "Vérification", icon: "checkmark.shield", color: 0x6EE7A8,
              question: "Comment vérifier mon identité ?"),
    ]

    /// Questions with real answers, expanding in place.
    private let faqs: [(q: String, a: String)] = [
        ("Comment contacter un propriétaire ?",
         "Ouvrez l'annonce puis touchez « Message ». La conversation reste dans Mobly : votre numéro n'est jamais partagé."),
        ("Comment planifier une visite ?",
         "Depuis l'annonce, touchez « Demander une visite » et proposez une date. Le propriétaire confirme ou propose un autre créneau, et vous recevez une notification."),
        ("Comment fonctionne la vérification ?",
         "Nous contrôlons votre pièce d'identité via un prestataire spécialisé. Mobly ne conserve aucune copie de vos documents. La vérification est obligatoire pour publier une annonce."),
        ("Pourquoi mon annonce est en attente ?",
         "Une annonce est mise en ligne immédiatement quand votre identité est vérifiée. Sinon elle reste en attente, et elle est publiée automatiquement dès que la vérification est validée."),
        ("Les prix sont-ils négociables ?",
         "Cela dépend du propriétaire. Proposez votre prix directement dans la conversation."),
        ("Comment signaler une annonce ?",
         "Ouvrez l'annonce ou le profil concerné et touchez « Signaler ». Notre équipe examine chaque signalement."),
    ]

    @ObservedObject private var auth = AuthStore.shared
    @ObservedObject private var config = RemoteConfigStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var expanded: Int?
    @State private var openingSupport = false
    @State private var pendingQuestion: String?
    @State private var supportThread: ChatThread?
    @State private var supportFailed = false

    /// Support chat can be switched off remotely, in which case the entry
    /// points fall back to e-mail rather than leaving no way to reach anyone.
    private var chatAvailable: Bool { config.isEnabled("support.chat") && auth.isSignedIn }
    private var supportEmail: String { config.config.copy.supportEmail ?? "support@mobly.cm" }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Questions liées")
                        .font(.moblyHeading(26))
                        .foregroundStyle(Color.moblyTextPrimary)
                        .padding(.horizontal, 22)
                        .padding(.top, 18)
                        .padding(.bottom, 16)

                    topicCards
                        .padding(.bottom, 32)

                    Text("Questions\nfréquentes")
                        .font(.moblyHeading(26))
                        .foregroundStyle(Color.moblyTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 22)
                        .padding(.bottom, 16)

                    VStack(spacing: 10) {
                        ForEach(Array(faqs.enumerated()), id: \.offset) { i, item in
                            faqRow(i, item)
                        }
                    }
                    .padding(.horizontal, 22)

                    if !chatAvailable {
                        PillButton(title: "Écrire à \(supportEmail)",
                                   style: .primaryBlue,
                                   trailingIcon: "envelope.fill") {
                            if let url = URL(string: "mailto:\(supportEmail)") {
                                UIApplication.shared.open(url)
                            }
                        }
                        .padding(.horizontal, 22)
                        .padding(.top, 24)
                    }
                }
                // Clears the floating tab bar so the last question is reachable.
                .padding(.bottom, 120)
            }
        }
        .background(Color.white.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(isPresented: $openingSupport) {
            SupportOpeningView(
                // Presenting the chat while this cover is still dismissing is
                // silently dropped by SwiftUI, so wait for it to finish.
                onOpened: { thread in
                    openingSupport = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        supportThread = thread
                    }
                },
                onFailed: {
                    openingSupport = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        supportFailed = true
                    }
                },
                onBack: { openingSupport = false }
            )
            .swipeToDismiss(onDismiss: { openingSupport = false })
        }
        .fullScreenCover(item: $supportThread) { thread in
            SupportChatView(thread: thread,
                            initialQuestion: pendingQuestion,
                            onBack: { supportThread = nil; pendingQuestion = nil })
        }
        .alert("Support indisponible", isPresented: $supportFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(LT("Impossible d'ouvrir la conversation. Réessayez, ou écrivez à \(supportEmail)."))
        }
    }

    private func openChat(asking question: String? = nil) {
        guard chatAvailable else {
            if let url = URL(string: "mailto:\(supportEmail)") { UIApplication.shared.open(url) }
            return
        }
        pendingQuestion = question
        openingSupport = true
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "arrow.left")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color(hex: 0xF1F2F5)))
            }
            .buttonStyle(.plain)
            Spacer()
            Button { openChat() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 15, weight: .medium))
                    Text("Chat support")
                        .font(.moblyBody(14, weight: .medium))
                }
                .foregroundStyle(Color.moblyTextPrimary)
                .padding(.horizontal, 16).frame(height: 44)
                .background(Capsule().fill(Color(hex: 0xF1F2F5)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
    }

    // MARK: Topic cards

    private var topicCards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(topics) { t in
                    Button { openChat(asking: t.question) } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(alignment: .top) {
                                ZStack {
                                    Circle().fill(.white).frame(width: 44, height: 44)
                                    Image(systemName: t.icon)
                                        .font(.system(size: 18, weight: .medium))
                                        .foregroundStyle(Color.moblyTextPrimary)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 22, weight: .light))
                                    .foregroundStyle(Color.moblyTextPrimary)
                            }
                            Spacer()
                            Text(t.title)
                                .font(.moblyBody(16, weight: .medium))
                                .foregroundStyle(Color.moblyTextPrimary)
                        }
                        .padding(14)
                        .frame(width: 150, height: 160)
                        .background(RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(Color(hex: t.color)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 22)
        }
    }

    // MARK: FAQ

    private func faqRow(_ i: Int, _ item: (q: String, a: String)) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Motion.quick) { expanded = (expanded == i) ? nil : i }
            } label: {
                HStack(alignment: .top) {
                    Text(LT(item.q))
                        .font(.moblyBody(15))
                        .foregroundStyle(Color.moblyTextPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Image(systemName: expanded == i ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.moblyTextPrimary)
                        .padding(.top, 3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded == i {
                VStack(alignment: .leading, spacing: 10) {
                    Text(LT(item.a))
                        .font(.moblyBody(13.5))
                        .foregroundStyle(Color(hex: 0x3A3D4A))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if chatAvailable {
                        Button { openChat(asking: item.q) } label: {
                            Text("Poser la question au support")
                                .font(.moblyBody(12.5, weight: .semibold))
                                .foregroundStyle(Color.moblyPrimary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 10)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color(hex: 0xF1F2F5)))
    }
}

/// Opens the support conversation, then hands it to `ChatThreadView`.
///
/// Mirrors `ChatOpeningView` for listings: the screen appears at once and the
/// network call resolves behind it, because on a Douala connection the round
/// trip is slow enough that an un-styled wait reads as a broken button.
private struct SupportOpeningView: View {
    var onOpened: (ChatThread) -> Void
    var onFailed: () -> Void
    var onBack: () -> Void

    @ObservedObject private var chat = ChatStore.shared
    @ObservedObject private var auth = AuthStore.shared

    var body: some View {
        ZStack {
            Color.moblySurface.ignoresSafeArea()
            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(Color.moblySurfaceTint).frame(width: 76, height: 76)
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(Color.moblyPrimary)
                }
                Text("Support Mobly")
                    .font(.moblyHeading(19))
                    .foregroundStyle(Color.moblyTextPrimary)
                ProgressView()
            }
        }
        .task {
            guard let dto = await chat.openSupportThread() else {
                onFailed()
                return
            }
            onOpened(ChatThread.from(dto, myUserId: auth.user?.id))
        }
        .overlay(alignment: .topLeading) {
            Button(action: onBack) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(.white))
            }
            .padding(.leading, 18)
            .padding(.top, 8)
        }
    }
}

// MARK: - Privacy & security

struct PrivacySecurityView: View {
    // Settings persist to UserDefaults so they survive relaunches. When the
    // backend grows dedicated fields (call-masking, 2FA), swap the read /
    // write path here without touching the UI.
    @AppStorage("privacy.maskNumber") private var maskNumber: Bool = true
    @AppStorage("privacy.twoFA")      private var twoFA: Bool = false
    @ObservedObject private var blocked = BlockedUsers.shared
    @State private var showChangePassword = false
    @State private var showBlocked = false
    @State private var showExportShare: URL?
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var deleteError: String?
    @State private var busyExport = false

    var body: some View {
        ProfileScaffold(title: "Confidentialité & sécurité") {
            VStack(spacing: 16) {
                card {
                    VStack(spacing: 0) {
                        Button { showChangePassword = true } label: {
                            navRow("Changer le mot de passe", "key.fill")
                        }.buttonStyle(.plain)
                        Divider().padding(.leading, 46)
                        toggle("Numéro masqué lors des appels", "phone.badge.waveform.fill", $maskNumber)
                        Divider().padding(.leading, 46)
                        toggle("Authentification à deux facteurs", "lock.shield.fill", $twoFA)
                        Divider().padding(.leading, 46)
                        Button { showBlocked = true } label: {
                            navRow("Utilisateurs bloqués (\(blocked.ids.count))", "hand.raised.fill")
                        }.buttonStyle(.plain)
                    }
                }
                card {
                    VStack(spacing: 0) {
                        Button { exportData() } label: {
                            HStack(spacing: 13) {
                                iconBox("arrow.down.doc.fill", 0x3A4FF0)
                                Text(busyExport ? "Préparation…" : "Télécharger mes données")
                                    .font(.moblyBody(13.5, weight: .medium))
                                    .foregroundStyle(Color.moblyTextPrimary)
                                Spacer()
                                if busyExport { ProgressView().scaleEffect(0.7) }
                                else {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Color(hex: 0xC4C7D2))
                                }
                            }.padding(.vertical, 11)
                        }.buttonStyle(.plain)
                        Divider().padding(.leading, 46)
                        Button { if RemoteConfigStore.shared.can("account.delete") { confirmDelete = true } } label: {
                            HStack(spacing: 13) {
                                iconBox("trash.fill", 0xE5484D)
                                Text("Supprimer mon compte").font(.moblyBody(13.5, weight: .medium))
                                    .foregroundStyle(Color(hex: 0xE5484D))
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color(hex: 0xC4C7D2))
                            }.padding(.vertical, 11)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .sheet(isPresented: $showChangePassword) { ChangePasswordSheet() }
        .sheet(isPresented: $showBlocked)        { BlockedUsersSheet() }
        .sheet(item: $showExportShare)           { url in ShareSheet(url: url) }
        .alert("Supprimer votre compte ?",
               isPresented: $confirmDelete) {
            Button("Supprimer", role: .destructive) {
                // This used only to sign out, while promising the account and
                // its data were gone — the user stayed fully intact on the
                // server and could sign straight back in.
                Task {
                    deleting = true
                    defer { deleting = false }
                    do {
                        try await MoblyAPI.shared.deleteAccount()
                        await AuthStore.shared.signOut(allDevices: true)
                    } catch let e as MoblyAPI.APIError {
                        deleteError = e.message
                    } catch {
                        deleteError = "Suppression impossible. Réessayez."
                    }
                }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Votre compte, vos annonces, vos favoris et vos messages seront définitivement supprimés. Cette action est irréversible.")
        }
        .alert("Suppression impossible", isPresented: Binding(
            get: { deleteError != nil }, set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
    }

    /// Snapshot the user's basic data into a JSON file and open a share
    /// sheet so they can save it to Files / e-mail it / send to themselves.
    private func exportData() {
        busyExport = true
        Task {
            let u = AuthStore.shared.user
            let payload: [String: Any] = [
                "id": u?.id ?? "",
                "fullName": u?.fullName ?? "",
                "phone": u?.phone ?? "",
                "email": u?.email as Any,
                "city": u?.city as Any,
                "region": u?.region as Any,
                "createdAt": ISO8601DateFormatter().string(from: Date()),
                "favorites": UserDataStore.shared.favorites.map { ["id": $0.id, "title": $0.title] },
                "notifications": UserDataStore.shared.notifications.count,
            ]
            let data = try? JSONSerialization.data(withJSONObject: payload,
                                                   options: [.prettyPrinted, .sortedKeys])
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("mobly-export-\(u?.id ?? "me").json")
            try? data?.write(to: url, options: .atomic)
            await MainActor.run {
                busyExport = false
                showExportShare = url
            }
        }
    }

    private func iconBox(_ icon: String, _ color: UInt32) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9).fill(Color(hex: color).opacity(0.12)).frame(width: 32, height: 32)
            Image(systemName: icon).font(.system(size: 14, weight: .medium)).foregroundStyle(Color(hex: color))
        }
    }
    private func navRow(_ label: String, _ icon: String) -> some View {
        HStack(spacing: 13) {
            iconBox(icon, 0x3A4FF0)
            Text(LT(label)).font(.moblyBody(13.5, weight: .medium)).foregroundStyle(Color.moblyTextPrimary)
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(hex: 0xC4C7D2))
        }.padding(.vertical, 11)
    }
    private func toggle(_ label: String, _ icon: String, _ b: Binding<Bool>) -> some View {
        HStack(spacing: 13) {
            iconBox(icon, 0x3A4FF0)
            Text(LT(label)).font(.moblyBody(13.5, weight: .medium)).foregroundStyle(Color.moblyTextPrimary)
            Spacer()
            Toggle("", isOn: b).labelsHidden().tint(Color.moblyPrimary)
        }.padding(.vertical, 7)
    }
}

// MARK: - Change password sheet

private struct ChangePasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var newPass = ""
    @State private var confirm = ""
    @State private var saving = false
    @State private var errorMsg: String?
    @State private var doneMsg: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("Choisissez un nouveau mot de passe. Il remplacera l'actuel sur ce compte.")
                    .font(.moblyBody(12.5))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                    .padding(.top, 8)
                SecureField("Nouveau mot de passe", text: $newPass)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0xF4F5F8)))
                SecureField("Confirmer le mot de passe", text: $confirm)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0xF4F5F8)))
                if let e = errorMsg {
                    Text(LT(e)).font(.moblyBody(12)).foregroundStyle(Color(hex: 0xE5484D))
                }
                if let d = doneMsg {
                    Text(d).font(.moblyBody(12)).foregroundStyle(Color(hex: 0x1F8A5B))
                }
                Spacer()
                Button {
                    Task { await save() }
                } label: {
                    Text(saving ? "Enregistrement…" : "Enregistrer")
                        .font(.moblyHeading(15))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .background(Capsule().fill(canSave ? Color.moblyPrimary : Color(hex: 0xC4C7D2)))
                }
                .buttonStyle(.plain).disabled(!canSave || saving)
            }
            .padding(20)
            .navigationTitle("Nouveau mot de passe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fermer") { dismiss() } } }
        }
        .presentationDetents([.height(360)])
    }

    private var canSave: Bool { newPass.count >= 6 && newPass == confirm }

    private func save() async {
        saving = true; errorMsg = nil; doneMsg = nil
        defer { saving = false }
        await AuthStore.shared.setPassword(newPass)
        doneMsg = "Mot de passe mis à jour."
        try? await Task.sleep(nanoseconds: 900_000_000)
        await MainActor.run { dismiss() }
    }
}

// MARK: - Blocked users sheet

private struct BlockedUsersSheet: View {
    @ObservedObject private var blocked = BlockedUsers.shared
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Group {
                if blocked.ids.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "hand.raised")
                            .font(.system(size: 34)).foregroundStyle(Color(hex: 0xC4C7D2))
                        Text("Aucun utilisateur bloqué")
                            .font(.moblyHeading(15))
                            .foregroundStyle(Color.moblyTextPrimary)
                        Text("Bloquez quelqu'un depuis son profil de discussion.")
                            .font(.moblyBody(12.5))
                            .foregroundStyle(Color(hex: 0x9A9DAC))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(Array(blocked.ids), id: \.self) { id in
                            HStack {
                                Text(id).font(.moblyBody(13, weight: .medium))
                                Spacer()
                                Button("Débloquer") { blocked.unblock(id) }
                                    .font(.moblyBody(12, weight: .semibold))
                                    .foregroundStyle(Color.moblyPrimary)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Utilisateurs bloqués")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fermer") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Share sheet wrapper

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

// MARK: - About

/// App Store identity.
/// ⚠️ À COMPLÉTER : remplacer `appID` par l'identifiant Apple réel dès la
/// première fiche créée dans App Store Connect, sinon « Noter Mobly » ouvre
/// une page introuvable.
enum MoblyAppStore {
    static let appID = "0000000000"

    /// Ouvre directement le formulaire d'avis sur la fiche App Store.
    static var writeReviewURL: URL? {
        URL(string: "https://apps.apple.com/app/id\(appID)?action=write-review")
    }
}

struct AboutView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        ProfileScaffold(title: "À propos de Mobly") {
            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    Text("mobly").font(.moblyWordmark(size: 40)).foregroundStyle(Color.moblyPrimary)
                    Text("Votre espace, à portée de main.")
                        .font(.moblyBody(13)).foregroundStyle(Color(hex: 0x9A9DAC))
                    Text("Version 1.0.0").font(.moblyBody(12)).foregroundStyle(Color(hex: 0xC4C7D2))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 20)

                card {
                    VStack(spacing: 0) {
                        NavigationLink { LegalDocumentView(doc: LegalLibrary.cgu) } label: {
                            aboutRow("Conditions d'utilisation")
                        }.buttonStyle(.plain)
                        Divider()
                        NavigationLink { LegalDocumentView(doc: LegalLibrary.confidentialite) } label: {
                            aboutRow("Politique de confidentialité")
                        }.buttonStyle(.plain)
                        Divider()
                        NavigationLink { LegalHubView() } label: {
                            aboutRow("Tous les documents légaux")
                        }.buttonStyle(.plain)
                        Divider()
                        NavigationLink { LegalDocumentView(doc: LegalLibrary.mentionsLegales) } label: {
                            aboutRow("Mentions légales")
                        }.buttonStyle(.plain)
                        Divider()
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            if let url = MoblyAppStore.writeReviewURL { openURL(url) }
                        } label: {
                            aboutRow("Noter Mobly sur l'App Store ⭐️")
                        }.buttonStyle(.plain)
                        Divider(); aboutRow("Site web · mobly.cm")
                    }
                }
                Text("© 2026 Mobly · Douala, Cameroun")
                    .font(.moblyBody(11.5)).foregroundStyle(Color(hex: 0xC4C7D2))
                    .frame(maxWidth: .infinity).padding(.top, 6)
            }
        }
    }
    private func aboutRow(_ label: String) -> some View {
        HStack {
            Text(LT(label)).font(.moblyBody(13.5)).foregroundStyle(Color.moblyTextPrimary)
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(hex: 0xC4C7D2))
        }.padding(.vertical, 13).contentShape(Rectangle())
    }
}

// MARK: - Become owner
//
// Step-by-step wizard for the visitor → propriétaire upgrade. Presented full
// screen so the app's tab bar is hidden — this is a dedicated moment, not a
// menu row. Each step is single-focus: welcome, benefits, how-it-works,
// social proof, confirm. Progress dots at the top let the user see how far
// they've come; the header carries a Back button and a Skip → to the final
// confirm step.

struct BecomeOwnerView: View {
    var onClose: () -> Void = {}
    /// Called instead of `onClose` once the first annonce has been handed to
    /// the publisher, so the presenter can open the owner dashboard where it
    /// shows as "Publication…". Falls back to `onClose` when nil.
    var onPublished: (() -> Void)? = nil

    @ObservedObject private var listingStore = ListingStore.shared
    @ObservedObject private var auth = AuthStore.shared

    @State private var step: Int = {
        if let s = ProcessInfo.processInfo.environment["BECOME_OWNER_STEP"], let i = Int(s) {
            return max(0, min(i, 4))
        }
        return 0
    }()
    @State private var showCelebration = false
    @State private var showAddListing = false
    @State private var showVerification = false
    @State private var showPayment = false
    /// The plan chosen on the pricing step. Defaults to the free trial, which
    /// is the offer we lead with on the home banner.
    @State private var selectedPlan: OwnerPlan = .trial

    private let totalSteps = 6

    /// Whether the KYC step applies at all. Driven by the same
    /// `owners.identityRequired` switch the server enforces, so relaxing the
    /// rule from the dashboard also removes the step here — rather than the
    /// app demanding a check the backend no longer asks for.
    private var kycRequired: Bool {
        RemoteConfigStore.shared.isEnabled("owners.identityRequired")
    }

    private var isIdentityVerified: Bool {
        !kycRequired || auth.user?.identityVerified == true
    }

    private var listingsCount: Int { max(listingStore.listings.count, 126) }
    private var citiesCount: Int {
        max(Set(listingStore.listings.compactMap {
            $0.location.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) }
        }).count, 7)
    }

    var body: some View {
        ZStack {
            Color(hex: 0xF7F8FA).ignoresSafeArea()

            VStack(spacing: 0) {
                progressHeader
                    .padding(.horizontal, 20)
                    .padding(.top, 10)

                stepContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                footer
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 30)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .fullScreenCover(isPresented: $showCelebration) {
            CelebrationView(onDone: {
                Session.shared.upgradeToOwner()
                showCelebration = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    showAddListing = true
                }
            })
            .swipeToDismiss(onDismiss: { showCelebration = false })
        }
        // AddListing presents on top of BecomeOwnerView. Whether the user
        // publishes, skips, or hits ✕, we dismiss both covers and let Profile
        // — now in owner mode — take over. The dashboard is one tap away as
        // "Mon espace propriétaire" on the profile screen.
        .fullScreenCover(isPresented: $showAddListing) {
            AddListingView(
                showSkipButton: true,
                onSkip: {
                    showAddListing = false
                    onClose()
                }
            ) { _ in
                // The publish sheet already put the annonce on the dashboard.
                showAddListing = false
                if let onPublished { onPublished() } else { onClose() }
            }
            .swipeToDismiss(onDismiss: {
                showAddListing = false
                onClose()
            })
        }
        .fullScreenCover(isPresented: $showPayment) {
            OwnerPaymentView(
                plan: .paid,
                oneTime: true,
                onCancel: { showPayment = false },
                onPaid: {
                    showPayment = false
                    // Paid up front → become an active owner. Identity
                    // verification still runs first when KYC applies.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { activateOwner() }
                }
            )
            .swipeToDismiss(onDismiss: { showPayment = false })
        }
        .fullScreenCover(isPresented: $showVerification) {
            NavigationStack {
                IdentityVerificationView()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                showVerification = false
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.moblyTextPrimary)
                            }
                        }
                    }
            }
            .swipeToDismiss(onDismiss: { showVerification = false })
        }
        .onChange(of: showVerification) { showing in
            if !showing {
                // Verification sheet closed — refresh the user, and if identity
                // is now confirmed, complete the owner upgrade and celebrate.
                Task {
                    await auth.bootstrap()
                    await MainActor.run {
                        if isIdentityVerified && !showCelebration && !showAddListing {
                            finishOwnerUpgrade()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Header

    private var progressHeader: some View {
        HStack(spacing: 14) {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                if step == 0 { onClose() }
                else { withAnimation(Motion.quick) { step -= 1 } }
            } label: {
                Image(systemName: step == 0 ? "xmark" : "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(.white))
                    .shadow(color: Color(hex: 0x14152A).opacity(0.06), radius: 6, y: 2)
            }

            HStack(spacing: 6) {
                ForEach(0..<totalSteps, id: \.self) { i in
                    Capsule()
                        .fill(i <= step ? Color.moblyPrimary : Color(hex: 0xE2E4EC))
                        .frame(height: 5)
                        .animation(Motion.quick, value: step)
                }
            }
            .frame(maxWidth: .infinity)

            if step < totalSteps - 1 {
                Button {
                    withAnimation(Motion.quick) { step = totalSteps - 1 }
                } label: {
                    Text("Passer")
                        .font(.moblyBody(13, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x9A9DAC))
                }
            } else {
                Color.clear.frame(width: 50, height: 1)
            }
        }
    }

    // MARK: - Step body

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case 0: StepIntro()
        case 1: StepBenefits()
        case 2: StepHowItWorks()
        case 3: StepSocialProof(listingsCount: listingsCount, citiesCount: citiesCount)
        case 4: StepConfirm()
        default: StepPricing(selectedPlan: $selectedPlan)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 8) {
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                if step < totalSteps - 1 {
                    withAnimation(Motion.quick) { step += 1 }
                } else {
                    SessionTracker.shared.log("owner.plan_selected", ["plan": selectedPlan.analyticsId])
                    if selectedPlan == .paid {
                        // Pay the 5 000 FCFA now → active straight away, no trial.
                        showPayment = true
                    } else {
                        // Free 7-day trial, no payment now.
                        activateOwner()
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(step == totalSteps - 1 ? selectedPlan.ctaTitle : "Suivant")
                        .font(.moblyHeading(15.5))
                    Image(systemName: step == totalSteps - 1
                          ? (selectedPlan == .paid ? "lock.fill" : "checkmark")
                          : "arrow.right")
                        .font(.system(size: 13, weight: .bold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 56)
                .background(
                    LinearGradient(
                        colors: [Color.moblyPrimary, Color(hex: 0x5B6BF5)],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .clipShape(Capsule())
                .shadow(color: Color.moblyPrimary.opacity(0.35), radius: 14, y: 8)
            }
            .buttonStyle(.plain)

            if step == totalSteps - 1 {
                Text(selectedPlan.footnote)
                    .font(.moblyBody(11))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                    .multilineTextAlignment(.center)
            }
        }
    }

    /// Gate before activation: run identity verification first when KYC applies,
    /// otherwise complete the upgrade. Used by both the free-trial path and the
    /// pay-now path (after the 5 000 FCFA payment succeeds).
    private func activateOwner() {
        if !isIdentityVerified {
            showVerification = true
        } else {
            finishOwnerUpgrade()
        }
    }

    /// Complete the owner upgrade. For the pay-now plan this also settles the
    /// one-time inscription fee so the account starts already active (no trial).
    private func finishOwnerUpgrade() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        SessionTracker.shared.log("owner.upgrade", ["plan": selectedPlan.analyticsId])
        Session.shared.upgradeToOwner()
        Task {
            await AuthStore.shared.becomeOwnerOnServer()
            if selectedPlan == .paid { await AuthStore.shared.payOwnerInscription() }
        }
        showCelebration = true
    }
}

// MARK: - Step 1: Intro

private struct StepIntro: View {
    @State private var appear = false
    @State private var float = false

    var body: some View {
        VStack(spacing: 30) {
            Spacer(minLength: 20)

            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Color.moblyPrimary.opacity(0.30), Color.moblyPrimary.opacity(0)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 240, height: 240)
                    .blur(radius: 40)

                Image(systemName: "house.fill")
                    .font(.system(size: 96, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(colors: [Color.moblyAccent, Color(hex: 0xE85A1A)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .rotationEffect(.degrees(-6))
                    .offset(y: float ? -8 : 0)
                    .shadow(color: Color.moblyAccent.opacity(0.35), radius: 24, y: 14)

                // Floating sparkle chips
                chip("×3", 24, 0xFFF3EC, 0xC24E10)
                    .offset(x: 100, y: -80)
                    .opacity(appear ? 1 : 0)
                chip("Gratuit", 32, 0xE9F9EF, 0x1F8A5B)
                    .offset(x: -110, y: -30)
                    .opacity(appear ? 1 : 0)
                chip("En 5 min", 32, 0xEEF0FE, 0x3A4FF0)
                    .offset(x: 90, y: 80)
                    .opacity(appear ? 1 : 0)
            }
            .frame(height: 260)

            VStack(spacing: 12) {
                Text("Devenez propriétaire\nsur Mobly")
                    .font(.moblyHeading(28))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Publiez votre espace en quelques minutes\net touchez des locataires vérifiés\npartout au Cameroun.")
                    .font(.moblyBody(14.5))
                    .foregroundStyle(Color(hex: 0x666F80))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 30)
            .opacity(appear ? 1 : 0)
            .offset(y: appear ? 0 : 12)

            Spacer(minLength: 20)
        }
        .onAppear {
            withAnimation(Motion.gentle) { appear = true }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { float = true }
        }
    }

    private func chip(_ text: String, _ size: CGFloat, _ bg: UInt32, _ fg: UInt32) -> some View {
        Text(LT(text))
            .font(.moblyHeading(size == 24 ? 14 : 12.5))
            .foregroundStyle(Color(hex: fg))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Capsule().fill(Color(hex: bg)))
            .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }
}

// MARK: - Step 2: Benefits

private struct StepBenefits: View {
    private let benefits: [(icon: String, tint: UInt32, bg: UInt32, title: String, body: String)] = [
        ("megaphone.fill", 0xFF6B35, 0xFFF3EC,
         "Visible partout au Cameroun",
         "Home, Explore, carte — dès la publication."),
        ("bubble.left.and.bubble.right.fill", 0x3A4FF0, 0xEEF0FE,
         "Chat et visites intégrés",
         "Discutez et planifiez sans partager votre numéro."),
        ("chart.line.uptrend.xyaxis", 0x1F8A5B, 0xE9F9EF,
         "Vos statistiques en temps réel",
         "Vues, contacts, taux — au jour le jour."),
        ("bolt.badge.checkmark.fill", 0xC24E10, 0xFFF3EC,
         "Boostez et vendez plus vite",
         "×3 plus de vues à partir de 500 FCFA."),
    ]

    @State private var appear = false

    var body: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 10)

            VStack(spacing: 8) {
                Text("Tout ce dont vous avez besoin")
                    .font(.moblyHeading(24))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Une seule app pour publier, discuter, mesurer.")
                    .font(.moblyBody(14))
                    .foregroundStyle(Color(hex: 0x666F80))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 30)

            VStack(spacing: 12) {
                ForEach(Array(benefits.enumerated()), id: \.offset) { i, b in
                    HStack(alignment: .top, spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14).fill(Color(hex: b.bg))
                                .frame(width: 48, height: 48)
                            Image(systemName: b.icon)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(Color(hex: b.tint))
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(b.title).font(.moblyHeading(15))
                                .foregroundStyle(Color.moblyTextPrimary)
                            Text(b.body)
                                .font(.moblyBody(12.5))
                                .foregroundStyle(Color(hex: 0x666F80))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 18).fill(.white))
                    .shadow(color: Color(hex: 0x14152A).opacity(0.04), radius: 6, y: 2)
                    .opacity(appear ? 1 : 0)
                    .offset(y: appear ? 0 : 12)
                    .animation(Motion.standard.delay(Double(i) * 0.08), value: appear)
                }
            }
            .padding(.horizontal, 20)

            Spacer(minLength: 10)
        }
        .onAppear { appear = true }
    }
}

// MARK: - Step 3: How it works

private struct StepHowItWorks: View {
    private let steps: [(icon: String, title: String, body: String)] = [
        ("photo.on.rectangle.angled",
         "1. Créez votre annonce",
         "Photos, prix, description — quelques minutes suffisent."),
        ("envelope.badge.fill",
         "2. Recevez des demandes",
         "Chat sécurisé et visites planifiées, numéro masqué."),
        ("checkmark.seal.fill",
         "3. Concluez",
         "Vous choisissez qui rencontrer. Vous décidez."),
    ]

    @State private var appear = false

    var body: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 10)

            VStack(spacing: 8) {
                Text("Simple. Rapide. Efficace.")
                    .font(.moblyHeading(24))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .multilineTextAlignment(.center)
                Text("Trois étapes, et c'est parti.")
                    .font(.moblyBody(14))
                    .foregroundStyle(Color(hex: 0x666F80))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 30)

            VStack(spacing: 16) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                    HStack(alignment: .top, spacing: 16) {
                        ZStack {
                            Circle().fill(
                                LinearGradient(colors: [Color.moblyAccent, Color(hex: 0xE85A1A)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                            .frame(width: 54, height: 54)
                            Image(systemName: s.icon)
                                .font(.system(size: 21, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(s.title).font(.moblyHeading(15.5))
                                .foregroundStyle(Color.moblyTextPrimary)
                            Text(s.body)
                                .font(.moblyBody(13))
                                .foregroundStyle(Color(hex: 0x666F80))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(18)
                    .background(RoundedRectangle(cornerRadius: 20).fill(.white))
                    .shadow(color: Color(hex: 0x14152A).opacity(0.04), radius: 6, y: 2)
                    .opacity(appear ? 1 : 0)
                    .offset(x: appear ? 0 : -20)
                    .animation(Motion.panel.delay(Double(i) * 0.12), value: appear)
                }
            }
            .padding(.horizontal, 20)

            Spacer(minLength: 10)
        }
        .onAppear { appear = true }
    }
}

// MARK: - Step 4: Social proof
//
// Real numbers up top, then a horizontally auto-scrolling belt of owner
// testimonials. The belt duplicates its content so the loop is seamless —
// as one copy scrolls off the leading edge, the second copy is already in
// view. Speed is deliberately calm (~48 pt/s) so users can read as it moves.

private struct Testimonial: Identifiable {
    let id = UUID()
    let initial: String
    let name: String
    let city: String
    let role: String
    let quote: String
    let gradient: [Color]
    let rating: Int  // 1–5, drives the star row
}

private struct StepSocialProof: View {
    let listingsCount: Int
    let citiesCount: Int

    @State private var appear = false

    private static let testimonials: [Testimonial] = [
        .init(initial: "F", name: "Ferdinand F.", city: "Douala", role: "Propriétaire",
              quote: "J'ai loué mon studio en 3 jours. Mobly m'a évité les appels sans fin et les visites bidons.",
              gradient: [Color(hex: 0x3A4FF0), Color(hex: 0x6D2FE0)], rating: 5),
        .init(initial: "A", name: "Aïcha M.", city: "Yaoundé", role: "Propriétaire · 3 annonces",
              quote: "Le chat intégré change tout. Je réponds vite, je filtre facilement, et mon numéro reste privé.",
              gradient: [Color(hex: 0xFF6B35), Color(hex: 0xC24E10)], rating: 5),
        .init(initial: "J", name: "Jean-Paul N.", city: "Bafoussam", role: "Propriétaire",
              quote: "Publier a pris 6 minutes. Premier contact reçu le même soir. Publier ne coûte rien : imbattable.",
              gradient: [Color(hex: 0x1F8A5B), Color(hex: 0x0E6A44)], rating: 5),
        .init(initial: "S", name: "Sandrine E.", city: "Kribi", role: "Propriétaire · Court séjour",
              quote: "J'ai boosté à 500 FCFA sur un week-end de fêtes : trois réservations en 48h.",
              gradient: [Color(hex: 0xC24E10), Color(hex: 0x8B3410)], rating: 5),
        .init(initial: "M", name: "Marc T.", city: "Douala", role: "Agence",
              quote: "Les statistiques me disent exactement quelles annonces travailler. Plus de devinettes.",
              gradient: [Color(hex: 0x2A6FDB), Color(hex: 0x14152A)], rating: 4),
    ]

    var body: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 10)

            VStack(spacing: 8) {
                Text("Vous n'êtes pas seul.")
                    .font(.moblyHeading(24))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .multilineTextAlignment(.center)
                Text("Des centaines de propriétaires font déjà confiance à Mobly.")
                    .font(.moblyBody(14))
                    .foregroundStyle(Color(hex: 0x666F80))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }

            HStack(spacing: 12) {
                statCard(number: "\(listingsCount)", label: "espaces publiés")
                statCard(number: "\(citiesCount)", label: "villes couvertes")
                statCard(number: "24/7", label: "chat sécurisé")
            }
            .padding(.horizontal, 20)
            .opacity(appear ? 1 : 0)
            .offset(y: appear ? 0 : 12)
            .animation(Motion.gentle.delay(0.2), value: appear)

            AutoSwipeTestimonials(testimonials: Self.testimonials)
                .opacity(appear ? 1 : 0)
                .offset(y: appear ? 0 : 20)
                .animation(Motion.gentle.delay(0.35), value: appear)

            Spacer(minLength: 10)
        }
        .onAppear { appear = true }
    }

    private func statCard(number: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(number).font(.moblyHeading(22)).foregroundStyle(Color.moblyPrimary)
            Text(LT(label))
                .font(.moblyBody(11))
                .foregroundStyle(Color(hex: 0x9A9DAC))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 16).fill(.white))
        .shadow(color: Color(hex: 0x14152A).opacity(0.04), radius: 6, y: 2)
    }
}

// MARK: - Auto-swipe carousel
//
// Paged carousel that swipes to the next testimonial every ~4s. Cards hug
// their content vertically — a longer quote makes its card taller, a shorter
// one keeps it compact. The container reads the visible card's height each
// transition so the belt animates its own height too, which stops the layout
// from jumping around the surrounding text. Users can still swipe manually;
// the auto-advance timer resets on user interaction to avoid fighting them.
private struct AutoSwipeTestimonials: View {
    let testimonials: [Testimonial]

    @State private var index = 0
    @State private var cardHeights: [Int: CGFloat] = [:]
    @State private var timerTick = 0
    @State private var isUserSwiping = false

    /// Seconds between auto-swipes. Reset when the user manually swipes.
    private let interval: TimeInterval = 4
    private let advanceTimer = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    private var currentHeight: CGFloat {
        cardHeights[index] ?? 200
    }

    var body: some View {
        VStack(spacing: 14) {
            TabView(selection: $index) {
                ForEach(Array(testimonials.enumerated()), id: \.element.id) { i, t in
                    TestimonialCard(testimonial: t)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 4) // room for the card's shadow
                        .background(
                            GeometryReader { proxy in
                                Color.clear
                                    .onAppear { cardHeights[i] = proxy.size.height }
                                    .onChange(of: proxy.size.height) { _, h in
                                        cardHeights[i] = h
                                    }
                            }
                        )
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: currentHeight)
            .animation(Motion.standard, value: currentHeight)
            // Detect manual swipe — pause auto-advance briefly so we don't
            // trip over the user in the middle of their drag.
            .simultaneousGesture(
                DragGesture()
                    .onChanged { _ in
                        isUserSwiping = true
                        timerTick = 0
                    }
                    .onEnded { _ in isUserSwiping = false }
            )

            // Page dots (tap to jump)
            HStack(spacing: 6) {
                ForEach(0..<testimonials.count, id: \.self) { i in
                    Capsule()
                        .fill(i == index ? Color.moblyAccent : Color(hex: 0xE2E4EC))
                        .frame(width: i == index ? 18 : 6, height: 6)
                        .onTapGesture {
                            timerTick = 0
                            withAnimation(Motion.standard) { index = i }
                        }
                }
            }
            .animation(Motion.quick, value: index)
        }
        .onReceive(advanceTimer) { _ in
            guard !isUserSwiping else { return }
            withAnimation(Motion.standard) {
                index = (index + 1) % testimonials.count
            }
        }
    }
}

private struct TestimonialCard: View {
    let testimonial: Testimonial

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                ForEach(0..<5, id: \.self) { i in
                    Image(systemName: i < testimonial.rating ? "star.fill" : "star")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.moblyAccent)
                }
            }

            // No lineLimit — the card grows to fit the full quote and the
            // outer TabView animates its own height to match.
            Text(testimonial.quote)
                .font(.moblyBody(14.5))
                .foregroundStyle(Color.moblyTextPrimary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(LinearGradient(colors: testimonial.gradient,
                                                 startPoint: .top, endPoint: .bottom))
                    Text(testimonial.initial).font(.moblyHeading(13)).foregroundStyle(.white)
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(testimonial.name).font(.moblyHeading(13))
                            .foregroundStyle(Color.moblyTextPrimary)
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 10)).foregroundStyle(Color.moblyPrimary)
                    }
                    Text("\(testimonial.role) · \(testimonial.city)")
                        .font(.moblyBody(11))
                        .foregroundStyle(Color(hex: 0x9A9DAC))
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 22).fill(.white))
        .shadow(color: Color(hex: 0x14152A).opacity(0.06), radius: 10, y: 4)
    }
}

// MARK: - Step 5: Confirm

private struct StepConfirm: View {
    @ObservedObject private var auth = AuthStore.shared
    @State private var appear = false

    /// Whether the KYC step applies at all. Driven by the same
    /// `owners.identityRequired` switch the server enforces, so relaxing the
    /// rule from the dashboard also removes the step here — rather than the
    /// app demanding a check the backend no longer asks for.
    private var kycRequired: Bool {
        RemoteConfigStore.shared.isEnabled("owners.identityRequired")
    }

    private var isIdentityVerified: Bool {
        !kycRequired || auth.user?.identityVerified == true
    }

    private let promises: [(icon: String, text: String)] = [
        ("checkmark.circle.fill", "Publication 100 % gratuite"),
        ("checkmark.circle.fill", "Aucune commission sur vos revenus"),
        ("checkmark.circle.fill", "Votre numéro reste privé"),
        ("checkmark.circle.fill", "Votre compte peut être annulé à tout moment"),
    ]

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 20)

            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Color.moblyAccent.opacity(0.30), Color.moblyAccent.opacity(0)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 220, height: 220)
                    .blur(radius: 40)
                Circle()
                    .fill(.white)
                    .frame(width: 110, height: 110)
                    .shadow(color: Color.moblyAccent.opacity(0.3), radius: 20, y: 10)
                Image(systemName: isIdentityVerified ? "sparkles" : "checkmark.shield.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(
                        isIdentityVerified
                            ? LinearGradient(colors: [Color.moblyAccent, Color(hex: 0xE85A1A)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)
                            : LinearGradient(colors: [Color(hex: 0xE5950C), Color(hex: 0xC27A00)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
            }

            VStack(spacing: 10) {
                Text(isIdentityVerified ? "Vous êtes prêt." : "Vérification requise")
                    .font(.moblyHeading(28))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .multilineTextAlignment(.center)
                Text(isIdentityVerified
                     ? "Voici ce que vous obtenez en activant\nvotre espace propriétaire."
                     : "Pour la sécurité de tous, vérifiez\nvotre identité avant de publier.")
                    .font(.moblyBody(14))
                    .foregroundStyle(Color(hex: 0x666F80))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
            .padding(.horizontal, 30)

            VStack(spacing: 10) {
                ForEach(Array(promises.enumerated()), id: \.offset) { i, p in
                    HStack(spacing: 12) {
                        Image(systemName: p.icon)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color(hex: 0x1F8A5B))
                        Text(p.text)
                            .font(.moblyBody(14, weight: .medium))
                            .foregroundStyle(Color.moblyTextPrimary)
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 14).fill(.white))
                    .shadow(color: Color(hex: 0x14152A).opacity(0.03), radius: 5, y: 2)
                    .opacity(appear ? 1 : 0)
                    .offset(y: appear ? 0 : 8)
                    .animation(Motion.standard.delay(Double(i) * 0.06), value: appear)
                }
            }
            .padding(.horizontal, 20)

            Spacer(minLength: 10)
        }
        .onAppear { appear = true }
    }
}

// MARK: - Owner plan

/// The two ways to activate an owner account. Both unlock the same features;
/// the trial simply defers the first `OwnerPlan.monthlyPrice` charge by 7 days.
enum OwnerPlan {
    case trial
    case paid

    /// Monthly subscription price once billing starts, in FCFA.
    static let monthlyPrice = 5000

    var analyticsId: String { self == .trial ? "trial_7d" : "paid_monthly" }

    var ctaTitle: String {
        self == .trial ? "Commencer l'essai gratuit" : "Payer 5 000 FCFA"
    }

    var footnote: String {
        self == .trial
            ? "Essai gratuit 7 jours · Aucun paiement requis maintenant"
            : "Paiement unique de 5 000 FCFA · Compte actif immédiatement"
    }
}

// MARK: - Step 6: Pricing
//
// The offer screen: become an owner from 5 000 FCFA / month, or start with a
// free 7-day trial. Two tappable cards drive `selectedPlan`, which the footer
// and the payment page both read.
private struct StepPricing: View {
    @Binding var selectedPlan: OwnerPlan
    @State private var appear = false

    private let perks: [String] = [
        "Annonces illimitées",
        "Badge propriétaire vérifié",
        "Demandes de visite & messagerie",
        "Statistiques de vos annonces",
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    Text("Devenez propriétaire")
                        .font(.moblyHeading(27))
                        .foregroundStyle(Color.moblyTextPrimary)
                        .multilineTextAlignment(.center)
                    Text("Essayez 7 jours gratuitement,\nou payez une fois pour tout activer.")
                        .font(.moblyBody(14))
                        .foregroundStyle(Color(hex: 0x666F80))
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }
                .padding(.top, 16)
                .padding(.horizontal, 30)

                VStack(spacing: 14) {
                    planCard(
                        plan: .trial,
                        badge: "GRATUIT",
                        title: "Essai gratuit 7 jours",
                        price: "0 FCFA",
                        priceCaption: "aujourd'hui",
                        subtitle: "Activez gratuitement. Après 7 jours, payez 5 000 FCFA pour rester actif."
                    )
                    planCard(
                        plan: .paid,
                        badge: nil,
                        title: "Payer maintenant",
                        price: "5 000 FCFA",
                        priceCaption: "une seule fois",
                        subtitle: "Compte actif immédiatement. Paiement unique, sans abonnement."
                    )
                }
                .padding(.horizontal, 20)

                VStack(spacing: 10) {
                    ForEach(Array(perks.enumerated()), id: \.offset) { _, p in
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color(hex: 0x1F8A5B))
                            Text(p)
                                .font(.moblyBody(13.5, weight: .medium))
                                .foregroundStyle(Color.moblyTextPrimary)
                            Spacer()
                        }
                    }
                }
                .padding(.horizontal, 34)

                Spacer(minLength: 10)
            }
            .opacity(appear ? 1 : 0)
            .offset(y: appear ? 0 : 10)
            .animation(Motion.standard, value: appear)
        }
        .onAppear { appear = true }
    }

    private func planCard(plan: OwnerPlan, badge: String?, title: String,
                          price: String, priceCaption: String, subtitle: String) -> some View {
        let selected = selectedPlan == plan
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(Motion.quick) { selectedPlan = plan }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.moblyHeading(16))
                        .foregroundStyle(Color.moblyTextPrimary)
                    if let badge {
                        Text(badge)
                            .font(.moblyBody(9.5, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.moblyAccent))
                    }
                    Spacer()
                    ZStack {
                        Circle()
                            .strokeBorder(selected ? Color.moblyPrimary : Color(hex: 0xCED2DE),
                                          lineWidth: selected ? 7 : 2)
                            .frame(width: 22, height: 22)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(price)
                        .font(.moblyHeading(22))
                        .foregroundStyle(Color.moblyPrimary)
                    Text(priceCaption)
                        .font(.moblyBody(12.5))
                        .foregroundStyle(Color(hex: 0x9A9DAC))
                }
                Text(subtitle)
                    .font(.moblyBody(12.5))
                    .foregroundStyle(Color(hex: 0x666F80))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18).fill(.white))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(selected ? Color.moblyPrimary : Color(hex: 0xE7E9F0),
                            lineWidth: selected ? 2 : 1)
            )
            .shadow(color: selected ? Color.moblyPrimary.opacity(0.18) : Color(hex: 0x14152A).opacity(0.04),
                    radius: selected ? 12 : 5, y: selected ? 6 : 2)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Owner payment page
//
// A lightweight mobile-money checkout shown before identity verification.
// Front-end only — it collects the method and the phone number and simulates
// the charge; wiring it to a real PSP (MTN MoMo / Orange Money) is a backend
// task. For the trial the "charge" is 0 today, so the button reads differently
// but the flow is identical.
struct OwnerPaymentView: View {
    let plan: OwnerPlan
    /// One-time inscription fee (used by the post-trial reactivation paywall)
    /// instead of the subscription/trial framing.
    var oneTime: Bool = false
    var onCancel: () -> Void = {}
    var onPaid: () -> Void = {}

    @ObservedObject private var auth = AuthStore.shared

    enum Method: String, CaseIterable {
        case mtn = "MTN Mobile Money"
        case orange = "Orange Money"

        var tint: Color { self == .mtn ? Color(hex: 0xFFCC00) : Color(hex: 0xFF6600) }
        var glyph: String { self == .mtn ? "M" : "O" }
    }

    @State private var method: Method = .mtn
    @State private var phone = ""
    @State private var processing = false
    @State private var done = false

    private var amountToday: Int { oneTime ? OwnerPlan.monthlyPrice : (plan == .trial ? 0 : OwnerPlan.monthlyPrice) }

    private var phoneValid: Bool {
        phone.filter(\.isNumber).count >= 9
    }

    var body: some View {
        ZStack {
            Color(hex: 0xF7F8FA).ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        summaryCard
                        methodPicker
                        phoneField
                        secureNote
                        Spacer(minLength: 20)
                    }
                    .padding(20)
                }

                payButton
                    .padding(.horizontal, 20)
                    .padding(.bottom, 30)
            }

            if done { successOverlay }
        }
    }

    private var header: some View {
        HStack {
            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(.white))
                    .shadow(color: Color(hex: 0x14152A).opacity(0.06), radius: 6, y: 2)
            }
            Spacer()
            Text("Paiement")
                .font(.moblyHeading(16))
                .foregroundStyle(Color.moblyTextPrimary)
            Spacer()
            Color.clear.frame(width: 40, height: 40)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private var summaryCard: some View {
        VStack(spacing: 12) {
            HStack {
                Text(oneTime ? "Frais d'inscription propriétaire"
                             : (plan == .trial ? "Essai gratuit 7 jours" : "Abonnement propriétaire"))
                    .font(.moblyBody(14, weight: .semibold))
                    .foregroundStyle(Color.moblyTextPrimary)
                Spacer()
                Text(oneTime ? "5 000 FCFA" : (plan == .trial ? "0 FCFA" : "5 000 FCFA"))
                    .font(.moblyHeading(16))
                    .foregroundStyle(Color.moblyPrimary)
            }
            Rectangle().fill(Color(hex: 0xF1F2F6)).frame(height: 1)
            HStack {
                Text("À payer aujourd'hui")
                    .font(.moblyBody(13))
                    .foregroundStyle(Color(hex: 0x666F80))
                Spacer()
                Text("\(amountToday.formattedFcfa) FCFA")
                    .font(.moblyHeading(18))
                    .foregroundStyle(Color.moblyTextPrimary)
            }
            if oneTime {
                Text("Paiement unique. Aucun abonnement ni frais mensuel par la suite.")
                    .font(.moblyBody(11.5))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if plan == .trial {
                Text("Vous ne serez pas débité aujourd'hui. Le premier paiement de 5 000 FCFA aura lieu dans 7 jours, sauf annulation.")
                    .font(.moblyBody(11.5))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18).fill(.white))
        .shadow(color: Color(hex: 0x14152A).opacity(0.04), radius: 6, y: 2)
    }

    private var methodPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Moyen de paiement")
                .font(.moblyBody(12.5, weight: .semibold))
                .foregroundStyle(Color(hex: 0x9A9DAC))
            ForEach(Method.allCases, id: \.self) { m in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(Motion.quick) { method = m }
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 9).fill(m.tint)
                            Text(m.glyph)
                                .font(.moblyHeading(17))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 38, height: 38)
                        Text(m.rawValue)
                            .font(.moblyBody(14, weight: .medium))
                            .foregroundStyle(Color.moblyTextPrimary)
                        Spacer()
                        Circle()
                            .strokeBorder(method == m ? Color.moblyPrimary : Color(hex: 0xCED2DE),
                                          lineWidth: method == m ? 7 : 2)
                            .frame(width: 20, height: 20)
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(.white))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(method == m ? Color.moblyPrimary : Color(hex: 0xE7E9F0),
                                    lineWidth: method == m ? 2 : 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var phoneField: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Numéro \(method.rawValue)")
                .font(.moblyBody(12.5, weight: .semibold))
                .foregroundStyle(Color(hex: 0x9A9DAC))
            HStack(spacing: 8) {
                Text("+237")
                    .font(.moblyBody(14, weight: .semibold))
                    .foregroundStyle(Color.moblyTextPrimary)
                TextField("6 XX XX XX XX", text: $phone)
                    .font(.moblyBody(14))
                    .keyboardType(.numberPad)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(hex: 0xE7E9F0), lineWidth: 1))
        }
    }

    private var secureNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color(hex: 0x1F8A5B))
            Text("Paiement sécurisé. Vous confirmerez sur votre téléphone.")
                .font(.moblyBody(11.5))
                .foregroundStyle(Color(hex: 0x9A9DAC))
            Spacer()
        }
    }

    private var payButton: some View {
        Button {
            guard phoneValid, !processing else { return }
            startPayment()
        } label: {
            HStack(spacing: 8) {
                if processing {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "lock.fill").font(.system(size: 13, weight: .bold))
                }
                Text(processing
                     ? "Traitement…"
                     : (oneTime ? "Payer 5 000 FCFA"
                                : (plan == .trial ? "Démarrer l'essai gratuit" : "Payer 5 000 FCFA")))
                    .font(.moblyHeading(15.5))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity).frame(height: 56)
            .background(
                LinearGradient(colors: [Color.moblyPrimary, Color(hex: 0x5B6BF5)],
                               startPoint: .leading, endPoint: .trailing)
            )
            .clipShape(Capsule())
            .opacity(phoneValid ? 1 : 0.5)
            .shadow(color: Color.moblyPrimary.opacity(0.35), radius: 14, y: 8)
        }
        .buttonStyle(.plain)
        .disabled(!phoneValid || processing)
    }

    private var successOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                ZStack {
                    Circle().fill(Color(hex: 0x1F8A5B)).frame(width: 72, height: 72)
                    Image(systemName: "checkmark")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(.white)
                }
                Text(oneTime ? "Compte réactivé" : (plan == .trial ? "Essai activé" : "Paiement confirmé"))
                    .font(.moblyHeading(19))
                    .foregroundStyle(Color.moblyTextPrimary)
                Text(oneTime ? "Réactivation…" : "Vérification d'identité…")
                    .font(.moblyBody(13))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
            }
            .padding(28)
            .background(RoundedRectangle(cornerRadius: 22).fill(.white))
            .padding(40)
        }
        .transition(.opacity)
    }

    private func startPayment() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        processing = true
        SessionTracker.shared.log("owner.payment_started", [
            "plan": plan.analyticsId,
            "method": method.rawValue,
            "amount": String(amountToday),
        ])
        // Simulate the mobile-money round trip (USSD push + confirmation).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            processing = false
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            SessionTracker.shared.log("owner.payment_succeeded", ["plan": plan.analyticsId])
            withAnimation(Motion.standard) { done = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { onPaid() }
        }
    }
}

private extension Int {
    /// "5000" → "5 000" (thin-space grouping used across the app's prices).
    var formattedFcfa: String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = " "
        return f.string(from: NSNumber(value: self)) ?? String(self)
    }
}

// MARK: - Celebration
//
// A brief moment of theatre after the tap: confetti-adjacent (no third-party
// libs), a green seal, and a copy-heavy welcome. Then hands off to the owner
// dashboard. Keeps the conversion feeling like a milestone, not a form-submit.
private struct CelebrationView: View {
    var onDone: () -> Void

    @State private var appear = false
    @State private var pulse = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.moblyPrimary, Color(hex: 0x6D2FE0)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            // Floating sparkles
            ForEach(0..<14, id: \.self) { i in
                Image(systemName: i.isMultiple(of: 2) ? "sparkle" : "star.fill")
                    .font(.system(size: [10, 14, 18, 22, 26].randomElement() ?? 14))
                    .foregroundStyle(.white.opacity(Double.random(in: 0.15...0.6)))
                    .position(
                        x: CGFloat.random(in: 20...UIScreen.main.bounds.width - 20),
                        y: CGFloat.random(in: 80...UIScreen.main.bounds.height - 200)
                    )
                    .opacity(appear ? 1 : 0)
                    .animation(Motion.gentle.delay(Double(i) * 0.05), value: appear)
            }

            VStack(spacing: 24) {
                Spacer()
                ZStack {
                    Circle().fill(.white.opacity(0.15))
                        .frame(width: 160, height: 160)
                        .scaleEffect(pulse ? 1.1 : 1)
                    Circle().fill(.white)
                        .frame(width: 108, height: 108)
                    Image(systemName: "checkmark")
                        .font(.system(size: 46, weight: .bold))
                        .foregroundStyle(Color.moblyPrimary)
                }
                .scaleEffect(appear ? 1 : 0.4)

                VStack(spacing: 10) {
                    Text("Bienvenue,\npropriétaire !")
                        .font(.moblyHeading(28))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Votre espace propriétaire est prêt.\nVos locataires vous attendent.")
                        .font(.moblyBody(14))
                        .foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }
                .opacity(appear ? 1 : 0)
                .offset(y: appear ? 0 : 20)

                Spacer()

                Button {
                    onDone()
                } label: {
                    HStack(spacing: 8) {
                        Text("Publier ma première annonce")
                            .font(.moblyHeading(15.5))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .foregroundStyle(Color.moblyPrimary)
                    .frame(maxWidth: .infinity).frame(height: 56)
                    .background(Capsule().fill(.white))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
                .opacity(appear ? 1 : 0)
            }
        }
        .onAppear {
            withAnimation(Motion.gentle) { appear = true }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}
