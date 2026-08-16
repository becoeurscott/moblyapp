import SwiftUI
import PhotosUI

/// Single-page editor for an existing annonce.
///
/// Shows every field of the annonce inline with a pen icon next to each; tap
/// the pen to open a focused editor sheet for that field. The "Enregistrer
/// les modifications" button at the bottom is disabled until any field is
/// dirty; on save a loading overlay covers the screen until the server
/// confirms, then a green success confirmation slides in before the sheet
/// dismisses. Non-destructive: if the user cancels with unsaved changes,
/// they get a prompt before the sheet dismisses.
struct ManageListingView: View {
    let original: OwnerAnnonce
    var onClose: () -> Void = {}

    @ObservedObject private var store = OwnerListings.shared
    @Environment(\.dismiss) private var dismiss

    // Editable working copy — all field-level edits mutate this, then
    // `hasChanges` compares against `original` to decide whether the save
    // button lights up.
    @State private var draft: Listing

    // Which field is currently being edited (nil = overview).
    @State private var editingField: FieldKind?
    @State private var saving = false
    @State private var showSaveSuccess = false
    @State private var saveError: String?
    @State private var confirmDiscard = false

    init(annonce: OwnerAnnonce, onClose: @escaping () -> Void = {}) {
        self.original = annonce
        self.onClose = onClose
        _draft = State(initialValue: annonce.listing)
    }

    private var hasChanges: Bool { draft != original.listing }

    enum FieldKind: String, Identifiable {
        case title, description, price, furnished, category, tags, location
        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            Color(hex: 0xF7F8FA).ignoresSafeArea()

            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 14) {
                        heroCover
                        sectionCard(icon: "text.alignleft", label: "Titre",
                                    value: draft.title, field: .title)
                        sectionCard(icon: "doc.plaintext", label: "Description",
                                    value: draft.about.isEmpty ? "Aucune description" : draft.about,
                                    field: .description, multiline: true)
                        sectionCard(icon: "tag.fill", label: "Prix",
                                    value: "\(draft.price)\(draft.priceUnit.isEmpty ? "" : " " + draft.priceUnit)",
                                    field: .price)
                        sectionCard(icon: "sofa.fill", label: "Meublement",
                                    value: draft.deals.contains("Non meublé") ? "Non meublé" : "Meublé",
                                    field: .furnished,
                                    tint: draft.deals.contains("Non meublé")
                                          ? Color(hex: 0xE5484D) : Color(hex: 0x1F8A5B))
                        sectionCard(icon: "house.fill", label: "Catégorie",
                                    value: draft.category, field: .category)
                        sectionCard(icon: "mappin.and.ellipse", label: "Localisation",
                                    value: draft.location, field: .location)
                        tagsCard
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 6)
                    .padding(.bottom, 130)
                }
            }

            saveBar
                .frame(maxHeight: .infinity, alignment: .bottom)

            if saving { loadingOverlay }
            if showSaveSuccess { successOverlay }
        }
        .sheet(item: $editingField) { field in
            editor(for: field)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .alert("Modifications non enregistrées",
               isPresented: $confirmDiscard) {
            Button("Ignorer", role: .destructive) { onClose(); dismiss() }
            Button("Continuer l'édition", role: .cancel) {}
        } message: {
            Text("Vos modifications seront perdues si vous quittez maintenant.")
        }
        .alert("Erreur",
               isPresented: Binding(get: { saveError != nil },
                                    set: { if !$0 { saveError = nil } }),
               presenting: saveError) { _ in
            Button("OK", role: .cancel) {}
        } message: { msg in Text(LT(msg)) }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Button {
                if hasChanges { confirmDiscard = true } else { onClose(); dismiss() }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .frame(width: 42, height: 42)
                    .background(RoundedRectangle(cornerRadius: 14).fill(.white))
                    .shadow(color: Color(hex: 0x14152A).opacity(0.05), radius: 6, y: 2)
            }
            Spacer()
            VStack(spacing: 1) {
                Text("Modifier l'annonce")
                    .font(.moblyHeading(16))
                    .foregroundStyle(Color.moblyTextPrimary)
                Text(hasChanges ? "Modifications non enregistrées" : "À jour")
                    .font(.moblyBody(11))
                    .foregroundStyle(hasChanges ? Color(hex: 0xC24E10) : Color(hex: 0x9A9DAC))
            }
            Spacer()
            Color.clear.frame(width: 42, height: 42)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    // MARK: Cover

    private var heroCover: some View {
        ZStack(alignment: .bottomTrailing) {
            ListingCover(listing: draft)
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            // Placeholder for a photo editor — the wizard already handles
            // photo pick / reorder end-to-end, so this row simply routes
            // users to the full flow when they want to edit media.
            Text("Modifier depuis le publier")
                .font(.moblyBody(10.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(.black.opacity(0.55)))
                .padding(10)
        }
    }

    // MARK: Section rows

    private func sectionCard(icon: String, label: String, value: String,
                             field: FieldKind, multiline: Bool = false,
                             tint: Color = .moblyPrimary) -> some View {
        Button { editingField = field } label: {
            HStack(alignment: .top, spacing: 13) {
                ZStack {
                    Circle().fill(tint.opacity(0.15)).frame(width: 40, height: 40)
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(label.uppercased())
                        .font(.moblyBody(10.5, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(Color(hex: 0x9A9DAC))
                    Text(value.isEmpty ? "—" : value)
                        .font(.moblyBody(14, weight: .medium))
                        .foregroundStyle(Color.moblyTextPrimary)
                        .lineLimit(multiline ? 3 : 1)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                penIcon
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white))
        }
        .buttonStyle(.plain)
    }

    private var penIcon: some View {
        Image(systemName: "pencil")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.moblyPrimary)
            .frame(width: 30, height: 30)
            .background(Circle().fill(Color(hex: 0xEEF0FE)))
    }

    private var tagsCard: some View {
        Button { editingField = .tags } label: {
            HStack(alignment: .top, spacing: 13) {
                ZStack {
                    Circle().fill(Color(hex: 0xFFF3EC)).frame(width: 40, height: 40)
                    Image(systemName: "sparkles")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(hex: 0xFF6B35))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("ÉQUIPEMENTS")
                        .font(.moblyBody(10.5, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(Color(hex: 0x9A9DAC))
                    if draft.tags.isEmpty {
                        Text("Aucun équipement sélectionné")
                            .font(.moblyBody(13.5))
                            .foregroundStyle(Color(hex: 0x9A9DAC))
                    } else {
                        ManageChips(items: draft.tags.sorted())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                penIcon
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white))
        }
        .buttonStyle(.plain)
    }

    // MARK: Save bar + overlays

    private var saveBar: some View {
        VStack(spacing: 8) {
            Button {
                Task { await save() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                    Text("Enregistrer les modifications")
                        .font(.moblyHeading(15))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 54)
                .background(hasChanges
                            ? AnyShapeStyle(LinearGradient(colors: [Color.moblyPrimary, Color(hex: 0x2A3ADB)],
                                                            startPoint: .leading, endPoint: .trailing))
                            : AnyShapeStyle(Color(hex: 0xC4C7D2)))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!hasChanges || saving)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 30)
    }

    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(Color.moblyPrimary)
                    .scaleEffect(1.4)
                Text("Enregistrement…")
                    .font(.moblyHeading(14))
                    .foregroundStyle(Color.moblyTextPrimary)
            }
            .padding(30)
            .background(RoundedRectangle(cornerRadius: 18).fill(.white))
        }
        .transition(.opacity)
    }

    private var successOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color(hex: 0x1F8A5B)).frame(width: 62, height: 62)
                    Image(systemName: "checkmark")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                }
                Text("Modifications enregistrées")
                    .font(.moblyHeading(15))
                    .foregroundStyle(Color.moblyTextPrimary)
            }
            .padding(30)
            .background(RoundedRectangle(cornerRadius: 18).fill(.white))
        }
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: Save

    private func save() async {
        guard hasChanges else { return }
        saving = true
        let ok = await store.updateOnServer(draft)
        await MainActor.run {
            saving = false
            if ok {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { showSaveSuccess = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    showSaveSuccess = false
                    onClose()
                    dismiss()
                }
            } else {
                saveError = "La sauvegarde a échoué. Vérifiez votre connexion et réessayez."
            }
        }
    }

    // MARK: Field editors

    @ViewBuilder
    private func editor(for field: FieldKind) -> some View {
        switch field {
        case .title:       TextFieldEditor(title: "Titre", text: $draft.title,
                                           done: { editingField = nil })
        case .description: MultilineEditor(title: "Description", text: $draft.about,
                                           done: { editingField = nil })
        case .price:       PriceEditor(listing: $draft, done: { editingField = nil })
        case .furnished:   FurnishedEditor(listing: $draft, done: { editingField = nil })
        case .category:    CategoryEditor(listing: $draft, done: { editingField = nil })
        case .location:    LocationTextEditor(listing: $draft, done: { editingField = nil })
        case .tags:        TagsEditor(listing: $draft, done: { editingField = nil })
        }
    }
}

// MARK: - Field editor sheets

private struct TextFieldEditor: View {
    let title: String
    @Binding var text: String
    var done: () -> Void
    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                TextField(title, text: $text)
                    .font(.moblyBody(16))
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0xF4F5F8)))
                Spacer()
            }
            .padding(20)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("OK") { done() } } }
        }
    }
}

private struct MultilineEditor: View {
    let title: String
    @Binding var text: String
    var done: () -> Void
    var body: some View {
        NavigationStack {
            VStack {
                TextEditor(text: $text)
                    .font(.moblyBody(15))
                    .padding(10)
                    .frame(minHeight: 220)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0xF4F5F8)))
                Spacer()
            }
            .padding(20)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("OK") { done() } } }
        }
    }
}

private struct PriceEditor: View {
    @Binding var listing: Listing
    var done: () -> Void
    @State private var digits: String = ""
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("Prix en FCFA").font(.moblyBody(12.5)).foregroundStyle(Color(hex: 0x9A9DAC))
                TextField("0", text: $digits)
                    .keyboardType(.numberPad)
                    .font(.moblyHeading(22))
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0xF4F5F8)))
                Spacer()
            }
            .padding(20)
            .navigationTitle("Prix")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("OK") {
                        let n = Int(digits.filter(\.isNumber)) ?? 0
                        listing.price = format(n)
                        done()
                    }
                }
            }
            .onAppear { digits = listing.price.filter(\.isNumber) }
        }
    }
    private func format(_ n: Int) -> String {
        let s = String(n); var out = ""
        for (i, c) in s.reversed().enumerated() {
            if i > 0 && i % 3 == 0 { out.append(" ") }
            out.append(c)
        }
        return String(out.reversed()) + " FCFA"
    }
}

private struct FurnishedEditor: View {
    @Binding var listing: Listing
    var done: () -> Void
    private var isFurnished: Bool { !listing.deals.contains("Non meublé") }
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                choice(title: "Meublé", subtitle: "Prêt à vivre, équipé",
                       icon: "sofa.fill", selected: isFurnished) { set(true) }
                choice(title: "Non meublé", subtitle: "Vide, à équiper",
                       icon: "cube.box", selected: !isFurnished) { set(false) }
                Spacer()
            }
            .padding(20)
            .navigationTitle("Meublement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("OK") { done() } } }
        }
    }
    private func set(_ furnished: Bool) {
        var d = listing.deals.filter { $0 != "Meublé" && $0 != "Non meublé" }
        d.append(furnished ? "Meublé" : "Non meublé")
        listing.deals = d
    }
    @ViewBuilder
    private func choice(title: String, subtitle: String, icon: String,
                        selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(selected ? Color.moblyPrimary : Color(hex: 0xEEF0FE))
                    Image(systemName: icon).font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(selected ? .white : Color.moblyPrimary)
                }.frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LT(title)).font(.moblyHeading(16))
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
}

private struct CategoryEditor: View {
    @Binding var listing: Listing
    var done: () -> Void
    private let options = ["Chambres","Studios","Appartements","Villas","Bureaux","Boutiques","Coworking","Commercial"]
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(options, id: \.self) { opt in
                        let selected = listing.category == opt
                        Button {
                            listing.category = opt
                        } label: {
                            HStack {
                                Text(opt).font(.moblyBody(15, weight: .semibold))
                                    .foregroundStyle(Color.moblyTextPrimary)
                                Spacer()
                                if selected {
                                    Image(systemName: "checkmark").foregroundStyle(Color.moblyPrimary)
                                }
                            }
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 12).fill(.white))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.moblyPrimary : Color(hex: 0xE2E4EC), lineWidth: selected ? 2 : 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Catégorie")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("OK") { done() } } }
        }
    }
}

private struct LocationTextEditor: View {
    @Binding var listing: Listing
    var done: () -> Void
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("Localisation (ex: Bonapriso, Douala)")
                    .font(.moblyBody(12.5))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                TextField("Ville, quartier", text: $listing.location)
                    .font(.moblyBody(15))
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0xF4F5F8)))
                Spacer()
            }
            .padding(20)
            .navigationTitle("Localisation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("OK") { done() } } }
        }
    }
}

private struct TagsEditor: View {
    @Binding var listing: Listing
    var done: () -> Void
    private let all = ["Wifi","Climatisation","Parking","Sécurité 24/7","Eau chaude",
                       "Eau courante","Électricité","Cuisine équipée","Réfrigérateur",
                       "Télévision","Groupe électrogène","Balcon","Terrasse","Ménage inclus"]
    var body: some View {
        NavigationStack {
            ScrollView {
                ManageChips(items: all, selected: Set(listing.tags)) { tag in
                    var s = Set(listing.tags)
                    if s.contains(tag) { s.remove(tag) } else { s.insert(tag) }
                    listing.tags = Array(s).sorted()
                }
                .padding(20)
            }
            .navigationTitle("Équipements")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("OK") { done() } } }
        }
    }
}

// MARK: - Flow chip layout

private struct ManageChips: View {
    let items: [String]
    var selected: Set<String> = []
    var onTap: ((String) -> Void)? = nil

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(items, id: \.self) { it in
                let isSel = selected.contains(it) || onTap == nil
                Text(it)
                    .font(.moblyBody(12, weight: .semibold))
                    .foregroundStyle(isSel && onTap != nil ? .white
                                     : (onTap == nil ? Color.moblyPrimary : Color.moblyTextPrimary))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Capsule().fill(
                        onTap == nil ? Color(hex: 0xEEF0FE)
                        : (isSel ? Color.moblyPrimary : Color(hex: 0xF4F5F8))
                    ))
                    .onTapGesture { onTap?(it) }
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        return CGSize(width: maxW == .infinity ? x : maxW, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
