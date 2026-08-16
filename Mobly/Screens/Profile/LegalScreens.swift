import SwiftUI

// MARK: - Shared card

private func legalCard<C: View>(@ViewBuilder _ c: () -> C) -> some View {
    c().frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18).fill(.white))
        .shadow(color: Color(hex: 0x14152A).opacity(0.05), radius: 8, y: 2)
}

// MARK: - Hub — "Documents légaux"

struct LegalHubView: View {
    var body: some View {
        ProfileScaffold(title: "Documents légaux") {
            VStack(alignment: .leading, spacing: 18) {
                header

                ForEach(LegalLibrary.groups) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(group.title.uppercased())
                            .font(.moblyBody(11))
                            .tracking(0.8)
                            .foregroundStyle(Color(hex: 0x9A9DAC))
                            .padding(.leading, 4)

                        legalCard {
                            VStack(spacing: 0) {
                                ForEach(Array(group.docs.enumerated()), id: \.element.id) { idx, doc in
                                    if idx > 0 {
                                        Divider().padding(.leading, 56)
                                    }
                                    NavigationLink {
                                        LegalDocumentView(doc: doc)
                                    } label: {
                                        docRow(doc)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }

                Text("Version \(LegalLibrary.version) · Mise à jour le \(LegalLibrary.updated)\n© 2026 \(LegalCompany.name) · Douala, Cameroun")
                    .font(.moblyBody(11))
                    .foregroundStyle(Color(hex: 0xC4C7D2))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
        }
    }

    private var header: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 20)
                .fill(LinearGradient(colors: [Color.moblyPrimary, Color(hex: 0x5A6BFF)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(.white.opacity(0.18)).frame(width: 46, height: 46)
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Vos droits et les nôtres")
                        .font(.moblyHeading(16))
                        .foregroundStyle(.white)
                    Text("Tout ce qui encadre l'usage de Mobly, en clair.")
                        .font(.moblyBody(12))
                        .foregroundStyle(.white.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(18)
        }
    }

    private func docRow(_ doc: LegalDoc) -> some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 11).fill(Color(hex: doc.tint)).frame(width: 40, height: 40)
                Image(systemName: doc.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.moblyPrimary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(doc.short)
                    .font(.moblyHeading(13.5))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .multilineTextAlignment(.leading)
                Text(doc.summary)
                    .font(.moblyBody(11.5))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(hex: 0xC4C7D2))
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

// MARK: - Document reader

struct LegalDocumentView: View {
    let doc: LegalDoc
    @State private var appeared = false

    var body: some View {
        ProfileScaffold(title: doc.nav) {
            VStack(alignment: .leading, spacing: 16) {
                titleBlock
                introBlock

                ForEach(doc.sections) { section in
                    legalCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(section.heading)
                                .font(.moblyHeading(14.5))
                                .foregroundStyle(Color.moblyTextPrimary)
                                .fixedSize(horizontal: false, vertical: true)

                            ForEach(Array(section.body.enumerated()), id: \.offset) { _, p in
                                Text(p)
                                    .font(.moblyBody(13))
                                    .foregroundStyle(Color(hex: 0x4A4C60))
                                    .lineSpacing(4)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            if !section.bullets.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(Array(section.bullets.enumerated()), id: \.offset) { _, b in
                                        HStack(alignment: .top, spacing: 9) {
                                            Circle()
                                                .fill(Color.moblyPrimary.opacity(0.5))
                                                .frame(width: 5, height: 5)
                                                .padding(.top, 6)
                                            Text(LT(b))
                                                .font(.moblyBody(13))
                                                .foregroundStyle(Color(hex: 0x4A4C60))
                                                .lineSpacing(4)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                }
                                .padding(.top, 2)
                            }
                        }
                    }
                }

                contactBlock
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 8)
            .animation(.easeOut(duration: 0.35), value: appeared)
            .onAppear { appeared = true }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(doc.title)
                .font(.moblyHeading(20))
                .foregroundStyle(Color.moblyTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text("Version \(doc.version)")
                Text("·")
                Text("Mis à jour le \(doc.updated)")
            }
            .font(.moblyBody(11.5))
            .foregroundStyle(Color(hex: 0x9A9DAC))
        }
        .padding(.top, 2)
    }

    private var introBlock: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: doc.icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.moblyPrimary)
                .padding(.top, 1)
            Text(doc.intro)
                .font(.moblyBody(13))
                .foregroundStyle(Color(hex: 0x3C3E52))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.moblySurfaceTint))
    }

    private var contactBlock: some View {
        legalCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("Une question sur ce document ?")
                    .font(.moblyHeading(13.5))
                    .foregroundStyle(Color.moblyTextPrimary)
                Text("Écrivez-nous à \(LegalCompany.email) — nous répondons sous 30 jours au plus tard.")
                    .font(.moblyBody(12))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview("Hub") {
    NavigationStack { LegalHubView() }
}

#Preview("Document") {
    NavigationStack { LegalDocumentView(doc: LegalLibrary.cgu) }
}
