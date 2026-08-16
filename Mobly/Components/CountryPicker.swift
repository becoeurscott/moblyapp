import SwiftUI

/// Phone field with a country selector.
///
/// The selected country's dial code is never part of the text the user edits —
/// they type only the local number, and the caller composes E.164 from
/// `country.dial + digits`. Mixing the two in one field is how "+237+237677…"
/// happens.
struct PhoneNumberField: View {
    var label: String = "Numéro de téléphone"
    @Binding var country: Country
    @Binding var number: String
    var errorMessage: String?

    @State private var showPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !label.isEmpty {
                Text(label)
                    .font(.moblyBody(12.5, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x6B6F80))
            }

            HStack(spacing: 10) {
                // Country selection is locked to Cameroon for the pilot —
                // the picker chip is intentionally non-tappable. When we add
                // international onboarding, restore the `Button { showPicker
                // = true }` wrapper and the picker sheet at the bottom of
                // this view.
                HStack(spacing: 6) {
                    Text(country.flag).font(.system(size: 19))
                    Text(country.dialCode)
                        .font(.moblyBody(15, weight: .semibold))
                        .foregroundStyle(Color.moblyTextPrimary)
                }
                .accessibilityLabel("Indicatif pays, \(country.name)")

                Rectangle().fill(Color(hex: 0xE2E4EC)).frame(width: 1, height: 18)

                TextField("6 77 12 34 56", text: $number)
                    .font(.moblyBody(14, weight: .medium))
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .onChange(of: number) { _, newValue in
                        // Keep digits only. Country is locked to Cameroon
                        // for the pilot, so a pasted "+237 6…" simply loses
                        // its country prefix — the fixed `+237` chip on the
                        // left already carries it.
                        var digits = newValue.filter(\.isNumber)
                        if digits.hasPrefix(country.dial) {
                            digits = String(digits.dropFirst(country.dial.count))
                        }
                        if digits != newValue { number = digits }
                    }
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0xF4F5F8)))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(errorMessage == nil ? .clear : Color.moblyAccent, lineWidth: 1)
            )

            if let errorMessage {
                Text(errorMessage)
                    .font(.moblyBody(11, weight: .medium))
                    .foregroundStyle(Color.moblyAccent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Picker sheet is intentionally not attached — country is locked to
        // Cameroon for the pilot. `showPicker` and `CountryPickerSheet` are
        // kept in the file so the international flow can be re-enabled in one
        // change.
    }
}

/// Searchable country list.
struct CountryPickerSheet: View {
    @Binding var selected: Country
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    /// Sorted by localised name so the order matches what the user reads.
    private var sorted: [Country] {
        Country.all.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var results: [Country] {
        query.isEmpty ? sorted : sorted.filter { $0.matches(query) }
    }

    /// Home market + diaspora, pinned above the full list when not searching.
    private var suggested: [Country] {
        Country.suggestedISO.compactMap { iso in Country.all.first { $0.iso == iso } }
    }

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    Section("Fréquents") {
                        ForEach(suggested) { row($0) }
                    }
                }
                Section(query.isEmpty ? "Tous les pays" : "Résultats") {
                    ForEach(results) { row($0) }
                }
                if results.isEmpty {
                    Text("Aucun pays trouvé")
                        .font(.moblyBody(13))
                        .foregroundStyle(Color(hex: 0x9A9DAC))
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "Rechercher un pays")
            .navigationTitle("Pays")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                        .foregroundStyle(Color.moblyPrimary)
                }
            }
        }
    }

    private func row(_ c: Country) -> some View {
        Button {
            selected = c
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Text(c.flag).font(.system(size: 22))
                Text(c.name)
                    .font(.moblyBody(14.5))
                    .foregroundStyle(Color.moblyTextPrimary)
                Spacer()
                Text(c.dialCode)
                    .font(.moblyBody(13.5, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                if c.iso == selected.iso {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.moblyPrimary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
