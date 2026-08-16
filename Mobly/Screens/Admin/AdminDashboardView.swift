import SwiftUI

/// Root of the admin surface. Guarded by `auth.user?.isAdmin == true` from
/// the caller (ProfileView) — the view itself trusts it's being presented in
/// an authorized context.
///
/// Layout: a compact sidebar of section chips at the top; the active section
/// fills the rest of the screen. Each section runs its own `.task` so the
/// dashboard opens instantly and each screen pulls what it needs.
struct AdminDashboardView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var section: Section = .overview

    enum Section: String, CaseIterable, Identifiable {
        case overview   = "Vue d'ensemble"
        case users      = "Utilisateurs"
        case listings   = "Annonces"
        case reports    = "Signalements"
        case analytics  = "Analytiques"
        case threads    = "Conversations"
        case visits     = "Visites"

        var icon: String {
            switch self {
            case .overview:  return "chart.bar.doc.horizontal"
            case .users:     return "person.2.fill"
            case .listings:  return "building.2.fill"
            case .reports:   return "flag.fill"
            case .analytics: return "chart.line.uptrend.xyaxis"
            case .threads:   return "bubble.left.and.bubble.right.fill"
            case .visits:    return "calendar.badge.clock"
            }
        }
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            sectionTabs
            Divider().opacity(0.4)
            content
        }
        .background(Color(hex: 0xF7F8FA).ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(.white))
                    .shadow(color: Color(hex: 0x14152A).opacity(0.06), radius: 6, y: 2)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Espace admin")
                    .font(.moblyHeading(20))
                    .foregroundStyle(Color.moblyTextPrimary)
                Text("Gérer utilisateurs, annonces et signalements")
                    .font(.moblyBody(11.5))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.moblyAccent)
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
    }

    // MARK: - Section tabs

    private var sectionTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Section.allCases) { s in
                    Button {
                        UISelectionFeedbackGenerator().selectionChanged()
                        withAnimation(.easeInOut(duration: 0.22)) { section = s }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: s.icon).font(.system(size: 11, weight: .bold))
                            Text(s.rawValue).font(.moblyHeading(12.5))
                        }
                        .foregroundStyle(section == s ? .white : Color.moblyTextPrimary)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(
                            Capsule().fill(section == s ? Color.moblyPrimary : .white)
                        )
                        .overlay(
                            Capsule().stroke(section == s ? .clear : Color(hex: 0xE2E4EC),
                                             lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 8)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch section {
        case .overview:  AdminOverviewSection()
        case .users:     AdminUsersSection()
        case .listings:  AdminListingsSection()
        case .reports:   AdminReportsSection()
        case .analytics: AdminAnalyticsSection()
        case .threads:   AdminThreadsSection()
        case .visits:    AdminVisitsSection()
        }
    }
}

// MARK: - Overview

private struct AdminOverviewSection: View {
    @State private var overview: AdminAPI.Overview?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                if let ov = overview {
                    LazyVGrid(columns: [.init(.flexible(), spacing: 10),
                                         .init(.flexible(), spacing: 10)], spacing: 10) {
                        statTile("Utilisateurs", "\(ov.users)", "person.2.fill",
                                 delta: "+\(ov.newUsers30d) sur 30 j", tint: 0x3A4FF0)
                        statTile("Propriétaires", "\(ov.owners)", "building.2.fill", tint: 0x1F8A5B)
                        statTile("Annonces", "\(ov.listings)", "map.fill",
                                 delta: "+\(ov.newListings30d) sur 30 j", tint: 0xFF6B35)
                        statTile("Boostées", "\(ov.boostedListings)", "bolt.fill", tint: 0xC24E10)
                        statTile("Sessions 24 h", "\(ov.activeSessions24h)", "wave.3.right", tint: 0x8B5CF6)
                        statTile("Messages 24 h", "\(ov.messagesLast24h)", "bubble.left.fill", tint: 0x2E7BE4)
                        statTile("Visites en attente", "\(ov.pendingVisits)", "calendar.badge.clock", tint: 0xFF6B35)
                        statTile("Signalements", "\(ov.openReports)", "flag.fill", tint: 0xE5484D)
                    }
                    .padding(.horizontal, 16)
                } else if isLoading {
                    ProgressView().padding(.top, 60)
                } else if let e = errorMessage {
                    Text(LT(e)).font(.moblyBody(13))
                        .foregroundStyle(Color(hex: 0xE5484D))
                        .padding(.top, 60)
                }
            }
            .padding(.vertical, 14)
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do { overview = try await AdminAPI.shared.overview() }
        catch { errorMessage = (error as? MoblyAPI.APIError)?.message ?? "Erreur" }
    }

    private func statTile(_ label: String, _ value: String, _ icon: String,
                          delta: String? = nil, tint: UInt32) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color(hex: tint).opacity(0.12))
                    Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(hex: tint))
                }
                .frame(width: 32, height: 32)
                Spacer()
            }
            Text(LT(value))
                .font(.moblyHeading(24))
                .foregroundStyle(Color.moblyTextPrimary)
            Text(LT(label))
                .font(.moblyBody(11.5))
                .foregroundStyle(Color(hex: 0x9A9DAC))
            if let delta {
                Text(delta)
                    .font(.moblyBody(10.5, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x1F8A5B))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white))
        .shadow(color: Color(hex: 0x14152A).opacity(0.04), radius: 6, y: 2)
    }
}

// MARK: - Users

private struct AdminUsersSection: View {
    @State private var page = AdminAPI.AdminUsersPage(total: 0, page: 0, pageSize: 20, items: [])
    @State private var query = ""
    @State private var role = "all"     // all / owner / visitor / admin
    @State private var active = "all"   // all / active / suspended
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selected: AdminAPI.AdminUserSummary?

    var body: some View {
        VStack(spacing: 10) {
            filterBar
            list
        }
        .task(id: filterKey) { await load() }
        .sheet(item: $selected) { user in
            AdminUserDetailSheet(user: user, onChanged: { updated in
                if let i = page.items.firstIndex(where: { $0.id == updated.id }) {
                    var items = page.items; items[i] = updated
                    page = AdminAPI.AdminUsersPage(total: page.total, page: page.page,
                                                   pageSize: page.pageSize, items: items)
                }
            }, onDeleted: { id in
                page = AdminAPI.AdminUsersPage(
                    total: max(0, page.total - 1), page: page.page,
                    pageSize: page.pageSize,
                    items: page.items.filter { $0.id != id }
                )
            })
        }
    }

    private var filterKey: String { "\(query)|\(role)|\(active)" }

    private var filterBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                TextField("Nom, e-mail, numéro…", text: $query)
                    .font(.moblyBody(14))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color(hex: 0xC4C7D2))
                    }
                }
            }
            .padding(.horizontal, 12).frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 12).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: 0xE2E4EC), lineWidth: 1))

            HStack(spacing: 6) {
                filterChip("Tous", role == "all") { role = "all" }
                filterChip("Propriétaires", role == "owner") { role = "owner" }
                filterChip("Visiteurs", role == "visitor") { role = "visitor" }
                filterChip("Admins", role == "admin") { role = "admin" }
                Spacer()
            }
            HStack(spacing: 6) {
                filterChip("Actifs & suspendus", active == "all") { active = "all" }
                filterChip("Actifs", active == "active") { active = "active" }
                filterChip("Suspendus", active == "suspended") { active = "suspended" }
                Spacer()
            }
        }
        .padding(.horizontal, 16).padding(.top, 6)
    }

    private var list: some View {
        Group {
            if isLoading && page.items.isEmpty {
                ProgressView().padding(.top, 40)
            } else if let e = errorMessage {
                Text(LT(e)).font(.moblyBody(13)).foregroundStyle(Color(hex: 0xE5484D)).padding(.top, 40)
            } else if page.items.isEmpty {
                Text("Aucun résultat").font(.moblyBody(13))
                    .foregroundStyle(Color(hex: 0x9A9DAC)).padding(.top, 40)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 8) {
                        Text("\(page.total) résultat\(page.total > 1 ? "s" : "")")
                            .font(.moblyBody(11, weight: .semibold))
                            .foregroundStyle(Color(hex: 0x9A9DAC))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                        ForEach(page.items) { u in
                            Button { selected = u } label: { AdminUserRow(user: u) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 30)
                }
                .refreshable { await load() }
            }
        }
    }

    private func filterChip(_ title: String, _ selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(LT(title))
                .font(.moblyBody(11.5, weight: .semibold))
                .foregroundStyle(selected ? .white : Color.moblyTextPrimary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(selected ? Color.moblyPrimary : .white))
                .overlay(Capsule().stroke(selected ? .clear : Color(hex: 0xE2E4EC), lineWidth: 1))
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            page = try await AdminAPI.shared.listUsers(
                query: query.isEmpty ? nil : query, role: role, active: active
            )
        } catch { errorMessage = (error as? MoblyAPI.APIError)?.message ?? "Erreur" }
    }
}

private struct AdminUserRow: View {
    let user: AdminAPI.AdminUserSummary
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(
                    LinearGradient(colors: AvatarPalette.gradient(
                        for: user.id, stored: user.avatarColor
                    ), startPoint: .top, endPoint: .bottom)
                )
                Text(String(user.fullName.prefix(1)).uppercased())
                    .font(.moblyHeading(15)).foregroundStyle(.white)
            }
            .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(user.fullName)
                        .font(.moblyHeading(14)).foregroundStyle(Color.moblyTextPrimary)
                        .lineLimit(1)
                    if user.isAdmin {
                        badge("ADMIN", 0xE5484D)
                    } else if user.isOwner {
                        badge("PROPRIO", 0x1F8A5B)
                    }
                    if !user.isActive {
                        badge("SUSPENDU", 0x9A9DAC)
                    }
                }
                Text([user.email, user.phone].compactMap { $0 }.joined(separator: " · "))
                    .font(.moblyBody(11.5))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(hex: 0xC4C7D2))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white))
    }
    private func badge(_ text: String, _ tint: UInt32) -> some View {
        Text(LT(text))
            .font(.moblyBody(9, weight: .bold))
            .foregroundStyle(Color(hex: tint))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Capsule().fill(Color(hex: tint).opacity(0.12)))
    }
}

private struct AdminUserDetailSheet: View {
    let user: AdminAPI.AdminUserSummary
    var onChanged: (AdminAPI.AdminUserSummary) -> Void
    var onDeleted: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var detail: AdminAPI.AdminUserDetail.FullUser?
    @State private var isBusy = false
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    header
                    if let d = detail {
                        statsGrid(d)
                        actions(d)
                    } else {
                        ProgressView().padding(.vertical, 40)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .background(Color(hex: 0xF7F8FA).ignoresSafeArea())
            .navigationTitle("Utilisateur")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") { dismiss() }
                }
            }
            .task { await load() }
            .confirmationDialog("Supprimer définitivement ce compte ?",
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Supprimer", role: .destructive) {
                    Task {
                        try? await AdminAPI.shared.deleteUser(id: user.id)
                        onDeleted(user.id)
                        dismiss()
                    }
                }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("Cette action supprimera aussi ses annonces et messages.")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(
                    LinearGradient(colors: AvatarPalette.gradient(
                        for: user.id, stored: user.avatarColor
                    ), startPoint: .top, endPoint: .bottom)
                )
                Text(String(user.fullName.prefix(1)).uppercased())
                    .font(.moblyHeading(22)).foregroundStyle(.white)
            }
            .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(user.fullName).font(.moblyHeading(17))
                    .foregroundStyle(Color.moblyTextPrimary)
                Text([user.email, user.phone].compactMap { $0 }.joined(separator: " · "))
                    .font(.moblyBody(12)).foregroundStyle(Color(hex: 0x9A9DAC))
                    .lineLimit(1)
                if let city = user.city, !city.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin").font(.system(size: 10))
                        Text(city).font(.moblyBody(11))
                    }.foregroundStyle(Color(hex: 0x9A9DAC))
                }
            }
            Spacer()
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(.white))
    }

    private func statsGrid(_ d: AdminAPI.AdminUserDetail.FullUser) -> some View {
        LazyVGrid(columns: [.init(.flexible(), spacing: 8),
                             .init(.flexible(), spacing: 8),
                             .init(.flexible(), spacing: 8)], spacing: 8) {
            stat("Annonces", "\(d._count.listings)")
            stat("Favoris", "\(d._count.favorites)")
            stat("Avis reçus", "\(d._count.reviewsReceived)")
            stat("Messages", "\(d._count.messages)")
            stat("Visites reçues", "\(d._count.visitsReceived)")
            stat("Visites faites", "\(d._count.visitsRequested)")
            stat("Sessions", "\(d._count.sessions)")
            stat("Événements", "\(d._count.events)")
            stat("Note Mobly", d.moblyScore.map { String(format: "%.1f", $0) } ?? "—")
        }
    }
    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(LT(value)).font(.moblyHeading(17)).foregroundStyle(Color.moblyPrimary)
            Text(LT(label)).font(.moblyBody(10.5))
                .foregroundStyle(Color(hex: 0x9A9DAC))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white))
    }

    private func actions(_ d: AdminAPI.AdminUserDetail.FullUser) -> some View {
        VStack(spacing: 8) {
            actionRow("Compte actif", value: d.isActive) { on in
                Task { await patch(.init(isActive: on)) }
            }
            actionRow("Compte vérifié", value: d.verified) { on in
                Task { await patch(.init(verified: on)) }
            }
            actionRow("Identité vérifiée", value: d.identityVerified) { on in
                Task { await patch(.init(identityVerified: on)) }
            }
            actionRow("Propriétaire", value: d.isOwner) { on in
                Task { await patch(.init(isOwner: on)) }
            }
            actionRow("Administrateur", value: d.isAdmin) { on in
                Task { await patch(.init(isAdmin: on)) }
            }
            Button(role: .destructive) { confirmDelete = true } label: {
                HStack {
                    Image(systemName: "trash")
                    Text("Supprimer le compte")
                    Spacer()
                }
                .font(.moblyHeading(14))
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0xFDEDED)))
                .foregroundStyle(Color(hex: 0xE5484D))
            }
        }
    }

    private func actionRow(_ label: String, value: Bool, onToggle: @escaping (Bool) -> Void) -> some View {
        HStack {
            Text(LT(label)).font(.moblyHeading(14))
            Spacer()
            Toggle("", isOn: Binding(get: { value }, set: onToggle))
                .labelsHidden().disabled(isBusy)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white))
    }

    private func load() async {
        do { detail = try await AdminAPI.shared.user(id: user.id).user }
        catch { }
    }

    private func patch(_ body: AdminAPI.UserPatchBody) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let updated = try await AdminAPI.shared.patchUser(id: user.id, body: body)
            onChanged(updated)
            await load()
        } catch { }
    }
}

// MARK: - Listings

private struct AdminListingsSection: View {
    @State private var page = AdminAPI.AdminListingsPage(total: 0, page: 0, pageSize: 20, items: [])
    @State private var query = ""
    @State private var status = "all"
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 10) {
            filterBar
            content
        }
        .task(id: "\(query)|\(status)") { await load() }
    }

    private var filterBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color(hex: 0x9A9DAC))
                TextField("Titre, quartier, ville…", text: $query)
                    .font(.moblyBody(14))
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Color(hex: 0xC4C7D2))
                    }
                }
            }
            .padding(.horizontal, 12).frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 12).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: 0xE2E4EC), lineWidth: 1))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(["all","PENDING","ACTIVE","BOOSTED","PAUSED","REJECTED","ARCHIVED"], id: \.self) { s in
                        Button {
                            UISelectionFeedbackGenerator().selectionChanged()
                            status = s
                        } label: {
                            Text(s == "all" ? "Toutes" : s.capitalized)
                                .font(.moblyBody(11.5, weight: .semibold))
                                .foregroundStyle(status == s ? .white : Color.moblyTextPrimary)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Capsule().fill(status == s ? Color.moblyPrimary : .white))
                                .overlay(Capsule().stroke(status == s ? .clear : Color(hex: 0xE2E4EC), lineWidth: 1))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 6)
    }

    private var content: some View {
        Group {
            if isLoading && page.items.isEmpty { ProgressView().padding(.top, 40) }
            else if let e = errorMessage {
                Text(LT(e)).font(.moblyBody(13)).foregroundStyle(Color(hex: 0xE5484D)).padding(.top, 40)
            }
            else if page.items.isEmpty {
                Text("Aucune annonce").font(.moblyBody(13)).foregroundStyle(Color(hex: 0x9A9DAC)).padding(.top, 40)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 8) {
                        Text("\(page.total) annonce\(page.total > 1 ? "s" : "")")
                            .font(.moblyBody(11, weight: .semibold))
                            .foregroundStyle(Color(hex: 0x9A9DAC))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                        ForEach(page.items) { l in
                            AdminListingRow(listing: l, onDelete: { delete(l) },
                                             onStatus: { st in setStatus(l, st) })
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 30)
                }
                .refreshable { await load() }
            }
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            page = try await AdminAPI.shared.listListings(
                query: query.isEmpty ? nil : query, status: status
            )
        } catch { errorMessage = (error as? MoblyAPI.APIError)?.message ?? "Erreur" }
    }

    private func delete(_ l: AdminAPI.AdminListingSummary) {
        Task {
            try? await AdminAPI.shared.deleteListing(id: l.id)
            page = AdminAPI.AdminListingsPage(
                total: max(0, page.total - 1), page: page.page,
                pageSize: page.pageSize, items: page.items.filter { $0.id != l.id }
            )
        }
    }
    private func setStatus(_ l: AdminAPI.AdminListingSummary, _ st: String) {
        Task {
            if let updated = try? await AdminAPI.shared.patchListing(id: l.id, body: .init(status: st)) {
                if let i = page.items.firstIndex(where: { $0.id == updated.id }) {
                    var items = page.items; items[i] = updated
                    page = AdminAPI.AdminListingsPage(total: page.total, page: page.page,
                                                       pageSize: page.pageSize, items: items)
                }
            }
        }
    }
}

private struct AdminListingRow: View {
    let listing: AdminAPI.AdminListingSummary
    var onDelete: () -> Void
    var onStatus: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            cover
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(listing.title).font(.moblyHeading(14))
                        .foregroundStyle(Color.moblyTextPrimary).lineLimit(1)
                    Text(listing.status)
                        .font(.moblyBody(9, weight: .bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(statusTint.opacity(0.15)))
                        .foregroundStyle(statusTint)
                }
                Text([listing.neighborhood, listing.city].compactMap { $0 }.joined(separator: ", "))
                    .font(.moblyBody(11.5))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
                    .lineLimit(1)
                Text("\(listing.priceFcfa.formattedGrouped) FCFA\(LT(listing.priceUnit))")
                    .font(.moblyHeading(12.5))
                    .foregroundStyle(Color.moblyPrimary)
                HStack(spacing: 12) {
                    metric("eye.fill", "\(listing.views)")
                    metric("bubble.left.fill", "\(listing.contacts)")
                    metric("heart.fill", "\(listing.favorites)")
                }
                if let o = listing.owner {
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: AvatarPalette.hexValue(for: o.id, stored: o.avatarColor)))
                            .frame(width: 14, height: 14)
                        Text(o.fullName)
                            .font(.moblyBody(11)).foregroundStyle(Color(hex: 0x666F80))
                    }
                }
            }
            Spacer()
            Menu {
                Button("Marquer active")   { onStatus("ACTIVE") }
                Button("Mettre en pause")  { onStatus("PAUSED") }
                Button("Rejeter")           { onStatus("REJECTED") }
                Button("Archiver")          { onStatus("ARCHIVED") }
                Divider()
                Button("Supprimer", role: .destructive) { onDelete() }
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.system(size: 20)).foregroundStyle(Color(hex: 0x9A9DAC))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white))
    }

    @ViewBuilder private var cover: some View {
        Group {
            if let url = listing.coverUrl, let u = URL(string: url) {
                AsyncImage(url: u) { img in img.resizable().scaledToFill() }
                    placeholder: { Color(hex: 0xE2E4EC) }
            } else if let name = listing.imageName {
                Image(name).resizable().scaledToFill()
            } else {
                Color(hex: 0xE2E4EC)
            }
        }
        .frame(width: 56, height: 56).clipped()
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var statusTint: Color {
        switch listing.status {
        case "ACTIVE": return Color(hex: 0x1F8A5B)
        case "BOOSTED": return Color(hex: 0xC24E10)
        case "PENDING": return Color(hex: 0xE5A100)
        case "PAUSED": return Color(hex: 0x9A9DAC)
        case "REJECTED": return Color(hex: 0xE5484D)
        default: return Color(hex: 0x9A9DAC)
        }
    }
    private func metric(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9))
            Text(LT(text)).font(.moblyBody(10.5))
        }.foregroundStyle(Color(hex: 0x9A9DAC))
    }
}

// MARK: - Reports

private struct AdminReportsSection: View {
    @State private var page = AdminAPI.AdminReportsPage(total: 0, page: 0, pageSize: 25, items: [])
    @State private var status = "OPEN"
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(["OPEN","REVIEWING","ACTIONED","DISMISSED","all"], id: \.self) { s in
                        Button {
                            status = s
                        } label: {
                            Text(s == "all" ? "Tous" : s.capitalized)
                                .font(.moblyBody(11.5, weight: .semibold))
                                .foregroundStyle(status == s ? .white : Color.moblyTextPrimary)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Capsule().fill(status == s ? Color.moblyPrimary : .white))
                                .overlay(Capsule().stroke(status == s ? .clear : Color(hex: 0xE2E4EC), lineWidth: 1))
                        }
                    }
                }.padding(.horizontal, 16)
            }
            content
        }
        .task(id: status) { await load() }
    }

    private var content: some View {
        Group {
            if isLoading && page.items.isEmpty { ProgressView().padding(.top, 40) }
            else if page.items.isEmpty {
                Text("Aucun signalement").font(.moblyBody(13)).foregroundStyle(Color(hex: 0x9A9DAC)).padding(.top, 40)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 8) {
                        ForEach(page.items) { r in
                            AdminReportRow(report: r,
                                            onAction: { st in patch(r, st) })
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 30)
                }
                .refreshable { await load() }
            }
        }
    }

    private func load() async {
        isLoading = true; defer { isLoading = false }
        do { page = try await AdminAPI.shared.listReports(status: status) }
        catch { }
    }
    private func patch(_ r: AdminAPI.AdminReport, _ st: String) {
        Task {
            _ = try? await AdminAPI.shared.patchReport(id: r.id, body: .init(status: st))
            await load()
        }
    }
}

private struct AdminReportRow: View {
    let report: AdminAPI.AdminReport
    var onAction: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(report.target).font(.moblyBody(9, weight: .bold))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Capsule().fill(Color.moblyAccent.opacity(0.12)))
                    .foregroundStyle(Color.moblyAccent)
                Text(report.status).font(.moblyBody(9, weight: .bold))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Capsule().fill(Color(hex: 0x9A9DAC).opacity(0.12)))
                    .foregroundStyle(Color(hex: 0x666F80))
                Spacer()
                Text(report.createdAt, style: .relative)
                    .font(.moblyBody(10.5)).foregroundStyle(Color(hex: 0x9A9DAC))
            }
            Text(report.reason).font(.moblyHeading(14))
                .foregroundStyle(Color.moblyTextPrimary)
            if let d = report.details, !d.isEmpty {
                Text(d).font(.moblyBody(12))
                    .foregroundStyle(Color(hex: 0x666F80))
                    .lineLimit(4).fixedSize(horizontal: false, vertical: true)
            }
            if let r = report.reporter {
                Text("Par \(r.fullName) — \(r.email ?? r.phone)")
                    .font(.moblyBody(11)).foregroundStyle(Color(hex: 0x9A9DAC))
            }
            HStack(spacing: 8) {
                actionBtn("En revue", 0x2E7BE4) { onAction("REVIEWING") }
                actionBtn("Résolu", 0x1F8A5B) { onAction("ACTIONED") }
                actionBtn("Rejeter", 0xE5484D) { onAction("DISMISSED") }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white))
    }
    private func actionBtn(_ text: String, _ tint: UInt32, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(LT(text)).font(.moblyBody(11.5, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(Color(hex: tint).opacity(0.12)))
                .foregroundStyle(Color(hex: tint))
        }
    }
}

// MARK: - Analytics

private struct AdminAnalyticsSection: View {
    @State private var summary: AdminAPI.AnalyticsSummary?
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let s = summary {
                    HStack(spacing: 8) {
                        bigStat("DAU", "\(s.dau)")
                        bigStat("MAU", "\(s.mau)")
                    }
                    .padding(.horizontal, 16)

                    chart(s.dailyBuckets)
                        .padding(.horizontal, 16)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Événements les plus fréquents (30 j)")
                            .font(.moblyHeading(14))
                            .foregroundStyle(Color.moblyTextPrimary)
                        ForEach(s.topEvents) { e in
                            HStack {
                                Text(e.name).font(.moblyBody(12.5, weight: .semibold))
                                Spacer()
                                Text("\(e.count)").font(.moblyBody(12.5, weight: .semibold))
                                    .foregroundStyle(Color.moblyPrimary)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 10).fill(.white))
                        }
                    }
                    .padding(.horizontal, 16)
                } else {
                    ProgressView().padding(.top, 40)
                }
            }
            .padding(.vertical, 14)
        }
        .task { summary = try? await AdminAPI.shared.analyticsSummary() }
    }
    private func bigStat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(LT(value)).font(.moblyHeading(28)).foregroundStyle(Color.moblyPrimary)
            Text(LT(label)).font(.moblyBody(11.5)).foregroundStyle(Color(hex: 0x9A9DAC))
        }
        .frame(maxWidth: .infinity).padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white))
    }
    private func chart(_ buckets: [AdminAPI.AnalyticsSummary.Bucket]) -> some View {
        let peak = buckets.map(\.events).max() ?? 1
        return VStack(alignment: .leading, spacing: 8) {
            Text("Événements par jour (30 j)")
                .font(.moblyHeading(14))
                .foregroundStyle(Color.moblyTextPrimary)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(buckets) { b in
                    Capsule()
                        .fill(Color.moblyPrimary.opacity(0.75))
                        .frame(height: peak > 0
                               ? Swift.max(4, 100 * CGFloat(b.events) / CGFloat(peak))
                               : 4)
                }
            }
            .frame(height: 110)
            HStack {
                Text(buckets.first?.day ?? "")
                Spacer()
                Text(buckets.last?.day ?? "")
            }
            .font(.moblyBody(9.5)).foregroundStyle(Color(hex: 0x9A9DAC))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white))
    }
}

// MARK: - Threads

private struct AdminThreadsSection: View {
    @State private var page = AdminAPI.AdminThreadsPage(total: 0, page: 0, pageSize: 30, items: [])
    @State private var query = ""
    @State private var isLoading = false
    @State private var selected: AdminAPI.AdminThread?

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color(hex: 0x9A9DAC))
                TextField("Annonce ou participant…", text: $query).font(.moblyBody(14))
            }
            .padding(.horizontal, 12).frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 12).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: 0xE2E4EC), lineWidth: 1))
            .padding(.horizontal, 16)

            if isLoading && page.items.isEmpty {
                ProgressView().padding(.top, 40)
            } else if page.items.isEmpty {
                Text("Aucune conversation").font(.moblyBody(13))
                    .foregroundStyle(Color(hex: 0x9A9DAC)).padding(.top, 40)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 8) {
                        ForEach(page.items) { t in
                            Button { selected = t } label: { threadRow(t) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 30)
                }
                .refreshable { await load() }
            }
        }
        .task(id: query) { await load() }
        .sheet(item: $selected) { AdminThreadDetailSheet(thread: $0) }
    }
    private func threadRow(_ t: AdminAPI.AdminThread) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(t.listing?.title ?? "Conversation")
                    .font(.moblyHeading(13.5)).lineLimit(1)
                    .foregroundStyle(Color.moblyTextPrimary)
                Text(t.participants.map(\.fullName).joined(separator: " · "))
                    .font(.moblyBody(12)).foregroundStyle(Color(hex: 0x9A9DAC))
                    .lineLimit(1)
                if let lm = t.lastMessage {
                    Text(lm.text).font(.moblyBody(12))
                        .foregroundStyle(Color(hex: 0x666F80))
                        .lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(t.messageCount)").font(.moblyHeading(13))
                    .foregroundStyle(Color.moblyPrimary)
                Text("msg").font(.moblyBody(10)).foregroundStyle(Color(hex: 0x9A9DAC))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white))
    }
    private func load() async {
        isLoading = true; defer { isLoading = false }
        do { page = try await AdminAPI.shared.listThreads(query: query.isEmpty ? nil : query) }
        catch { }
    }
}

private struct AdminThreadDetailSheet: View {
    let thread: AdminAPI.AdminThread
    @Environment(\.dismiss) private var dismiss
    @State private var messages: [AdminAPI.AdminMessage] = []
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(messages) { m in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Circle().fill(Color(hex: AvatarPalette.hexValue(
                                    for: m.senderId, stored: m.sender?.avatarColor
                                ))).frame(width: 14, height: 14)
                                Text(m.sender?.fullName ?? "—")
                                    .font(.moblyBody(11, weight: .semibold))
                                    .foregroundStyle(Color(hex: 0x666F80))
                                Spacer()
                                Text(m.createdAt, style: .time)
                                    .font(.moblyBody(10)).foregroundStyle(Color(hex: 0x9A9DAC))
                            }
                            Text(m.text).font(.moblyBody(13))
                                .foregroundStyle(Color.moblyTextPrimary)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.white))
                    }
                }.padding(14)
            }
            .background(Color(hex: 0xF7F8FA).ignoresSafeArea())
            .navigationTitle(thread.listing?.title ?? "Conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Fermer") { dismiss() } }
            }
            .task { messages = (try? await AdminAPI.shared.threadMessages(id: thread.id)) ?? [] }
        }
    }
}

// MARK: - Visits

private struct AdminVisitsSection: View {
    @State private var page = AdminAPI.AdminVisitsPage(total: 0, page: 0, pageSize: 30, items: [])
    @State private var status = "all"
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(["all","REQUESTED","CONFIRMED","CANCELLED","COMPLETED","NO_SHOW"], id: \.self) { s in
                        Button { status = s } label: {
                            Text(s == "all" ? "Toutes" : s.capitalized)
                                .font(.moblyBody(11.5, weight: .semibold))
                                .foregroundStyle(status == s ? .white : Color.moblyTextPrimary)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Capsule().fill(status == s ? Color.moblyPrimary : .white))
                                .overlay(Capsule().stroke(status == s ? .clear : Color(hex: 0xE2E4EC), lineWidth: 1))
                        }
                    }
                }.padding(.horizontal, 16)
            }
            if isLoading && page.items.isEmpty { ProgressView().padding(.top, 40) }
            else if page.items.isEmpty {
                Text("Aucune visite").font(.moblyBody(13)).foregroundStyle(Color(hex: 0x9A9DAC)).padding(.top, 40)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 8) {
                        ForEach(page.items) { v in visitRow(v) }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 30)
                }
                .refreshable { await load() }
            }
        }
        .task(id: status) { await load() }
    }
    private func visitRow(_ v: AdminAPI.AdminVisit) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(v.status).font(.moblyBody(9, weight: .bold))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Capsule().fill(Color.moblyAccent.opacity(0.12)))
                    .foregroundStyle(Color.moblyAccent)
                Spacer()
                Text(v.scheduledAt, style: .date).font(.moblyBody(11))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
            }
            Text(v.listing?.title ?? "—").font(.moblyHeading(13.5))
                .foregroundStyle(Color.moblyTextPrimary).lineLimit(1)
            HStack(spacing: 10) {
                if let vi = v.visitor {
                    HStack(spacing: 4) {
                        Circle().fill(Color(hex: AvatarPalette.hexValue(for: vi.id, stored: vi.avatarColor)))
                            .frame(width: 12, height: 12)
                        Text("V: \(vi.fullName)").font(.moblyBody(11))
                    }.foregroundStyle(Color(hex: 0x666F80))
                }
                if let ow = v.owner {
                    HStack(spacing: 4) {
                        Circle().fill(Color(hex: AvatarPalette.hexValue(for: ow.id, stored: ow.avatarColor)))
                            .frame(width: 12, height: 12)
                        Text("P: \(ow.fullName)").font(.moblyBody(11))
                    }.foregroundStyle(Color(hex: 0x666F80))
                }
            }
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 12).fill(.white))
    }
    private func load() async {
        isLoading = true; defer { isLoading = false }
        do { page = try await AdminAPI.shared.listVisits(status: status) }
        catch { }
    }
}
