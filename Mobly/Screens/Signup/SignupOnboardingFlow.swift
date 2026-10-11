import SwiftUI

/// What a new user told us right after signup.
struct OnboardingAnswers: Codable, Equatable {
    enum Intent: String, Codable { case seeking, offering }
    var intent: Intent?
    /// Listing categories as the feed names them ("Studios", "Chambres"…).
    var spaceTypes: [String] = []
    /// One of Cameroon's 10 régions ("Littoral", "Centre"…).
    var region: String?
    /// "long" (priced per month) or "court" (per day). Nil when skipped.
    var stay: String?
    /// Shortest stay planned: months for "long", days for "court".
    var minDuration: Int?
    var budget: Budget?

    struct Budget: Codable, Equatable, Hashable {
        let label: String
        let min: Int?
        let max: Int?
    }

    static let storageKey = "signup.onboardingAnswers"
    /// Answers not yet stored on the account (offline, or server error).
    static let pendingSyncKey = "signup.onboardingAnswers.pendingSync"
    /// Set when onboarding ends; Home shows its "for you" picks once, then clears it.
    static let suggestionsPendingKey = "signup.onboardingSuggestionsPending"
    /// Set when the user answered "Je propose un espace": Home opens
    /// "Devenez propriétaire" once, then clears it.
    static let becomeOwnerPendingKey = "signup.becomeOwnerPending"

    static func load() -> OnboardingAnswers? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(OnboardingAnswers.self, from: data)
    }

    var hasSearchCriteria: Bool { !spaceTypes.isEmpty || region != nil || budget != nil || stay != nil }

    /// "dans le Littoral", "dans l'Ouest" — the article French puts before
    /// a région's name.
    static func inRegion(_ region: String) -> String {
        let vowels: Set<Character> = ["A", "E", "É", "È", "I", "O", "U"]
        guard let first = region.first else { return region }
        return vowels.contains(first) ? L("dans l'") + region : L("dans le") + " " + region
    }

    /// "bonnes" for the feminine categories, so the sentence agrees with
    /// what was picked ("les bonnes chambres", "les bons studios").
    var goodAdjective: String {
        let feminine: Set<String> = ["Chambres", "Villas", "Boutiques"]
        return spaceTypes.count == 1 && feminine.contains(spaceTypes[0]) ? L("bonnes") : L("bons")
    }

    /// "studios dans le Littoral", "espaces dans l'Ouest", "chambres" —
    /// nil when nothing was chosen. Used to say back what the user asked for.
    var summary: String? {
        let type = spaceTypes.count == 1 ? spaceTypes[0].lowercased() : nil
        switch (type, region) {
        case let (t?, r?): return "\(t) \(Self.inRegion(r))"
        case let (t?, nil): return t
        case let (nil, r?): return L("espaces") + " \(Self.inRegion(r))"
        default: return nil
        }
    }

    /// Stores the answers on the account. Kept locally as pending until the
    /// server confirms, so a dropped connection right after signup doesn't
    /// lose them — `syncPending()` retries on the next launch.
    func saveToAccount() async {
        UserDefaults.standard.set(true, forKey: Self.pendingSyncKey)
        let body = MoblyAPI.SearchPreferencesBody(
            intent: intent.map { $0 == .seeking ? "SEEKING" : "OFFERING" },
            spaceTypes: spaceTypes,
            region: region,
            stay: stay,
            minDuration: minDuration,
            budgetMin: budget?.min,
            budgetMax: budget?.max
        )
        do {
            try await MoblyAPI.shared.saveSearchPreferences(body)
            UserDefaults.standard.removeObject(forKey: Self.pendingSyncKey)
        } catch {
            // Left pending; retried at next launch.
        }
    }

    static func syncPending() async {
        guard UserDefaults.standard.bool(forKey: pendingSyncKey),
              MoblyAPI.shared.isAuthenticated,
              let answers = load() else { return }
        await answers.saveToAccount()
    }
}

/// The end of signup, after the phone and e-mail are verified: a few
/// questions about what the user wants, then the permission screens, each
/// worded around those answers.
///
/// One screen with fixed chrome — progress at the top, buttons at the
/// bottom — where only the middle changes, cross-fading between steps. The
/// earlier version slid whole screens sideways, buttons included.
struct SignupOnboardingFlow: View {
    var firstName: String
    var onFinish: (OnboardingAnswers) -> Void

    private enum Step: Hashable { case intent, spaceType, stay, minDuration, region, budget, notifications, location }

    @ObservedObject private var location = LocationService.shared
    @ObservedObject private var config = RemoteConfigStore.shared
    @State private var answers = OnboardingAnswers()
    @State private var index = 0
    @State private var busy = false
    /// Permission screens, decided once on arrival: only what iOS can still
    /// ask for, so a granted or refused permission is never a dead end.
    @State private var permissionSteps: [Step]

    init(firstName: String, onFinish: @escaping (OnboardingAnswers) -> Void) {
        self.firstName = firstName
        self.onFinish = onFinish
        var perms: [Step] = []
        let config = RemoteConfigStore.shared
        if config.isEnabled("signup.permissionPrimers") {
            let push = PushService.shared.status
            if config.isEnabled("notifications.push"), push == .notDetermined || push == .unknown {
                perms.append(.notifications)
            }
            if LocationService.shared.canAskPermission { perms.append(.location) }
        }
        _permissionSteps = State(initialValue: perms)
    }

    /// Owners have no budget to give; the questions can be switched off
    /// remotely with `signup.onboardingQuestions`.
    private var steps: [Step] {
        var s: [Step] = []
        if config.isEnabled("signup.onboardingQuestions") {
            if answers.intent == .offering {
                s = [.intent, .spaceType, .region]
            } else {
                // Duration and budget are worded per month or per day, so
                // they follow the stay answer.
                s = [.intent, .spaceType, .stay]
                if answers.stay != nil { s.append(.minDuration) }
                s += [.region, .budget]
            }
        }
        return s + permissionSteps
    }

    private var step: Step? { index < steps.count ? steps[index] : nil }
    private var isOwner: Bool { answers.intent == .offering }

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 22)
                .padding(.top, 8)

            ZStack {
                if let step {
                    content(for: step)
                        .id(step)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            bottomButtons
                .padding(.horizontal, 30)
                .padding(.bottom, 16)
        }
        .background(Color.white.ignoresSafeArea())
        .stepSwipeBack(enabled: canGoBack) { goBack() }
        .onAppear {
            if steps.isEmpty { onFinish(answers) }
            if let step { log("signup.onboarding.shown", step) }
        }
        .onChange(of: location.authorization) { _, status in
            guard step == .location, status != .notDetermined else { return }
            SessionTracker.shared.log("signup.primer.answered",
                                      ["kind": "location", "granted": location.isAuthorized])
            advance()
        }
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack(spacing: 14) {
            Button(action: goBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 13).fill(Color(hex: 0xF4F5F8)))
            }
            .opacity(canGoBack ? 1 : 0)
            .disabled(!canGoBack)

            HStack(spacing: 5) {
                ForEach(steps.indices, id: \.self) { i in
                    Capsule()
                        .fill(i <= index ? Color.moblyPrimary : Color(hex: 0xE6E8F0))
                        .frame(height: 5)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: index)

            // Balances the back button so the bar stays centred.
            Color.clear.frame(width: 40, height: 40)
        }
    }

    /// Back only between questions — a permission already answered in the
    /// system dialog can't be taken back here.
    private var canGoBack: Bool {
        guard index > 0, let step else { return false }
        return step != .notifications && step != .location && !busy
    }

    private var bottomButtons: some View {
        VStack(spacing: 6) {
            PillButton(title: primaryTitle, style: .primaryBlue, trailingIcon: nil, action: primary)
                .opacity(canContinue && !busy ? 1 : 0.5)
                .disabled(!canContinue || busy)
            Button(action: skip) {
                Text(secondaryTitle)
                    .font(.moblyHeading(16))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
            }
            .buttonStyle(.plain)
            .disabled(busy)
        }
    }

    private var primaryTitle: String {
        switch step {
        case .notifications: return L("Activer les notifications")
        case .location:      return L("Autoriser la localisation")
        default:             return L("Continuer")
        }
    }

    private var secondaryTitle: LocalizedStringKey {
        step == .notifications || step == .location ? "Plus tard" : "Passer"
    }

    private var canContinue: Bool {
        switch step {
        case .intent:    return answers.intent != nil
        case .spaceType: return !answers.spaceTypes.isEmpty
        case .stay:        return answers.stay != nil
        case .minDuration: return answers.minDuration != nil
        case .region:    return answers.region != nil
        case .budget:    return answers.budget != nil
        default:         return true
        }
    }

    // MARK: Steps

    @ViewBuilder private func content(for step: Step) -> some View {
        switch step {
        case .intent:
            QuestionPage(eyebrow: firstName.isEmpty ? nil : "Bienvenue, \(firstName)",
                         title: "Qu'est-ce qui vous amène sur Mobly ?",
                         message: "On adapte l'application à ce que vous voulez faire.") {
                VStack(spacing: 12) {
                    IntentCard(icon: "magnifyingglass", title: "Je cherche un espace",
                               subtitle: "Louer une chambre, un studio, un bureau…",
                               selected: answers.intent == .seeking) { pickIntent(.seeking) }
                    IntentCard(icon: "key.fill", title: "Je propose un espace",
                               subtitle: "Publier une annonce et recevoir des demandes",
                               selected: answers.intent == .offering) { pickIntent(.offering) }
                }
            }
        case .spaceType:
            QuestionPage(title: isOwner ? "Quel espace proposez-vous ?" : "Quel espace recherchez-vous ?",
                         message: "Choisissez-en autant que vous voulez.") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                          spacing: 10) {
                    ForEach(Self.spaceTypes, id: \.label) { item in
                        ChoiceTile(icon: item.icon, label: LocalizedStringKey(item.label),
                                   selected: answers.spaceTypes.contains(item.label)) {
                            toggleType(item.label)
                        }
                    }
                }
            }
        case .stay:
            QuestionPage(title: "Long séjour ou court séjour ?",
                         message: "Pour vous montrer les bons prix, au mois ou à la journée.") {
                VStack(spacing: 12) {
                    IntentCard(icon: "house.fill", title: "Long séjour",
                               subtitle: "Location au mois, pour s'installer",
                               selected: answers.stay == "long") { pickStay("long") }
                    IntentCard(icon: "calendar", title: "Court séjour",
                               subtitle: "Location à la journée, pour quelques jours",
                               selected: answers.stay == "court") { pickStay("court") }
                }
            }
        case .minDuration:
            QuestionPage(title: "Durée minimale",
                         message: isShortStay ? "Combien de jours comptez-vous rester au moins ?"
                                              : "Combien de mois comptez-vous rester au moins ?") {
                VStack(spacing: 10) {
                    ForEach(isShortStay ? Self.dayDurations : Self.monthDurations, id: \.self) { n in
                        BudgetRow(label: LocalizedStringKey(Self.durationLabel(n, days: isShortStay)),
                                  selected: answers.minDuration == n) {
                            select { answers.minDuration = n }
                        }
                    }
                }
            }
        case .region:
            QuestionPage(title: isOwner ? "Dans quelle région se trouve votre espace ?" : "Dans quelle région ?",
                         message: isOwner ? "Les locataires de cette région verront votre annonce en premier."
                                          : "Là où vous voulez vous installer.") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                          spacing: 10) {
                    ForEach(CameroonGeo.regions) { region in
                        RegionTile(name: region.name,
                                   capital: region.cities.first ?? "",
                                   imageName: Self.regionImages[region.name],
                                   selected: answers.region == region.name) {
                            select { answers.region = region.name }
                        }
                    }
                }
            }
        case .budget:
            QuestionPage(title: isShortStay ? "Quel est votre budget par jour ?" : "Quel est votre budget par mois ?",
                         message: "Pour ne vous montrer que ce qui vous convient. Vous pourrez le changer à tout moment.") {
                VStack(spacing: 10) {
                    ForEach(isShortStay ? Self.dailyBudgets : Self.budgets, id: \.label) { b in
                        BudgetRow(label: LocalizedStringKey(b.label), selected: answers.budget == b) {
                            select { answers.budget = b }
                        }
                    }
                }
            }
        case .notifications:
            PrimerContent(art: isOwner ? .ownerNotifications : .notifications,
                          eyebrow: firstName.isEmpty ? nil : "\(firstName), une dernière chose",
                          title: isOwner ? "Ne ratez aucune demande" : "Ne ratez aucune réponse",
                          message: notificationsMessage)
        case .location:
            PrimerContent(art: .location,
                          eyebrow: firstName.isEmpty ? nil : "Presque fini, \(firstName)",
                          title: "Voyez d'abord ce qui est près de vous",
                          message: "Mobly classe les annonces selon la distance. Votre position exacte n'est jamais partagée avec les propriétaires.")
        }
    }

    /// Says back what they asked for, so the ask reads as being about them.
    private var notificationsMessage: LocalizedStringKey {
        if isOwner {
            return "On vous prévient dès qu'un utilisateur vous écrit ou demande une visite."
        }
        if let summary = answers.summary {
            return "Les \(answers.goodAdjective) \(summary) partent vite. On vous prévient dès qu'un propriétaire vous répond ou confirme votre visite, rien d'autre."
        }
        return "Les bons espaces partent vite. On vous prévient dès qu'un propriétaire vous répond ou confirme votre visite, rien d'autre."
    }

    // MARK: Actions

    private func select(_ change: () -> Void) {
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(.easeOut(duration: 0.15)) { change() }
    }

    private func pickIntent(_ intent: OnboardingAnswers.Intent) {
        select {
            answers.intent = intent
            // Owners skip the budget question, so a budget picked as a
            // tenant must not survive the switch.
            if intent == .offering {
                answers.budget = nil; answers.stay = nil; answers.minDuration = nil
            }
        }
    }

    private var isShortStay: Bool { answers.stay == "court" }

    private func pickStay(_ stay: String) {
        select {
            // Durations and budgets are in months or days: a switch clears them.
            if answers.stay != stay { answers.minDuration = nil; answers.budget = nil }
            answers.stay = stay
        }
    }

    private func toggleType(_ label: String) {
        select {
            if let i = answers.spaceTypes.firstIndex(of: label) { answers.spaceTypes.remove(at: i) }
            else { answers.spaceTypes.append(label) }
        }
    }

    private func primary() {
        switch step {
        case .notifications:
            busy = true
            Task {
                let granted = await PushService.shared.requestFromPrimer()
                SessionTracker.shared.log("signup.primer.answered", ["kind": "notifications", "granted": granted])
                busy = false
                advance()
            }
        case .location:
            // Already answered (e.g. in Réglages meanwhile): no prompt will come.
            guard location.canAskPermission else { advance(); return }
            busy = true
            location.askForPermission()   // `.onChange` above moves on
        default:
            advance()
        }
    }

    private func skip() {
        if let step { log("signup.onboarding.skipped", step) }
        // Skipping a question clears it, so "Passer" never keeps a half answer.
        switch step {
        case .intent:    answers.intent = nil
        case .spaceType: answers.spaceTypes = []
        case .stay:      answers.stay = nil; answers.minDuration = nil; answers.budget = nil
        case .minDuration: answers.minDuration = nil
        case .region:    answers.region = nil
        case .budget:    answers.budget = nil
        default: break
        }
        advance()
    }

    private func advance() {
        busy = false
        guard index + 1 < steps.count else { finish(); return }
        withAnimation(.easeInOut(duration: 0.25)) { index += 1 }
        if let step { log("signup.onboarding.shown", step) }
    }

    private func goBack() {
        guard canGoBack else { return }
        withAnimation(.easeInOut(duration: 0.25)) { index -= 1 }
    }

    private func finish() {
        if let data = try? JSONEncoder().encode(answers) {
            UserDefaults.standard.set(data, forKey: OnboardingAnswers.storageKey)
        }
        // A tenant's answers become a saved search they can rerun from
        // Recherche — the first thing on Mobly that is already theirs.
        if answers.intent != .offering,
           answers.hasSearchCriteria {
            var filters = FilterState()
            filters.propertyTypes = Set(answers.spaceTypes)
            if let region = answers.region { filters.regions = [region] }
            if let min = answers.budget?.min { filters.minPrice = String(min) }
            if let max = answers.budget?.max { filters.maxPrice = String(max) }
            // Long stay = "À louer" (monthly), short stay = "Court séjour" (daily).
            switch answers.stay {
            case "court": filters.activities = ["Court séjour"]
            case "long":  filters.activities = ["À louer"]
            default: break
            }
            let label = answers.summary.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? L("Ma recherche")
            SavedSearchStore.shared.add(label: label, query: "", filters: filters)
        }
        SessionTracker.shared.log("signup.onboarding.answered", [
            "intent": answers.intent?.rawValue ?? "",
            "types": answers.spaceTypes.joined(separator: ","),
            "region": answers.region ?? "",
            "budget": answers.budget?.label ?? "",
            "stay": answers.stay ?? "",
            "minDuration": answers.minDuration ?? 0,
        ])
        // Stored on the account (SearchPreference), and Home picks three
        // matching spaces from it a few seconds after arrival.
        let answers = answers
        Task { await answers.saveToAccount() }
        if answers.intent == .offering {
            UserDefaults.standard.set(true, forKey: OnboardingAnswers.becomeOwnerPendingKey)
        } else if answers.hasSearchCriteria {
            UserDefaults.standard.set(true, forKey: OnboardingAnswers.suggestionsPendingKey)
        }
        onFinish(answers)
    }

    private func log(_ name: String, _ step: Step) {
        SessionTracker.shared.log(name, ["step": "\(step)"])
    }

    // MARK: Options

    private static let spaceTypes: [(label: String, icon: String)] = [
        ("Chambres", "bed.double.fill"),
        ("Studios", "square.split.bottomrightquarter.fill"),
        ("Appartements", "building.2.fill"),
        ("Villas", "house.fill"),
        ("Bureaux", "briefcase.fill"),
        ("Boutiques", "bag.fill"),
        ("Coworking", "person.3.fill"),
        ("Commercial", "storefront.fill"),
    ]

    /// Photo of the régional capital where the app ships one; the others
    /// get a map pin.
    private static let regionImages: [String: String] = [
        "Littoral": "CityDouala", "Centre": "CityYaounde", "Ouest": "CityBafoussam",
        "Sud-Ouest": "CityBuea", "Nord-Ouest": "CityBamenda", "Sud": "CityKribi",
        "Nord": "CityGaroua", "Adamaoua": "CityNgaoundere", "Extrême-Nord": "CityMaroua",
        "Est": "CityBertoua",
    ]

    private static let budgets: [OnboardingAnswers.Budget] = [
        .init(label: "Moins de 50 000 FCFA", min: nil, max: 50_000),
        .init(label: "50 000 à 100 000 FCFA", min: 50_000, max: 100_000),
        .init(label: "100 000 à 200 000 FCFA", min: 100_000, max: 200_000),
        .init(label: "200 000 à 500 000 FCFA", min: 200_000, max: 500_000),
        .init(label: "Plus de 500 000 FCFA", min: 500_000, max: nil),
        .init(label: "Je ne sais pas encore", min: nil, max: nil),
    ]

    /// Per day, for court séjour: real nightly prices run ~10 000 to 300 000 FCFA.
    private static let dailyBudgets: [OnboardingAnswers.Budget] = [
        .init(label: "Moins de 20 000 FCFA", min: nil, max: 20_000),
        .init(label: "20 000 à 50 000 FCFA", min: 20_000, max: 50_000),
        .init(label: "50 000 à 100 000 FCFA", min: 50_000, max: 100_000),
        .init(label: "100 000 à 300 000 FCFA", min: 100_000, max: 300_000),
        .init(label: "Plus de 300 000 FCFA", min: 300_000, max: nil),
        .init(label: "Je ne sais pas encore", min: nil, max: nil),
    ]

    private static let monthDurations = [1, 3, 6, 12]
    private static let dayDurations = [1, 3, 7, 14]

    static func durationLabel(_ n: Int, days: Bool) -> String {
        if days { return n == 1 ? "1 jour" : "\(n) jours" }
        return n == 12 ? "12 mois (1 an)" : "\(n) mois"
    }
}

// MARK: - Question building blocks

private struct QuestionPage<Options: View>: View {
    var eyebrow: LocalizedStringKey? = nil
    var title: LocalizedStringKey
    var message: LocalizedStringKey
    @ViewBuilder var options: Options

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                if let eyebrow {
                    Text(eyebrow)
                        .font(.moblyBody(13, weight: .semibold))
                        .foregroundStyle(Color.moblyPrimary)
                        .padding(.bottom, 8)
                }
                Text(title)
                    .font(.moblyHeading(26))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
                Text(message)
                    .font(.moblyBody(14.5))
                    .foregroundStyle(Color(hex: 0x6B6F80))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 24)
                options
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 12)
        }
    }
}

/// Selected look shared by every option: blue outline on a tinted fill.
private struct OptionBackground: ViewModifier {
    var selected: Bool
    var radius: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(selected ? Color.moblySurfaceTint : Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(selected ? Color.moblyPrimary : Color(hex: 0xE2E4EC),
                            lineWidth: selected ? 2 : 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

private struct SelectionMark: View {
    var selected: Bool
    var body: some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(selected ? Color.moblyPrimary : Color(hex: 0xD3D6E0))
    }
}

private struct IntentCard: View {
    var icon: String
    var title: LocalizedStringKey
    var subtitle: LocalizedStringKey
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(selected ? .white : Color.moblyPrimary)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(selected ? Color.moblyPrimary : Color.moblySurfaceTint))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.moblyBody(16, weight: .bold))
                        .foregroundStyle(Color.moblyTextPrimary)
                    Text(subtitle)
                        .font(.moblyBody(13))
                        .foregroundStyle(Color(hex: 0x6B6F80))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                SelectionMark(selected: selected)
            }
            .padding(16)
            .modifier(OptionBackground(selected: selected))
        }
        .buttonStyle(.plain)
    }
}

private struct ChoiceTile: View {
    var icon: String
    var label: LocalizedStringKey
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.moblyPrimary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(selected ? Color.white : Color.moblySurfaceTint))
                Text(label)
                    .font(.moblyBody(14.5, weight: .semibold))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 58)
            .modifier(OptionBackground(selected: selected, radius: 16))
        }
        .buttonStyle(.plain)
    }
}

private struct RegionTile: View {
    var name: String
    var capital: String
    var imageName: String?
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if let imageName {
                        Image(imageName).resizable().scaledToFill()
                    } else {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.moblyPrimary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.moblySurfaceTint)
                    }
                }
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.moblyBody(14, weight: .semibold))
                        .foregroundStyle(Color.moblyTextPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(capital)
                        .font(.moblyBody(11.5))
                        .foregroundStyle(Color(hex: 0x6B6F80))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 58)
            .modifier(OptionBackground(selected: selected, radius: 16))
        }
        .buttonStyle(.plain)
    }
}

private struct BudgetRow: View {
    var label: LocalizedStringKey
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .font(.moblyBody(15, weight: .semibold))
                    .foregroundStyle(Color.moblyTextPrimary)
                Spacer()
                SelectionMark(selected: selected)
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .modifier(OptionBackground(selected: selected, radius: 16))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    SignupOnboardingFlow(firstName: "Jeanne") { _ in }
}
