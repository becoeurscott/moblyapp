import SwiftUI

/// Focused search-entry screen: dimmed/blurred backdrop, auto-keyboard, and
/// live location autocomplete. Selecting a location opens the results page.
struct ExploreSearchView: View {
    var onClose: () -> Void = {}
    var onSelectLocation: (String) -> Void = { _ in }

    @State private var query = ""
    @FocusState private var focused: Bool
    @State private var recents: [String] = ["Akwa, Douala", "Bastos, Yaoundé"]

    private var suggestions: [(name: String, region: String)] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return MoblyData.searchableLocations.filter {
            $0.name.lowercased().contains(q) || $0.region.lowercased().contains(q)
        }
    }

    var body: some View {
        ZStack {
            // Blurred backdrop
            Color.black.opacity(0.15).ignoresSafeArea()
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()

            VStack(spacing: 0) {
                searchBar
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 12)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        if query.isEmpty {
                            recentsSection
                        } else if suggestions.isEmpty {
                            emptyRow
                        } else {
                            ForEach(suggestions, id: \.name) { s in
                                suggestionRow(name: s.name, region: s.region, highlight: query)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .background(Color.white)
            }
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focused = true } }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                TextField("Où cherchez-vous ? (quartier, ville…)", text: $query)
                    .font(.moblyBody(14))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .focused($focused)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { submit() }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Color(hex: 0xC4C7D2))
                    }
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 14).fill(.white))
            .shadow(color: .black.opacity(0.06), radius: 8, y: 3)

            Button(action: onClose) {
                Text("Annuler")
                    .font(.moblyBody(14, weight: .semibold))
                    .foregroundStyle(Color.moblyPrimary)
            }
        }
    }

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recherches récentes")
                    .font(.moblyBody(12.5, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                Spacer()
                if !recents.isEmpty {
                    Button("Effacer") { recents = [] }
                        .font(.moblyBody(12, weight: .semibold))
                        .foregroundStyle(Color.moblyPrimary)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 6)

            ForEach(recents, id: \.self) { r in
                Button { onSelectLocation(r) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color(hex: 0x9A9DAC))
                            .frame(width: 22)
                        Text(r)
                            .font(.moblyBody(14))
                            .foregroundStyle(Color.moblyTextPrimary)
                        Spacer()
                        Image(systemName: "arrow.up.left")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color(hex: 0xC4C7D2))
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 13)
                }
                .buttonStyle(.plain)
            }

            Text("Quartiers populaires")
                .font(.moblyBody(12.5, weight: .semibold))
                .foregroundStyle(Color(hex: 0x9A9DAC))
                .padding(.horizontal, 22)
                .padding(.top, 12)
                .padding(.bottom, 6)
            ForEach(Array(MoblyData.searchableLocations.prefix(6)), id: \.name) { s in
                suggestionRow(name: s.name, region: s.region, highlight: "")
            }
        }
    }

    private func suggestionRow(name: String, region: String, highlight: String) -> some View {
        Button { onSelectLocation("\(name), \(region)") } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.moblySurfaceTint).frame(width: 36, height: 36)
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.moblyPrimary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.moblyHeading(14))
                        .foregroundStyle(Color.moblyTextPrimary)
                    Text(region)
                        .font(.moblyBody(12))
                        .foregroundStyle(Color(hex: 0x9A9DAC))
                }
                Spacer()
                Image(systemName: "arrow.up.left")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(hex: 0xC4C7D2))
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 11)
        }
        .buttonStyle(.plain)
    }

    private var emptyRow: some View {
        VStack(spacing: 8) {
            Image(systemName: "mappin.slash")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Color(hex: 0xD5D8E2))
            Text("Aucun lieu trouvé")
                .font(.moblyBody(14, weight: .medium))
                .foregroundStyle(Color(hex: 0x9A9DAC))
            Text("Essayez un autre quartier ou une ville.")
                .font(.moblyBody(12.5))
                .foregroundStyle(Color(hex: 0xC4C7D2))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
    }

    private func submit() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        onSelectLocation(q)
    }
}

#Preview {
    ExploreSearchView()
}
