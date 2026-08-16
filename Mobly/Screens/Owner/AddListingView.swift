import SwiftUI
import PhotosUI
import MapKit
import UniformTypeIdentifiers

private enum StayType { case court, long }   // Court séjour (≤1 mois) / Long séjour (>1 mois)

/// Conditional publish/edit wizard. The steps shown adapt to the choices:
/// stay type gates furnishing (court séjour = always meublé), category gates the
/// room count, furnishing swaps the amenity set, long séjour asks a minimum
/// duration, and the price unit is per jour (court) or per mois (long).
struct AddListingView: View {
    var editing: OwnerAnnonce? = nil
    var onCommit: (Listing) -> Void
    /// Show a "Passer" button on the first step. Set from the post-upgrade
    /// flow so a fresh owner can bail without publishing yet.
    var showSkipButton: Bool = false
    /// Called when the user taps "Passer". Falls back to `dismiss()` if left
    /// nil so the presenting view can decide where to route (owner dashboard,
    /// profile…). Not called on X — that path stays a plain dismiss.
    var onSkip: (() -> Void)? = nil

    init(editing: OwnerAnnonce? = nil,
         showSkipButton: Bool = false,
         onSkip: (() -> Void)? = nil,
         onCommit: @escaping (Listing) -> Void) {
        self.editing = editing
        self.showSkipButton = showSkipButton
        self.onSkip = onSkip
        self.onCommit = onCommit
        let l = editing?.listing
        _category  = State(initialValue: l?.category ?? ProcessInfo.processInfo.environment["ADD_CAT"] ?? "")
        _stay      = State(initialValue: (l?.deals.contains("Court séjour") ?? false) ? .court : .long)
        let (n, c) = AddListingView.splitLocation(l?.location ?? "")
        let env = ProcessInfo.processInfo.environment
        _neighborhood = State(initialValue: env["ADD_QUARTIER"] ?? n)
        _city         = State(initialValue: env["ADD_CITY"] ?? c)
        _region       = State(initialValue: env["ADD_REGION"]
                              ?? CameroonGeo.region(for: env["ADD_CITY"] ?? c)
                              ?? "")
        _title     = State(initialValue: l?.title ?? "")
        _about     = State(initialValue: l?.about ?? "")
        _rooms     = State(initialValue: AddListingView.parseRooms(l?.subtitle ?? "") ?? 1)
        _furnished = State(initialValue: l?.deals.contains("Meublé") ?? true)
        _priceValue = State(initialValue: (l?.price ?? "").filter(\.isNumber))
        _amenities  = State(initialValue: Set(l?.tags ?? []))
        _cover      = State(initialValue: l?.customImageData == nil ? (l?.imageName ?? "") : "")
        // Debug hook: preload a few bundled sample photos so the drag/drop
        // grid can be inspected without going through the picker first.
        var initialPhotos = l?.customImageData.map { [$0] } ?? []
        if initialPhotos.isEmpty,
           ProcessInfo.processInfo.environment["DEBUG_PHOTOS"] == "1" {
            initialPhotos = ["ListingGreen","ListingPink","ListingYellow","ListingTwilight","ListingLoft"]
                .compactMap { UIImage(named: $0)?.jpegData(compressionQuality: 0.8) }
        }
        _uploadedPhotos = State(initialValue: initialPhotos)
        _pinLat = State(initialValue: l?.lat)
        _pinLng = State(initialValue: l?.lng)
        _showMapPicker = State(initialValue: ProcessInfo.processInfo.environment["OPEN_MAP_PICKER"] == "1")
    }

    @Environment(\.dismiss) private var dismiss
    private var isEditing: Bool { editing != nil }

    // MARK: Steps (dynamic — some are skipped by the choices above)

    private enum Step { case type, stay, furnishing, infos, location, features, price, photos, review }

    /// The active ordered steps for the current choices.
    private var steps: [Step] {
        var s: [Step] = [.type, .stay]
        s.append(.furnishing)
        s += [.infos, .location, .features, .price, .photos, .review]
        return s
    }
    @State private var stepIndex: Int = {
        if let raw = ProcessInfo.processInfo.environment["ADD_STEP"], let i = Int(raw) { return i }
        return 0
    }()
    private var step: Step { steps[min(stepIndex, steps.count - 1)] }

    // MARK: Collected fields
    @State private var category: String
    @State private var stay: StayType
    @State private var region: String
    @State private var city: String
    @State private var neighborhood: String
    /// Precise map pin, filled in by the location picker. Optional so a user
    /// who really doesn't want to place a pin can still publish (they'll be
    /// rendered at the ville centroid by fallback).
    @State private var pinLat: Double? = nil
    @State private var pinLng: Double? = nil
    @State private var showMapPicker = false
    @State private var title: String
    @State private var about: String
    @State private var rooms: Int
    @State private var livingRooms: Int = 1
    @State private var kitchens: Int = 1
    @State private var bathrooms: Int = 1
    @State private var hasTerrace: Bool = false
    // Bureau / Commercial / Boutique
    @State private var offices: Int = 1
    @State private var meetingRooms: Int = 0
    @State private var toilets: Int = 1
    @State private var pieces: Int = 1
    @State private var hasVitrine: Bool = false
    @State private var hasReserve: Bool = false
    @State private var workstations: Int = 5
    @State private var coworkMeetingRooms: Int = 1
    @State private var minMonths: Int = 1
    @State private var furnished: Bool
    @State private var priceValue: String
    @State private var amenities: Set<String>
    @State private var cover: String
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var uploadedPhotos: [Data]
    @State private var coverIndex = 0
    /// Index of the thumbnail currently being dragged, or nil. Drives the
    /// scale/opacity feedback on the source cell + the accent outline on
    /// hovered drop targets.
    @State private var draggingIndex: Int? = nil
    @State private var loadingPhotos = false
    /// True while the review step's Publier button is uploading photos.
    @State private var isPublishing = false
    /// Non-nil = server publish failed. Surfaced as an alert so the owner
    /// isn't left thinking their annonce is safely online when it isn't
    /// (silent local-only saves were how the "Impossible d'ouvrir la
    /// conversation" bug got through — the listing existed only on device).
    @State private var publishError: String?

    private let categories = ["Chambres", "Studios", "Appartements", "Villas",
                              "Bureaux", "Boutiques", "Coworking", "Commercial"]
    private let cities = ["Douala", "Yaoundé", "Bafoussam", "Kribi", "Buéa", "Limbé"]
    private let covers = ["ListingGreen", "ListingPink", "ListingYellow", "ListingTwilight", "ListingLoft"]

    private let meubleAmenities = ["Wifi", "Climatisation", "Télévision", "Réfrigérateur",
                                   "Cuisine équipée", "Eau chaude", "Lit(s)", "Ménage inclus",
                                   "Parking", "Sécurité 24/7", "Groupe électrogène"]
    private let nonMeubleAmenities = ["Eau courante", "Électricité", "Carrelage", "Parking",
                                      "Sécurité 24/7", "Balcon", "Cour", "Groupe électrogène", "Forage"]
    private let bureauAmenities = ["Wifi", "Climatisation", "Ascenseur", "Parking",
                                   "Sécurité 24/7", "Groupe électrogène", "Imprimante",
                                   "Salle d'attente", "Accès handicapé", "Interphone"]
    private let boutiqueAmenities = ["Wifi", "Climatisation", "Parking", "Sécurité 24/7",
                                     "Groupe électrogène", "Enseigne extérieure",
                                     "Rideau métallique", "Comptoir", "Accès handicapé"]
    private let commercialAmenities = ["Wifi", "Climatisation", "Parking", "Sécurité 24/7",
                                       "Groupe électrogène", "Quai de chargement",
                                       "Enseigne extérieure", "Rideau métallique", "Accès handicapé"]
    private let coworkingAmenities = ["Wifi haut débit", "Climatisation", "Imprimante",
                                      "Parking", "Sécurité 24/7", "Groupe électrogène",
                                      "Cuisine / Cafétéria", "Casiers", "Accès handicapé", "Salle de pause"]
    private var activeAmenities: [String] {
        if isBureau { return bureauAmenities }
        if isBoutique { return boutiqueAmenities }
        if isCommercial { return commercialAmenities }
        if isCoworking { return coworkingAmenities }
        return furnished ? meubleAmenities : nonMeubleAmenities
    }

    /// Only multi-room dwellings ask for a bedroom count (a chambre has none).
    private var needsRooms: Bool { category == "Appartements" || category == "Villas" }
    private var isBureau: Bool { category == "Bureaux" }
    private var isBoutique: Bool { category == "Boutiques" }
    private var isCommercial: Bool { category == "Commercial" }
    private var isCoworking: Bool { category == "Coworking" }
    private var priceUnit: String { stay == .court ? "jour" : "mois" }

    private static func splitLocation(_ s: String) -> (String, String) {
        let parts = s.components(separatedBy: ", ")
        if parts.count >= 2 { return (parts[0], parts[1]) }
        return ("", parts.first ?? "")
    }
    private static func parseRooms(_ s: String) -> Int? {
        let scanner = s.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
        return scanner.first.flatMap(Int.init)
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            topBar
            progressBar
            ScrollView(showsIndicators: false) {
                stepBody
                    .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 30)
            }
            footer
        }
        .background(Color.moblySurface.ignoresSafeArea())
    }

    private var topBar: some View {
        HStack {
            Button { back() } label: {
                Image(systemName: stepIndex == 0 ? "xmark" : "chevron.left")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.moblyTextPrimary)
                    .frame(width: 42, height: 42)
                    .background(RoundedRectangle(cornerRadius: 14).fill(.white)
                        .shadow(color: Color(hex: 0x14152A).opacity(0.06), radius: 8, y: 2))
            }
            Spacer()
            Text(isEditing ? "Modifier l'annonce" : "Publier un espace")
                .font(.moblyHeading(17)).foregroundStyle(Color.moblyTextPrimary)
            Spacer()
            // "Passer" only makes sense on the first step and only in the
            // fresh-owner flow (post-upgrade). After step 0 the wizard is
            // committed enough that "Passer" would just lose their work.
            if showSkipButton && stepIndex == 0 && !isEditing {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if let onSkip { onSkip() } else { dismiss() }
                } label: {
                    Text("Passer")
                        .font(.moblyBody(14, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x666F80))
                        .padding(.horizontal, 14).frame(height: 42)
                        .background(Capsule().fill(.white)
                            .shadow(color: Color(hex: 0x14152A).opacity(0.05), radius: 6, y: 2))
                }
            } else {
                Color.clear.frame(width: 42, height: 42)
            }
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            let frac = CGFloat(stepIndex + 1) / CGFloat(steps.count)
            ZStack(alignment: .leading) {
                Capsule().fill(Color(hex: 0xE2E4EC))
                Capsule().fill(Color.moblyPrimary).frame(width: geo.size.width * frac)
            }
        }
        .frame(height: 5).padding(.horizontal, 20)
        .animation(.easeInOut(duration: 0.25), value: stepIndex)
    }

    @ViewBuilder private var stepBody: some View {
        switch step {
        case .type:       typeStep
        case .stay:       stayStep
        case .furnishing: furnishingStep
        case .infos:      infosStep
        case .location:   locationStep
        case .features:   featuresStep
        case .price:      priceStep
        case .photos:     photosStep
        case .review:     reviewStep
        }
    }

    private func stepHeader(_ t: String, _ s: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LT(t)).font(.moblyHeading(22)).foregroundStyle(Color.moblyTextPrimary)
            Text(s).font(.moblyBody(13)).foregroundStyle(Color(hex: 0x9A9DAC))
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 4)
    }

    // MARK: Step 1 — category
    private var typeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader("Quel type d'espace ?", "Choisissez la catégorie de votre bien.")
            chipGrid(categories, selection: category) { category = $0 }
        }
    }

    // MARK: Step 2 — stay type
    private var stayStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepHeader("Type de location", "Court séjour se paie au jour, long séjour au mois.")
            optionCard(title: "Court séjour", subtitle: "Max 1 mois · prix par jour",
                       icon: "calendar.badge.clock", selected: stay == .court) {
                stay = .court
            }
            optionCard(title: "Long séjour", subtitle: "Plus d'1 mois · prix par mois",
                       icon: "calendar", selected: stay == .long) { stay = .long }
        }
    }

    // MARK: Step 3 — furnishing (long séjour only)
    private var furnishingStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepHeader("Meublé ou non meublé ?", "Cela change les équipements demandés ensuite.")
            optionCard(title: "Meublé", subtitle: "Prêt à vivre, équipé",
                       icon: "sofa.fill", selected: furnished) { furnished = true }
            optionCard(title: "Non meublé", subtitle: "Vide, location au mois",
                       icon: "cube.box", selected: !furnished) { furnished = false }
        }
    }

    // MARK: Step 4 — title + description
    private var infosStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader("Décrivez votre espace", "Un titre clair et une description honnête attirent plus de contacts.")
            sectionLabel("TITRE")
            fieldBox { TextField("Ex. Studio meublé à Akwa", text: $title) }
            sectionLabel("DESCRIPTION")
            ZStack(alignment: .topLeading) {
                if about.isEmpty {
                    Text("Ambiance, atouts, voisinage, ce qui rend l'espace unique…")
                        .font(.moblyBody(14)).foregroundStyle(Color(hex: 0xB4B7C2))
                        .padding(.horizontal, 16).padding(.vertical, 18)
                }
                TextEditor(text: $about)
                    .font(.moblyBody(14)).foregroundStyle(Color.moblyTextPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(minHeight: 150, alignment: .topLeading)
            }
            .background(RoundedRectangle(cornerRadius: 14).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(hex: 0xE2E4EC), lineWidth: 1.5))
            HStack {
                Spacer()
                Text("\(aboutCount) caractères · 40 min.")
                    .font(.moblyBody(11.5))
                    .foregroundStyle(aboutCount >= 40 ? Color(hex: 0x1F8A5B) : Color(hex: 0x9A9DAC))
            }
        }
    }
    private var aboutCount: Int { about.trimmingCharacters(in: .whitespacesAndNewlines).count }

    // MARK: Step 5 — location (cascading région → ville → quartier)
    private var locationStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeader("Où se trouve l'espace ?", "Choisissez la région, puis la ville, puis le quartier.")
            sectionLabel("RÉGION")
            chipGrid(CameroonGeo.regions.map(\.name), selection: region) { r in
                if r != region { withAnimation(.easeInOut(duration: 0.25)) { region = r; city = ""; neighborhood = "" } }
            }
            if let reg = CameroonGeo.regions.first(where: { $0.name == region }) {
                sectionLabel("VILLE")
                chipGrid(reg.cities, selection: city) { c in
                    if c != city { withAnimation(.easeInOut(duration: 0.25)) { city = c; neighborhood = "" } }
                }
            }
            if !city.isEmpty {
                sectionLabel("QUARTIER")
                let known = CameroonGeo.quartiers(for: city)
                if !known.isEmpty {
                    chipGrid(known, selection: neighborhood) { neighborhood = $0 }
                    Text("Votre quartier n'est pas listé ?")
                        .font(.moblyBody(11.5)).foregroundStyle(Color(hex: 0x9A9DAC))
                }
                fieldBox { TextField(known.isEmpty ? "Saisissez le quartier" : "Autre quartier", text: $neighborhood) }
            }

            // Once région / ville / quartier are set, offer a map picker so
            // the owner can drop a precise pin — helps the visitor find the
            // exact building instead of a vague neighbourhood marker.
            if !city.isEmpty && !neighborhood.isEmpty {
                mapTile
                    .padding(.top, 6)
            }
        }
        .alert("Publication en ligne échouée",
               isPresented: Binding(
                   get: { publishError != nil },
                   set: { if !$0 { publishError = nil } }
               ),
               presenting: publishError) { _ in
            Button("OK", role: .cancel) { publishError = nil }
        } message: { msg in
            Text(LT(msg))
        }
        .fullScreenCover(isPresented: $showMapPicker) {
            LocationPinPicker(
                initial: CameroonGeo.coordinate(for: city),
                existing: pinLat.flatMap { lat in
                    pinLng.map { lng in CLLocationCoordinate2D(latitude: lat, longitude: lng) }
                },
                // Fed to CLGeocoder so the map opens on the quartier, not
                // just the ville — e.g. "Ekounou, Yaoundé".
                searchQuery: locationQuery,
                onConfirm: { coord in
                    pinLat = coord.latitude
                    pinLng = coord.longitude
                    showMapPicker = false
                },
                onCancel: { showMapPicker = false }
            )
        }
    }

    /// Free-text location string used to geocode the initial map camera.
    /// Prefers the most specific labels available so the map opens as close
    /// to the actual space as possible.
    private var locationQuery: String {
        let n = neighborhood.trimmingCharacters(in: .whitespaces)
        let parts = [n, city, region].filter { !$0.isEmpty }
        return parts.joined(separator: ", ")
    }

    /// Map-preview card that opens the pin picker. Doubles as the "already
    /// pinned" summary once the user has confirmed a spot.
    private var mapTile: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showMapPicker = true
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(pinLat != nil ? Color(hex: 0xE9F9EF) : Color.moblySurfaceTint)
                        .frame(width: 52, height: 52)
                    Image(systemName: pinLat != nil ? "mappin.circle.fill" : "map.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(pinLat != nil ? Color(hex: 0x1F8A5B) : Color.moblyPrimary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(pinLat != nil ? "Position confirmée" : "Placer sur la carte")
                        .font(.moblyHeading(14.5))
                        .foregroundStyle(Color.moblyTextPrimary)
                    Text(pinLat != nil
                         ? "Touchez pour ajuster la punaise sur la carte 3D."
                         : "Ouvrez la carte satellite/3D et déposez la punaise.")
                        .font(.moblyBody(11.5))
                        .foregroundStyle(Color(hex: 0x9A9DAC))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xC4C7D2))
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16).fill(.white))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(pinLat != nil ? Color(hex: 0x1F8A5B).opacity(0.4) : Color(hex: 0xE2E4EC),
                            lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var isApartment: Bool { category == "Appartements" }

    // MARK: Step 6 — features (conditional: rooms, amenities set, min duration)
    private var featuresStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeader("Caractéristiques", "Renseignez les détails propres à votre espace.")

            if isApartment {
                HStack {
                    Text("Chambres").font(.moblyHeading(15)).foregroundStyle(Color.moblyTextPrimary)
                    Spacer()
                    stepper($rooms, range: 1...12)
                }
                HStack {
                    Text("Salon").font(.moblyHeading(15)).foregroundStyle(Color.moblyTextPrimary)
                    Spacer()
                    stepper($livingRooms, range: 0...4)
                }
                HStack {
                    Text("Cuisines").font(.moblyHeading(15)).foregroundStyle(Color.moblyTextPrimary)
                    Spacer()
                    stepper($kitchens, range: 0...4)
                }
                HStack {
                    Text("Salle de bain").font(.moblyHeading(15)).foregroundStyle(Color.moblyTextPrimary)
                    Spacer()
                    stepper($bathrooms, range: 1...6)
                }
                HStack {
                    Text("Terrasse / Véranda").font(.moblyHeading(15)).foregroundStyle(Color.moblyTextPrimary)
                    Spacer()
                    Button { withAnimation(.easeInOut(duration: 0.2)) { hasTerrace.toggle() } } label: {
                        Image(systemName: hasTerrace ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 24))
                            .foregroundStyle(hasTerrace ? Color.moblyPrimary : Color(hex: 0xD5D8E2))
                    }.buttonStyle(.plain)
                }
                Divider().padding(.vertical, 2)
            } else if needsRooms {
                HStack {
                    Text("Chambres").font(.moblyHeading(15)).foregroundStyle(Color.moblyTextPrimary)
                    Spacer()
                    stepper($rooms, range: 1...12)
                }
            } else if isBureau {
                HStack {
                    Text("Bureaux").font(.moblyHeading(15)).foregroundStyle(Color.moblyTextPrimary)
                    Spacer()
                    stepper($offices, range: 1...20)
                }
                HStack {
                    Text("Salle de réunion").font(.moblyHeading(15)).foregroundStyle(Color.moblyTextPrimary)
                    Spacer()
                    stepper($meetingRooms, range: 0...5)
                }
                HStack {
                    Text("Toilettes").font(.moblyHeading(15)).foregroundStyle(Color.moblyTextPrimary)
                    Spacer()
                    stepper($toilets, range: 0...6)
                }
                Divider().padding(.vertical, 2)
            } else if isBoutique {
                HStack {
                    Text("Pièces").font(.moblyHeading(15)).foregroundStyle(Color.moblyTextPrimary)
                    Spacer()
                    stepper($pieces, range: 1...10)
                }
                HStack {
                    Text("Toilettes").font(.moblyHeading(15)).foregroundStyle(Color.moblyTextPrimary)
                    Spacer()
                    stepper($toilets, range: 0...4)
                }
                HStack {
                    Text("Vitrine").font(.moblyHeading(15)).foregroundStyle(Color.moblyTextPrimary)
                    Spacer()
                    Button { withAnimation(.easeInOut(duration: 0.2)) { hasVitrine.toggle() } } label: {
                        Image(systemName: hasVitrine ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 24))
                            .foregroundStyle(hasVitrine ? Color.moblyPrimary : Color(hex: 0xD5D8E2))
                    }.buttonStyle(.plain)
                }
                HStack {
                    Text("Réserve / Stock").font(.moblyHeading(15)).foregroundStyle(Color.moblyTextPrimary)
                    Spacer()
                    Button { withAnimation(.easeInOut(duration: 0.2)) { hasReserve.toggle() } } label: {
                        Image(systemName: hasReserve ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 24))
                            .foregroundStyle(hasReserve ? Color.moblyPrimary : Color(hex: 0xD5D8E2))
                    }.buttonStyle(.plain)
                }
                Divider().padding(.vertical, 2)
            } else if isCommercial {
                HStack {
                    Text("Pièces").font(.moblyHeading(15)).foregroundStyle(Color.moblyTextPrimary)
                    Spacer()
                    stepper($pieces, range: 1...10)
                }
                HStack {
                    Text("Toilettes").font(.moblyHeading(15)).foregroundStyle(Color.moblyTextPrimary)
                    Spacer()
                    stepper($toilets, range: 0...6)
                }
                HStack {
                    Text("Vitrine").font(.moblyHeading(15)).foregroundStyle(Color.moblyTextPrimary)
                    Spacer()
                    Button { withAnimation(.easeInOut(duration: 0.2)) { hasVitrine.toggle() } } label: {
                        Image(systemName: hasVitrine ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 24))
                            .foregroundStyle(hasVitrine ? Color.moblyPrimary : Color(hex: 0xD5D8E2))
                    }.buttonStyle(.plain)
                }
                Divider().padding(.vertical, 2)
            } else if isCoworking {
                HStack {
                    Text("Postes de travail").font(.moblyHeading(15)).foregroundStyle(Color.moblyTextPrimary)
                    Spacer()
                    stepper($workstations, range: 1...100)
                }
                HStack {
                    Text("Salles de réunion").font(.moblyHeading(15)).foregroundStyle(Color.moblyTextPrimary)
                    Spacer()
                    stepper($coworkMeetingRooms, range: 0...10)
                }
                HStack {
                    Text("Toilettes").font(.moblyHeading(15)).foregroundStyle(Color.moblyTextPrimary)
                    Spacer()
                    stepper($toilets, range: 0...6)
                }
                Divider().padding(.vertical, 2)
            }

            sectionLabel(isBureau || isBoutique || isCommercial || isCoworking ? "ÉQUIPEMENTS"
                        : furnished ? "ÉQUIPEMENTS (MEUBLÉ)" : "CARACTÉRISTIQUES (NON MEUBLÉ)")
            chipGridMulti(activeAmenities, selection: amenities) { a in
                if amenities.contains(a) { amenities.remove(a) } else { amenities.insert(a) }
            }

            if stay == .long {
                Divider().padding(.vertical, 2)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Durée minimale").font(.moblyHeading(15)).foregroundStyle(Color.moblyTextPrimary)
                        Text("Nombre de mois minimum de location").font(.moblyBody(11.5)).foregroundStyle(Color(hex: 0x9A9DAC))
                    }
                    Spacer()
                    stepper($minMonths, range: 1...24, suffix: "mois")
                }
            }
        }
    }

    // MARK: Step 7 — price (unit depends on stay)
    private var priceStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeader(stay == .court ? "Prix par jour" : "Loyer mensuel",
                       stay == .court ? "Montant facturé par jour." : "Montant du loyer par mois.")
            fieldBox {
                HStack {
                    TextField("0", text: $priceValue).keyboardType(.numberPad).font(.moblyHeading(20))
                    Text("FCFA / \(priceUnit)").font(.moblyHeading(15)).foregroundStyle(Color(hex: 0x9A9DAC))
                }
            }
            if (Int(digits(priceValue)) ?? 0) > 0 {
                Text("\(formattedPrice) / \(priceUnit)").font(.moblyBody(13)).foregroundStyle(Color.moblyPrimary)
            }
        }
    }

    // MARK: Step 8 — photos
    //
    // Owner-uploaded photos only. Two ways to set the cover:
    //   • **Tap** a thumbnail — promotes it to cover in place.
    //   • **Long-press + drag** — reorder the photos; the one that ends up in
    //     position 0 becomes the cover. Matches how iOS Photos works, so most
    //     users will already know the interaction.
    private var photosStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeader("Photos de l'espace", uploadedPhotos.isEmpty
                       ? "Ajoutez des photos de votre espace. La première sera la couverture — vous pourrez la changer ensuite."
                       : "Touchez ou faites glisser une photo pour la définir comme couverture.")

            PhotosPicker(selection: $pickerItems, matching: .images) {
                HStack(spacing: 10) {
                    Image(systemName: loadingPhotos ? "arrow.triangle.2.circlepath" : "photo.badge.plus")
                        .font(.system(size: 18, weight: .semibold))
                    Text(uploadedPhotos.isEmpty ? "Ajouter des photos" : "Ajouter d'autres photos")
                        .font(.moblyHeading(15))
                }
                .foregroundStyle(Color.moblyPrimary)
                .frame(maxWidth: .infinity).frame(height: 54)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color(hex: 0xEEF0FE)))
            }
            .onChange(of: pickerItems) { _, items in loadPhotos(items) }

            if !uploadedPhotos.isEmpty {
                // Cover preview — big, obvious, tells the user which photo is
                // going to represent their space in every list.
                if let coverUI = coverUIImage {
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: coverUI)
                            .resizable().aspectRatio(contentMode: .fill)
                            .frame(maxWidth: .infinity).frame(height: 200)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                        HStack(spacing: 5) {
                            Image(systemName: "star.fill").font(.system(size: 10, weight: .bold))
                            Text("Couverture").font(.moblyBody(11, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(Color.moblyPrimary))
                        .padding(12)
                    }
                }

                Text("\(uploadedPhotos.count) photo\(uploadedPhotos.count > 1 ? "s" : "")")
                    .font(.moblyBody(12, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x9A9DAC))

                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 10),
                              GridItem(.flexible(), spacing: 10),
                              GridItem(.flexible(), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(Array(uploadedPhotos.enumerated()), id: \.offset) { i, data in
                        if let ui = UIImage(data: data) {
                            photoThumb(ui: ui, index: i)
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.22), value: uploadedPhotos.count)
                .animation(.easeInOut(duration: 0.22), value: coverIndex)
            }
        }
    }

    private var coverUIImage: UIImage? {
        guard uploadedPhotos.indices.contains(coverIndex) else { return nil }
        return UIImage(data: uploadedPhotos[coverIndex])
    }

    /// A single thumbnail with tap-to-cover **and** drag-to-reorder. The
    /// dragged item carries its source index as a string payload; the drop
    /// target reads that index and calls `movePhoto(from:to:)`. Position 0
    /// is the cover, so dragging any photo to slot 0 auto-promotes it.
    @ViewBuilder
    private func photoThumb(ui: UIImage, index i: Int) -> some View {
        ZStack(alignment: .topLeading) {
            Image(uiImage: ui)
                .resizable().aspectRatio(1, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .stroke(coverIndex == i ? Color.moblyPrimary : (i == draggingIndex ? Color.moblyAccent : .clear),
                            lineWidth: 3))
            if coverIndex == i {
                Image(systemName: "star.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(Circle().fill(Color.moblyPrimary))
                    .padding(6)
            }
            if i == 0 {
                // Small "COUVERTURE" hint on the very first slot — makes it
                // obvious *which* position promotes on drop, not just that
                // the current cover has a star.
                Text("COUVERTURE")
                    .font(.moblyBody(8, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Capsule().fill(Color.moblyPrimary.opacity(0.9)))
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .opacity(coverIndex == 0 ? 0 : 0.9) // avoid stacking with the star
                    .offset(y: 44)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { removePhoto(at: i) } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 20))
                    .foregroundStyle(.white, .black.opacity(0.5))
            }.padding(5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .scaleEffect(draggingIndex == i ? 1.05 : 1)
        .opacity(draggingIndex == i ? 0.9 : 1)
        .animation(.easeInOut(duration: 0.18), value: draggingIndex)
        .onTapGesture {
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.easeInOut(duration: 0.2)) { coverIndex = i }
        }
        .onDrag {
            draggingIndex = i
            return NSItemProvider(object: String(i) as NSString)
        }
        .onDrop(of: [.text], delegate: PhotoDropDelegate(
            targetIndex: i,
            draggingIndex: $draggingIndex,
            perform: movePhoto
        ))
    }

    /// Move the photo from `from` to `to` (single insert/remove — SwiftUI's
    /// `Array.move` doesn't handle the target-past-source case correctly for
    /// our simple case, but this is fine and easier to reason about). Updates
    /// `coverIndex` so it points at the same photo after the move; if the
    /// photo landed at index 0, it becomes the new cover automatically.
    private func movePhoto(from: Int, to: Int) {
        guard from != to,
              uploadedPhotos.indices.contains(from),
              (0...uploadedPhotos.count).contains(to)
        else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            let item = uploadedPhotos.remove(at: from)
            let insertAt = to > from ? to - 1 : to
            uploadedPhotos.insert(item, at: insertAt)

            // Follow the cover photo through the reorder.
            if coverIndex == from {
                coverIndex = insertAt
            } else if from < coverIndex && insertAt >= coverIndex {
                coverIndex -= 1
            } else if from > coverIndex && insertAt <= coverIndex {
                coverIndex += 1
            }
            // Dropped in slot 0 → new cover, no matter which one was cover before.
            if insertAt == 0 { coverIndex = 0 }
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    // MARK: Step 9 — review
    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader(isEditing ? "Vérifiez et enregistrez" : "Vérifiez et publiez",
                       isEditing ? "Vos modifications seront visibles aussitôt." : "Un dernier coup d'œil avant la mise en ligne.")
            Group {
                if let data = coverData, let ui = UIImage(data: data) {
                    Image(uiImage: ui).resizable().aspectRatio(contentMode: .fill)
                } else if !cover.isEmpty {
                    Image(cover).resizable().aspectRatio(contentMode: .fill)
                }
            }
            .frame(height: 160).frame(maxWidth: .infinity).clipped()
            .clipShape(RoundedRectangle(cornerRadius: 18))

            VStack(spacing: 0) {
                reviewRow("Titre", title.isEmpty ? "—" : title)
                reviewRow("Description", about.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "—" : about.trimmingCharacters(in: .whitespacesAndNewlines))
                reviewRow("Type", category.isEmpty ? "—" : "\(category) · \(stay == .court ? "Court séjour" : "Long séjour")")
                if stay == .long { reviewRow("Meublé", furnished ? "Oui" : "Non") }
                reviewRow("Lieu", locationLabel.isEmpty ? "—" : locationLabel)
                if isApartment {
                    reviewRow("Chambres", "\(rooms)")
                    reviewRow("Salon", "\(livingRooms)")
                    reviewRow("Cuisines", "\(kitchens)")
                    reviewRow("Salle de bain", "\(bathrooms)")
                    reviewRow("Terrasse", hasTerrace ? "Oui" : "Non")
                } else if needsRooms {
                    reviewRow("Chambres", "\(rooms)")
                } else if isBureau {
                    reviewRow("Bureaux", "\(offices)")
                    reviewRow("Salle de réunion", "\(meetingRooms)")
                    reviewRow("Toilettes", "\(toilets)")
                } else if isBoutique {
                    reviewRow("Pièces", "\(pieces)")
                    reviewRow("Toilettes", "\(toilets)")
                    reviewRow("Vitrine", hasVitrine ? "Oui" : "Non")
                    reviewRow("Réserve", hasReserve ? "Oui" : "Non")
                } else if isCommercial {
                    reviewRow("Pièces", "\(pieces)")
                    reviewRow("Toilettes", "\(toilets)")
                    reviewRow("Vitrine", hasVitrine ? "Oui" : "Non")
                } else if isCoworking {
                    reviewRow("Postes de travail", "\(workstations)")
                    reviewRow("Salles de réunion", "\(coworkMeetingRooms)")
                    reviewRow("Toilettes", "\(toilets)")
                }
                if stay == .long { reviewRow("Durée min.", "\(minMonths) mois") }
                reviewRow("Prix", "\(formattedPrice) / \(priceUnit)", last: true)
            }
            .background(RoundedRectangle(cornerRadius: 18).fill(.white)
                .shadow(color: Color(hex: 0x14152A).opacity(0.05), radius: 9, y: 3))

            if !amenities.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("ÉQUIPEMENTS").font(.moblyBody(12, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x9A9DAC)).tracking(0.3)
                    WrapLayout(spacing: 8) {
                        ForEach(amenities.sorted(), id: \.self) { tag in
                            Text(tag).font(.moblyBody(13, weight: .medium))
                                .foregroundStyle(Color.moblyPrimary)
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(Capsule().fill(Color(hex: 0xEEF0FE)))
                        }
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 18).fill(.white)
                    .shadow(color: Color(hex: 0x14152A).opacity(0.05), radius: 9, y: 3))
            }
        }
    }

    private func reviewRow(_ k: String, _ v: String, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(k).font(.moblyBody(13)).foregroundStyle(Color(hex: 0x9A9DAC))
                Spacer()
                Text(LT(v)).font(.moblyHeading(14)).foregroundStyle(Color.moblyTextPrimary).multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            if !last { Divider().padding(.leading, 16) }
        }
    }

    // MARK: Footer
    private var footer: some View {
        VStack(spacing: 4) {
            Divider()
            PillButton(title: footerTitle,
                       style: step == .review ? .primaryOrange : .primaryBlue,
                       trailingIcon: step == .review ? (isPublishing ? nil : "checkmark") : "arrow.right") {
                if !isPublishing { next() }
            }
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
            .opacity(canAdvance && !isPublishing ? 1 : 0.5)
            .allowsHitTesting(canAdvance && !isPublishing)

            if isPublishing {
                Text("Publication en cours… vos photos sont envoyées sur le serveur.")
                    .font(.moblyBody(11))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                    .padding(.bottom, 6)
            }
        }
        .background(Color.moblySurface)
    }

    private var footerTitle: String {
        if step != .review { return "Continuer" }
        if isPublishing { return isEditing ? "Enregistrement…" : "Publication…" }
        return isEditing ? "Enregistrer" : "Publier l'annonce"
    }

    // MARK: Reusable controls
    private func chipGrid(_ items: [String], selection: String, action: @escaping (String) -> Void) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(items, id: \.self) { item in selectPill(item, selected: selection == item) { action(item) } }
        }
    }
    private func chipGridMulti(_ items: [String], selection: Set<String>, action: @escaping (String) -> Void) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(items, id: \.self) { item in selectPill(item, selected: selection.contains(item)) { action(item) } }
        }
    }
    private func selectPill(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button { UISelectionFeedbackGenerator().selectionChanged(); action() } label: {
            Text(LT(label)).font(.moblyHeading(14))
                .foregroundStyle(selected ? .white : Color.moblyTextPrimary)
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .background(RoundedRectangle(cornerRadius: 14).fill(selected ? Color.moblyPrimary : .white))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? .clear : Color(hex: 0xE2E4EC), lineWidth: 1.5))
        }.buttonStyle(.plain)
    }
    private func optionCard(title: String, subtitle: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button { UISelectionFeedbackGenerator().selectionChanged(); withAnimation(.easeInOut(duration: 0.2)) { action() } } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(selected ? Color.moblyPrimary : Color(hex: 0xEEF0FE))
                    Image(systemName: icon).font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(selected ? .white : Color.moblyPrimary)
                }.frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LT(title)).font(.moblyHeading(16)).foregroundStyle(Color.moblyTextPrimary)
                    Text(LT(subtitle)).font(.moblyBody(12)).foregroundStyle(Color(hex: 0x9A9DAC))
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20)).foregroundStyle(selected ? Color.moblyPrimary : Color(hex: 0xD5D8E2))
            }
            .padding(15)
            .background(RoundedRectangle(cornerRadius: 16).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(selected ? Color.moblyPrimary : Color(hex: 0xE2E4EC), lineWidth: selected ? 2 : 1.5))
        }.buttonStyle(.plain)
    }
    private func fieldBox<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().padding(.horizontal, 16).padding(.vertical, 15)
            .background(RoundedRectangle(cornerRadius: 14).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(hex: 0xE2E4EC), lineWidth: 1.5))
    }
    private func sectionLabel(_ t: String) -> some View {
        Text(LT(t)).font(.moblyBody(12, weight: .semibold)).foregroundStyle(Color(hex: 0x9A9DAC)).tracking(0.3)
    }
    private func stepper(_ value: Binding<Int>, range: ClosedRange<Int>, suffix: String? = nil) -> some View {
        HStack(spacing: 14) {
            Button { if value.wrappedValue > range.lowerBound { value.wrappedValue -= 1 } } label: {
                Image(systemName: "minus").font(.system(size: 15, weight: .bold)).frame(width: 34, height: 34)
                    .background(Circle().fill(Color(hex: 0xEEF0FE))).foregroundStyle(Color.moblyPrimary)
            }
            Text(suffix == nil ? "\(value.wrappedValue)" : "\(value.wrappedValue) \(suffix!)")
                .font(.moblyHeading(16)).frame(minWidth: 22)
            Button { if value.wrappedValue < range.upperBound { value.wrappedValue += 1 } } label: {
                Image(systemName: "plus").font(.system(size: 15, weight: .bold)).frame(width: 34, height: 34)
                    .background(Circle().fill(Color(hex: 0xEEF0FE))).foregroundStyle(Color.moblyPrimary)
            }
        }.buttonStyle(.plain)
    }

    // MARK: Logic
    //
    // Every step is mandatory — "Continuer" stays disabled until the user
    // fills in what's needed. Skipping any step leaves the annonce with an
    // incomplete profile that hurts its discoverability, so the wizard
    // holds the user's hand instead of letting them race through empty
    // sections.
    private var canAdvance: Bool {
        switch step {
        case .type:       return !category.isEmpty
        case .stay:       return true      // stay is a two-tap picker with a default
        case .furnishing: return true      // hard picker: one of two choices, already set
        case .infos:      return !title.trimmingCharacters(in: .whitespaces).isEmpty && aboutCount >= 40
        case .location:
            // Région / ville / quartier must all be set AND the user must
            // have dropped a pin on the map. The pin is what makes the
            // annonce actually findable — accepting "quartier only" would
            // spawn listings that show up at the ville centroid forever.
            return !region.isEmpty
                && !city.isEmpty
                && !neighborhood.trimmingCharacters(in: .whitespaces).isEmpty
                && pinLat != nil && pinLng != nil
        case .features:
            // Room count is only asked for categories that need it. Amenities
            // are always asked — at least one must be picked so the annonce
            // shows some equipment on the detail page.
            let roomsOK = !isApartment || rooms > 0
            return roomsOK && !amenities.isEmpty
        case .price:      return (Int(digits(priceValue)) ?? 0) > 0
        case .photos:
            // Real, uploaded photos only. The bundled example gallery is gone,
            // so an annonce with no photos would render as a blank card.
            return !uploadedPhotos.isEmpty
        case .review:     return true
        }
    }
    private func next() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if step == .review { publish(); return }
        withAnimation(.easeInOut(duration: 0.28)) { stepIndex = min(stepIndex + 1, steps.count - 1) }
    }
    private func back() {
        if stepIndex == 0 { dismiss(); return }
        withAnimation(.easeInOut(duration: 0.28)) { stepIndex = max(stepIndex - 1, 0) }
    }

    /// Load the freshly picked items and *append* them to the existing set,
    /// so the user can add more photos across multiple picker sessions
    /// without losing the ones they already picked. `pickerItems` is cleared
    /// at the end so a subsequent pick that includes some of the same items
    /// doesn't count them as duplicates for the picker's internal state.
    private func loadPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        loadingPhotos = true
        cover = ""    // any previously-selected bundled cover is now moot
        Task {
            var added: [Data] = []
            for item in items {
                if let d = try? await item.loadTransferable(type: Data.self) {
                    added.append(d)
                }
            }
            await MainActor.run {
                let wasEmpty = uploadedPhotos.isEmpty
                uploadedPhotos.append(contentsOf: added)
                // First-ever pick: the first photo is the cover by default.
                if wasEmpty { coverIndex = 0 }
                pickerItems = []
                loadingPhotos = false
            }
        }
    }
    private func removePhoto(at i: Int) {
        uploadedPhotos.remove(at: i)
        if coverIndex >= uploadedPhotos.count { coverIndex = max(0, uploadedPhotos.count - 1) }
        else if i < coverIndex { coverIndex -= 1 }
    }
    private var coverData: Data? { uploadedPhotos.indices.contains(coverIndex) ? uploadedPhotos[coverIndex] : nil }

    private func publish() {
        var deals = [stay == .court ? "Court séjour" : "À louer"]
        deals.append(furnished ? "Meublé" : "Non meublé")
        var tags = Array(amenities.sorted().prefix(3))
        if tags.isEmpty { tags = [furnished ? "Meublé" : "Non meublé"] }
        var subParts = [furnished ? "Meublé" : "Non meublé"]
        if isApartment {
            subParts.append("\(rooms) ch · \(livingRooms) salon · \(bathrooms) sdb")
            if hasTerrace { subParts.append("Terrasse") }
        } else if needsRooms {
            subParts.append("\(rooms) ch")
        } else if isBureau {
            subParts.append("\(offices) bureau\(offices > 1 ? "x" : "") · \(meetingRooms) réunion · \(toilets) wc")
        } else if isBoutique {
            subParts.append("\(pieces) pièce\(pieces > 1 ? "s" : "") · \(toilets) wc")
            if hasVitrine { subParts.append("Vitrine") }
            if hasReserve { subParts.append("Réserve") }
        } else if isCommercial {
            subParts.append("\(pieces) pièce\(pieces > 1 ? "s" : "") · \(toilets) wc")
            if hasVitrine { subParts.append("Vitrine") }
        } else if isCoworking {
            subParts.append("\(workstations) postes · \(coworkMeetingRooms) réunion · \(toilets) wc")
        }
        var feats: [String: String] = [:]
        if isApartment {
            feats["Chambres"] = "\(rooms)"
            feats["Salon"] = "\(livingRooms)"
            feats["Cuisines"] = "\(kitchens)"
            feats["Salle de bain"] = "\(bathrooms)"
            feats["Terrasse"] = hasTerrace ? "Oui" : "Non"
        } else if needsRooms {
            feats["Chambres"] = "\(rooms)"
        } else if isBureau {
            feats["Bureaux"] = "\(offices)"
            feats["Salle de réunion"] = "\(meetingRooms)"
            feats["Toilettes"] = "\(toilets)"
        } else if isBoutique {
            feats["Pièces"] = "\(pieces)"
            feats["Toilettes"] = "\(toilets)"
            feats["Vitrine"] = hasVitrine ? "Oui" : "Non"
            feats["Réserve"] = hasReserve ? "Oui" : "Non"
        } else if isCommercial {
            feats["Pièces"] = "\(pieces)"
            feats["Toilettes"] = "\(toilets)"
            feats["Vitrine"] = hasVitrine ? "Oui" : "Non"
        } else if isCoworking {
            feats["Postes de travail"] = "\(workstations)"
            feats["Salles de réunion"] = "\(coworkMeetingRooms)"
            feats["Toilettes"] = "\(toilets)"
        }
        let existing = editing?.listing
        // Fall back to the signed-in user's name so the detail page never says
        // just "Propriétaire" — even if the server publish below fails, the
        // annonce shows who posted it. Server response overwrites this later.
        let me = AuthStore.shared.user
        let displayName = me?.fullName
            ?? (Session.shared.fullName.isEmpty ? nil : Session.shared.fullName)
        var listing = Listing(
            id: existing?.id ?? "own-\(title.hashValue)-\(priceValue)",
            title: title,
            location: locationLabel,
            price: formattedPrice,
            rating: existing?.rating ?? "Nouveau",
            imageName: cover.isEmpty ? (existing?.imageName ?? "ListingGreen") : cover,
            ownerName: existing?.ownerName ?? displayName,
            ownerVerified: existing?.ownerVerified ?? (me?.verified ?? false),
            customImageData: coverData,
            category: category,
            subtitle: subParts.joined(separator: " · "),
            about: about.trimmingCharacters(in: .whitespacesAndNewlines),
            verified: existing?.verified ?? true,
            boosted: existing?.boosted ?? false,
            tags: tags,
            reviewCount: existing?.reviewCount ?? 0,
            deals: deals,
            features: feats,
            lat: pinLat,
            lng: pinLng
        )
        // Photos are stored in cover-first order thanks to drag-to-reorder.
        listing.customPhotos = uploadedPhotos

        // Local cache first, always — even if the upload fails the user's
        // photos survive to the detail-page gallery via file:// URLs, and
        // the source Data is still on `customPhotos` for a re-upload later.
        let fileURLs = OwnerPhotoStore.save(uploadedPhotos, id: listing.id)
        listing.photos = fileURLs.map { $0.absoluteString }

        isPublishing = true
        Task {
            // 1) Upload photos to Cloudinary (best-effort — local file:// URLs
            //    still let the owner see the annonce if this fails).
            if !uploadedPhotos.isEmpty {
                do {
                    let uploaded = try await MoblyAPI.shared.uploadOwnerPhotos(uploadedPhotos)
                    let remoteURLs = uploaded.map { $0.url }
                    if !remoteURLs.isEmpty {
                        listing.photos = remoteURLs
                        listing.coverUrl = remoteURLs.first
                    }
                    SessionTracker.shared.log("owner.photos_uploaded", [
                        "count": remoteURLs.count, "listingId": listing.id
                    ])
                } catch {
                    SessionTracker.shared.log("owner.photos_upload_failed", [
                        "listingId": listing.id
                    ])
                }
            }

            // 2) Register the annonce on the server so it has a real id and a
            //    server-side owner — otherwise `POST /threads {listingId}`
            //    would 404 and the "Contacter" button on the detail page
            //    would surface "Impossible d'ouvrir la conversation".
            if let dto = await publishToServer(listing) {
                listing = mergeServer(dto, into: listing)
            }

            await MainActor.run {
                isPublishing = false
                onCommit(listing)
                // If the server publish failed, keep this sheet up so the
                // owner sees the alert and knows their annonce is local-only.
                // Otherwise dismiss straight to the dashboard.
                if publishError == nil { dismiss() }
            }
        }
    }

    /// POST or PATCH `/listings` depending on whether we're publishing a new
    /// annonce or editing an existing one. Returns the server DTO on success,
    /// nil on any failure. Sets `publishError` on the view when the failure
    /// is actionable so the owner sees why their annonce didn't save.
    private func publishToServer(_ l: Listing) async -> ListingDTO? {
        // Not signed in with the backend at all → the annonce cannot be
        // saved online. Surface this rather than silently swallowing.
        guard MoblyAPI.shared.isAuthenticated else {
            await MainActor.run {
                publishError = "Connectez-vous pour publier votre annonce en ligne."
            }
            return nil
        }
        // The user may have become owner locally (Session flag) but the
        // server-side isOwner has not caught up yet. Sync it before POSTing
        // so the request doesn't 403 "OWNER_REQUIRED".
        if AuthStore.shared.user?.isOwner == false {
            _ = await AuthStore.shared.becomeOwnerOnServer()
        }
        let priceFcfa = Int((digits(priceValue))) ?? 0
        guard priceFcfa > 0 else { return nil }
        let deal = l.deals.contains("Acheter") ? "SALE" : "RENT"
        let regionValue = region.trimmingCharacters(in: .whitespaces)
        let neighborhoodValue = neighborhood.trimmingCharacters(in: .whitespaces)
        // The server treats file:// URLs as invalid (they're not reachable
        // from other devices); only send the remote ones.
        let remotePhotos = l.photos.filter { $0.hasPrefix("http") }
        let coverForServer = l.coverUrl?.hasPrefix("http") == true ? l.coverUrl : nil
        let body = MoblyAPI.CreateListingBody(
            title: l.title,
            category: l.category,
            deal: deal,
            region: regionValue.isEmpty ? nil : regionValue,
            city: city,
            neighborhood: neighborhoodValue.isEmpty ? nil : neighborhoodValue,
            priceFcfa: priceFcfa,
            furnished: !l.deals.contains("Non meublé"),
            rooms: max(0, rooms),
            about: l.about.isEmpty ? nil : l.about,
            tags: l.tags,
            coverUrl: coverForServer,
            imageName: nil,
            photos: remotePhotos,
            lat: l.lat,
            lng: l.lng
        )
        do {
            let dto: ListingDTO
            if let existing = editing {
                // PATCH — the server row already exists; keep the same id and
                // just push the changed fields. Also refreshes the public
                // ListingStore so Home / Explore / Search show the new deals
                // (e.g. Meublé → Non meublé) without waiting for a relaunch.
                dto = try await MoblyAPI.shared.updateListing(id: existing.listing.id, body: body)
            } else {
                dto = try await MoblyAPI.shared.createListing(body)
            }
            await ListingStore.shared.refresh()
            return dto
        } catch {
            SessionTracker.shared.log("owner.publish_failed", ["listingId": l.id])
            let msg: String
            if let e = error as? MoblyAPI.APIError {
                msg = e.isOffline
                    ? "Pas de connexion. Les modifications seront envoyées à la prochaine connexion."
                    : (editing != nil
                       ? "Modification en ligne impossible: \(e.message)"
                       : "Publication en ligne impossible: \(e.message)")
            } else {
                msg = editing != nil
                    ? "Modification en ligne impossible. Réessayez."
                    : "Publication en ligne impossible. Réessayez."
            }
            await MainActor.run { publishError = msg }
            return nil
        }
    }

    /// Overlay the server's authoritative fields onto the locally-built
    /// listing — id, owner identity, price string — while keeping the local
    /// photo data (photos not yet uploaded still render from `customPhotos`).
    private func mergeServer(_ dto: ListingDTO, into local: Listing) -> Listing {
        var merged = local
        // Server id replaces the local "own-…" placeholder so downstream
        // features (chat threads, favourites, visits) reference the real row.
        merged = Listing(
            id: dto.id,
            title: dto.title,
            location: dto.location,
            price: dto.price,
            rating: local.rating,
            imageName: local.imageName,
            coverUrl: dto.coverUrl ?? local.coverUrl,
            photos: (dto.photos?.isEmpty == false ? dto.photos! : local.photos),
            ownerName: dto.owner?.fullName ?? local.ownerName,
            ownerVerified: dto.owner?.verified ?? local.ownerVerified,
            customImageData: local.customImageData,
            customPhotos: local.customPhotos,
            category: dto.category,
            subtitle: local.subtitle,
            about: dto.about.isEmpty ? local.about : dto.about,
            verified: dto.verified,
            boosted: dto.boosted,
            tags: local.tags,
            reviewCount: dto.reviewCount,
            deals: local.deals,
            features: local.features,
            lat: dto.lat ?? local.lat,
            lng: dto.lng ?? local.lng
        )
        return merged
    }

    private var locationLabel: String {
        neighborhood.trimmingCharacters(in: .whitespaces).isEmpty ? city : "\(neighborhood), \(city)"
    }
    private func digits(_ s: String) -> String { s.filter(\.isNumber) }
    private var formattedPrice: String {
        let n = Int(digits(priceValue)) ?? 0
        let f = NumberFormatter(); f.groupingSeparator = " "; f.numberStyle = .decimal
        return "\(f.string(from: NSNumber(value: n)) ?? "\(n)") FCFA"
    }
}

// MARK: - Photo drop delegate
//
// Reads the source thumbnail's index from the drag payload and calls back
// to move it into `targetIndex`. Kept out of `AddListingView` so the view
// itself doesn't need to conform to `DropDelegate` — it isn't the drop
// target, its thumbnails are.
private struct PhotoDropDelegate: DropDelegate {
    let targetIndex: Int
    @Binding var draggingIndex: Int?
    let perform: (_ from: Int, _ to: Int) -> Void

    func dropEntered(info: DropInfo) {}

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first else {
            draggingIndex = nil
            return false
        }
        provider.loadObject(ofClass: NSString.self) { item, _ in
            guard let str = item as? String, let from = Int(str) else { return }
            DispatchQueue.main.async {
                perform(from, targetIndex)
                draggingIndex = nil
            }
        }
        return true
    }

    func dropExited(info: DropInfo) {}
}
