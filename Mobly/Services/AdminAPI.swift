import Foundation

/// REST client for `/api/v1/admin/*`.
///
/// Reuses `MoblyAPI.shared` for the underlying request pipeline (token,
/// refresh, retry, offline detection) — this class is a typed wrapper that
/// exposes the admin surface as strongly-typed Swift methods.
final class AdminAPI {
    static let shared = AdminAPI()
    private init() {}
    private let api = MoblyAPI.shared

    // MARK: - Overview

    struct Overview: Decodable {
        let users: Int
        let owners: Int
        let newUsers30d: Int
        let listings: Int
        let pendingListings: Int
        let boostedListings: Int
        let newListings30d: Int
        let activeSessions24h: Int
        let openReports: Int
        let pendingVisits: Int
        let confirmedVisits: Int
        let threads: Int
        let messagesLast24h: Int
    }

    func overview() async throws -> Overview {
        try await api.request("admin/overview", authorized: true)
    }

    // MARK: - Analytics

    struct AnalyticsSummary: Decodable {
        let dailyBuckets: [Bucket]
        let dau: Int
        let mau: Int
        let topEvents: [TopEvent]
        struct Bucket: Decodable, Identifiable {
            let day: String
            let sessions: Int
            let events: Int
            var id: String { day }
        }
        struct TopEvent: Decodable, Identifiable {
            let name: String
            let count: Int
            var id: String { name }
        }
    }

    func analyticsSummary() async throws -> AnalyticsSummary {
        try await api.request("admin/analytics/summary", authorized: true)
    }

    // MARK: - Users

    struct AdminUserSummary: Decodable, Identifiable {
        let id: String
        let fullName: String
        let email: String?
        let phone: String
        let isOwner: Bool
        let isAdmin: Bool
        let isActive: Bool
        let verified: Bool
        let identityVerified: Bool
        let city: String?
        let avatarUrl: String?
        let avatarColor: String?
        let createdAt: Date
        let lastSeenAt: Date?
    }

    struct AdminUserDetail: Decodable {
        let user: FullUser
        struct FullUser: Decodable {
            let id: String
            let fullName: String
            let email: String?
            let phone: String
            let isOwner: Bool
            let isAdmin: Bool
            let isActive: Bool
            let verified: Bool
            let identityVerified: Bool
            let city: String?
            let region: String?
            let neighborhood: String?
            let bio: String?
            let avatarUrl: String?
            let avatarColor: String?
            let moblyScore: Double?
            let rating: Double?
            let responseRate: Double?
            let createdAt: Date
            let lastSeenAt: Date?
            let _count: Counts
            struct Counts: Decodable {
                let listings: Int
                let favorites: Int
                let reviews: Int
                let reviewsReceived: Int
                let messages: Int
                let visitsRequested: Int
                let visitsReceived: Int
                let sessions: Int
                let events: Int
            }
        }
    }

    struct AdminUsersPage: Decodable {
        let total: Int
        let page: Int
        let pageSize: Int
        let items: [AdminUserSummary]
    }

    func listUsers(query: String? = nil, role: String = "all", active: String = "all",
                   page: Int = 0, pageSize: Int = 20) async throws -> AdminUsersPage {
        var q: [String: String] = [
            "role": role, "active": active,
            "page": String(page), "pageSize": String(pageSize),
        ]
        if let query, !query.isEmpty { q["query"] = query }
        return try await api.request("admin/users", query: q, authorized: true)
    }

    func user(id: String) async throws -> AdminUserDetail {
        try await api.request("admin/users/\(id)", authorized: true)
    }

    struct UserPatchBody: Encodable {
        var isActive: Bool? = nil
        var verified: Bool? = nil
        var identityVerified: Bool? = nil
        var isOwner: Bool? = nil
        var isAdmin: Bool? = nil
    }

    func patchUser(id: String, body: UserPatchBody) async throws -> AdminUserSummary {
        struct Wrap: Decodable { let user: AdminUserSummary }
        let w: Wrap = try await api.request(
            "admin/users/\(id)", method: "PATCH", body: body, authorized: true
        )
        return w.user
    }

    func deleteUser(id: String) async throws {
        _ = try await api.request(
            "admin/users/\(id)", method: "DELETE", authorized: true
        ) as EmptyResponse
    }

    // MARK: - Listings

    struct AdminListingSummary: Decodable, Identifiable {
        let id: String
        let title: String
        let category: String
        let status: String
        let available: Bool
        let verified: Bool
        let city: String
        let neighborhood: String?
        let priceFcfa: Int
        let priceUnit: String
        let coverUrl: String?
        let imageName: String?
        let views: Int
        let contacts: Int
        let favorites: Int
        let createdAt: Date
        let ownerId: String
        let owner: OwnerRef?
        struct OwnerRef: Decodable {
            let id: String
            let fullName: String
            let avatarUrl: String?
            let avatarColor: String?
        }
    }

    struct AdminListingsPage: Decodable {
        let total: Int
        let page: Int
        let pageSize: Int
        let items: [AdminListingSummary]
    }

    func listListings(query: String? = nil, status: String = "all",
                      category: String = "all", city: String = "all",
                      page: Int = 0, pageSize: Int = 20) async throws -> AdminListingsPage {
        var q: [String: String] = [
            "status": status, "category": category, "city": city,
            "page": String(page), "pageSize": String(pageSize),
        ]
        if let query, !query.isEmpty { q["query"] = query }
        return try await api.request("admin/listings", query: q, authorized: true)
    }

    struct ListingPatchBody: Encodable {
        var status: String? = nil
        var available: Bool? = nil
        var verified: Bool? = nil
    }

    func patchListing(id: String, body: ListingPatchBody) async throws -> AdminListingSummary {
        struct Wrap: Decodable { let listing: AdminListingSummary }
        let w: Wrap = try await api.request(
            "admin/listings/\(id)", method: "PATCH", body: body, authorized: true
        )
        return w.listing
    }

    func deleteListing(id: String) async throws {
        _ = try await api.request(
            "admin/listings/\(id)", method: "DELETE", authorized: true
        ) as EmptyResponse
    }

    // MARK: - Reports

    struct AdminReport: Decodable, Identifiable {
        let id: String
        let reporterId: String
        let target: String
        let targetId: String
        let reason: String
        let details: String?
        let status: String
        let resolution: String?
        let resolvedAt: Date?
        let createdAt: Date
        let reporter: Reporter?
        struct Reporter: Decodable {
            let id: String
            let fullName: String
            let email: String?
            let phone: String
        }
    }

    struct AdminReportsPage: Decodable {
        let total: Int
        let page: Int
        let pageSize: Int
        let items: [AdminReport]
    }

    func listReports(status: String = "all", page: Int = 0, pageSize: Int = 25)
        async throws -> AdminReportsPage
    {
        let q = [
            "status": status,
            "page": String(page),
            "pageSize": String(pageSize),
        ]
        return try await api.request("admin/reports", query: q, authorized: true)
    }

    struct ReportPatchBody: Encodable {
        let status: String
        var resolution: String? = nil
    }

    func patchReport(id: String, body: ReportPatchBody) async throws -> AdminReport {
        struct Wrap: Decodable { let report: AdminReport }
        let w: Wrap = try await api.request(
            "admin/reports/\(id)", method: "PATCH", body: body, authorized: true
        )
        return w.report
    }

    // MARK: - Threads (chat moderation)

    struct AdminThread: Decodable, Identifiable {
        let id: String
        let listing: ListingRef?
        let participants: [ParticipantRef]
        let messageCount: Int
        let lastMessage: LastMessage?
        let updatedAt: Date
        struct ListingRef: Decodable {
            let id: String
            let title: String
            let imageName: String?
            let coverUrl: String?
        }
        struct ParticipantRef: Decodable, Identifiable {
            let id: String
            let fullName: String
            let avatarUrl: String?
            let avatarColor: String?
        }
        struct LastMessage: Decodable {
            let text: String
            let kind: String
            let createdAt: Date
        }
    }

    struct AdminThreadsPage: Decodable {
        let total: Int
        let page: Int
        let pageSize: Int
        let items: [AdminThread]
    }

    func listThreads(query: String? = nil, page: Int = 0, pageSize: Int = 30)
        async throws -> AdminThreadsPage
    {
        var q = [
            "page": String(page),
            "pageSize": String(pageSize),
        ]
        if let query, !query.isEmpty { q["query"] = query }
        return try await api.request("admin/threads", query: q, authorized: true)
    }

    struct AdminMessage: Decodable, Identifiable {
        let id: String
        let threadId: String
        let senderId: String
        let kind: String
        let text: String
        let visitId: String?
        let visitAction: String?
        let createdAt: Date
        let sender: SenderRef?
        struct SenderRef: Decodable {
            let id: String
            let fullName: String
            let avatarColor: String?
        }
    }

    func threadMessages(id: String) async throws -> [AdminMessage] {
        struct Wrap: Decodable { let items: [AdminMessage] }
        let w: Wrap = try await api.request("admin/threads/\(id)/messages", authorized: true)
        return w.items
    }

    // MARK: - Visits (marketplace-wide)

    struct AdminVisit: Decodable, Identifiable {
        let id: String
        let status: String
        let scheduledAt: Date
        let note: String?
        let createdAt: Date
        let listing: ListingRef?
        let visitor: PersonRef?
        let owner: PersonRef?
        struct ListingRef: Decodable {
            let id: String
            let title: String
            let city: String?
            let imageName: String?
            let coverUrl: String?
        }
        struct PersonRef: Decodable {
            let id: String
            let fullName: String
            let avatarColor: String?
        }
    }

    struct AdminVisitsPage: Decodable {
        let total: Int
        let page: Int
        let pageSize: Int
        let items: [AdminVisit]
    }

    func listVisits(status: String = "all", page: Int = 0, pageSize: Int = 30)
        async throws -> AdminVisitsPage
    {
        let q = [
            "status": status,
            "page": String(page),
            "pageSize": String(pageSize),
        ]
        return try await api.request("admin/visits", query: q, authorized: true)
    }
}
