import Foundation

/// REST client for the Mobly backend.
///
/// Owns the session: tokens live in the Keychain, an expired access token is
/// refreshed transparently, and a refused refresh (or a real sign-out) clears
/// everything and tells the app.
final class MoblyAPI {
    static let shared = MoblyAPI()

    /// Overridable at launch so a device build can point at a LAN IP or a
    /// deployed host without a recompile:
    /// `API_BASE_URL=http://192.168.1.20:4000/api/v1`.
    ///
    /// NOTE: plain `http://` only works in the simulator. App Transport
    /// Security blocks cleartext on a real device unless an ATS exception is
    /// added — use https for anything off-machine.
    /// Resolution order:
    ///   1. `API_BASE_URL` env var — set in the Xcode scheme, wins for a quick
    ///      one-off without touching build settings
    ///   2. `MoblyAPIBaseURL` from Info.plist (`MOBLY_API_BASE_URL` build
    ///      setting) — Debug points at the Mac's LAN address so a **device**
    ///      build can reach the dev server; a phone can't resolve 127.0.0.1
    ///   3. localhost — simulator only
    ///
    /// Release ships with an empty setting deliberately: it must be filled in
    /// with the real https:// host rather than silently falling back to
    /// someone's laptop.
    var baseURL: URL = {
        if let raw = ProcessInfo.processInfo.environment["API_BASE_URL"],
           !raw.isEmpty, let url = URL(string: raw) { return url }
        if let raw = Bundle.main.object(forInfoDictionaryKey: "MoblyAPIBaseURL") as? String,
           !raw.isEmpty, let url = URL(string: raw) { return url }
        return URL(string: "http://127.0.0.1:4000/api/v1")!
    }()

    // MARK: - Session storage

    private enum Key {
        static let access = "accessToken"
        static let refresh = "refreshToken"
    }

    private(set) var token: String? {
        get { Keychain.get(Key.access) }
        set {
            if let newValue { Keychain.set(newValue, for: Key.access) }
            else { Keychain.delete(Key.access) }
        }
    }

    private(set) var refreshToken: String? {
        get { Keychain.get(Key.refresh) }
        set {
            if let newValue { Keychain.set(newValue, for: Key.refresh) }
            else { Keychain.delete(Key.refresh) }
        }
    }

    var isAuthenticated: Bool { token != nil }

    /// Posted when the session ends and the user must sign in again — either a
    /// real sign-out or a refresh the server refused.
    static let sessionExpired = Notification.Name("MoblySessionExpired")

    func store(token: String, refreshToken: String?) {
        self.token = token
        if let refreshToken { self.refreshToken = refreshToken }
    }

    /// Bumped by every `clearSession()`. A refresh that was already in flight
    /// when the user signed out captures the old value and checks it before
    /// writing — otherwise it would re-store credentials into the Keychain
    /// for an account that just logged out, silently resurrecting the
    /// session on the next launch.
    private var sessionGeneration: Int = 0

    func clearSession() {
        token = nil
        refreshToken = nil
        sessionGeneration &+= 1
        // Cancel any in-flight refresh so it can't complete and re-store.
        refreshTask?.cancel()
        refreshTask = nil
    }

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        // Without explicit timeouts a request can hang for 60s on a stalled
        // connection, which on a weak mobile network reads as a frozen app.
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        cfg.waitsForConnectivity = false   // fail fast so the UI can say "hors ligne"
        return URLSession(configuration: cfg)
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {
        // Debug shortcut: inject an access token via env so simulator screenshots
        // can skip the sign-in flow. Never set by a production build.
        let env = ProcessInfo.processInfo.environment
        if let t = env["DEBUG_ACCESS_TOKEN"], !t.isEmpty {
            Keychain.set(t, for: Key.access)
            if let r = env["DEBUG_REFRESH_TOKEN"], !r.isEmpty {
                Keychain.set(r, for: Key.refresh)
            }
        }
    }

    // MARK: - Errors

    /// Mirrors the backend's `code` field. The app branches on these — never on
    /// the message, which is French prose and free to change.
    enum Code: String {
        case validationFailed = "VALIDATION_FAILED"
        case unauthenticated  = "UNAUTHENTICATED"
        case accountNotFound  = "ACCOUNT_NOT_FOUND"
        case invalidPassword  = "INVALID_PASSWORD"
        case noPasswordSet    = "NO_PASSWORD_SET"
        case tokenExpired     = "TOKEN_EXPIRED"
        case forbidden        = "FORBIDDEN"
        case notFound         = "NOT_FOUND"
        case alreadyExists    = "ALREADY_EXISTS"
        case rateLimited      = "RATE_LIMITED"
        case otpRateLimited   = "OTP_RATE_LIMITED"
        case otpInvalid       = "OTP_INVALID"
        case otpExpired       = "OTP_EXPIRED"
        case otpLocked        = "OTP_LOCKED"
        case ownerRequired    = "OWNER_REQUIRED"
        case conflict         = "CONFLICT"
        case internalError    = "INTERNAL"
        case offline          = "OFFLINE"
        case unknown          = "UNKNOWN"
    }

    struct APIError: Error, LocalizedError {
        let status: Int
        let code: Code
        let message: String
        /// Server-side correlation id — worth surfacing on a 500 so a user
        /// report can be traced to a log line.
        let requestId: String?

        /// Per-field messages from the server, keyed by field name.
        let fields: [String: String]

        var errorDescription: String? { message }
        var isOffline: Bool { code == .offline }
        /// Transient conditions where retrying is reasonable.
        var isRetryable: Bool { code == .offline || status >= 500 }
        /// The user needs to sign in before this will work.
        var needsSignIn: Bool { code == .unauthenticated || code == .tokenExpired }
    }

    private struct ErrorBody: Decodable {
        let error: String?
        let code: String?
        let requestId: String?
        let fields: [String: String]?
    }

    // MARK: - Request

    func request<T: Decodable>(
        _ path: String,
        method: String = "GET",
        query: [String: String] = [:],
        body: Encodable? = nil,
        authorized: Bool = false,
        retries: Int = 2
    ) async throws -> T {
        var comps = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }

        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authorized, let token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body { req.httpBody = try JSONEncoder().encode(AnyEncodable(body)) }

        let data: Data
        let http: HTTPURLResponse
        do {
            let start = CFAbsoluteTimeGetCurrent()
            let (d, resp) = try await session.data(for: req)
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            Task { @MainActor in NetworkMonitor.shared.recordLatency(elapsed) }
            data = d
            http = resp as? HTTPURLResponse ?? HTTPURLResponse()
        } catch let urlError as URLError {
            // Separate "no network" from a server fault so the UI can offer the
            // right recovery ("vérifiez votre connexion" vs "réessayez").
            let offlineCodes: Set<URLError.Code> = [
                .notConnectedToInternet, .networkConnectionLost,
                .cannotConnectToHost, .cannotFindHost, .timedOut,
                .dataNotAllowed, .internationalRoamingOff,
            ]
            if offlineCodes.contains(urlError.code) {
                if retries > 0 {
                    try? await Task.sleep(nanoseconds: backoff(attempt: 2 - retries))
                    return try await request(path, method: method, query: query, body: body,
                                             authorized: authorized, retries: retries - 1)
                }
                throw APIError(status: 0, code: .offline,
                               message: "Pas de connexion. Vérifiez votre réseau.",
                               requestId: nil, fields: [:])
            }
            throw APIError(status: 0, code: .unknown,
                           message: urlError.localizedDescription,
                           requestId: nil, fields: [:])
        }

        if (200..<300).contains(http.statusCode) {
            if T.self == EmptyResponse.self { return EmptyResponse() as! T }
            return try decoder.decode(T.self, from: data)
        }

        let parsed = try? decoder.decode(ErrorBody.self, from: data)
        let code = Code(rawValue: parsed?.code ?? "") ?? .unknown

        // An expired access token is recoverable: spend a refresh token and
        // replay once. Guarded by `authorized` so an anonymous 401 can't drive
        // a refresh loop.
        if code == .tokenExpired, authorized, retries > 0 {
            if await refreshSession() {
                return try await request(path, method: method, query: query, body: body,
                                         authorized: authorized, retries: retries - 1)
            }
        }

        // Server faults are usually transient — back off and retry.
        if http.statusCode >= 500, retries > 0 {
            try? await Task.sleep(nanoseconds: backoff(attempt: 2 - retries))
            return try await request(path, method: method, query: query, body: body,
                                     authorized: authorized, retries: retries - 1)
        }

        throw APIError(
            status: http.statusCode,
            code: code,
            message: parsed?.error ?? "La requête a échoué (\(http.statusCode))",
            requestId: parsed?.requestId,
            fields: parsed?.fields ?? [:]
        )
    }

    /// Exponential backoff with jitter, so concurrent retries don't sync up and
    /// hit a recovering server in lockstep.
    private func backoff(attempt: Int) -> UInt64 {
        let base = pow(2.0, Double(attempt)) * 0.4          // ≈0.4s, 0.8s
        let jitter = Double.random(in: 0...0.3)
        return UInt64((base + jitter) * 1_000_000_000)
    }

    // MARK: - Refresh (single-flight)

    private var refreshTask: Task<Bool, Never>?

    /// Exchange the refresh token for a new pair.
    ///
    /// Single-flight on purpose: several requests can 401 at the same moment,
    /// and letting each spend the refresh token looks exactly like token reuse
    /// to the server — which revokes the whole family and signs the user out.
    /// So concurrent callers await one shared attempt.
    private func refreshSession() async -> Bool {
        if let existing = refreshTask { return await existing.value }

        // Snapshot the generation this refresh belongs to. If the user signs
        // out while the POST is in flight, `clearSession()` bumps the counter
        // and the result below is discarded instead of re-storing credentials.
        let generation = sessionGeneration

        let task = Task<Bool, Never> { [weak self] in
            guard let self, let rt = self.refreshToken else { return false }
            defer { self.refreshTask = nil }
            do {
                struct Body: Encodable { let refreshToken: String }
                // retries: 0 — a refresh failure must never recurse into itself.
                let res: AuthResponse = try await self.request(
                    "auth/refresh", method: "POST",
                    body: Body(refreshToken: rt), authorized: false, retries: 0
                )
                // The session ended (sign-out) while we were waiting — drop
                // the new credentials on the floor.
                guard generation == self.sessionGeneration else { return false }
                self.store(token: res.token, refreshToken: res.refreshToken)
                return true
            } catch {
                // Don't wipe a session that has already been replaced.
                guard generation == self.sessionGeneration else { return false }
                // Refused: expired, revoked, or reuse detected. Session is over.
                self.clearSession()
                await MainActor.run {
                    NotificationCenter.default.post(name: MoblyAPI.sessionExpired, object: nil)
                }
                return false
            }
        }
        refreshTask = task
        return await task.value
    }

    // MARK: - Auth

    func requestOTP(phone: String) async throws -> OTPRequestResponse {
        try await request("auth/otp/request", method: "POST", body: ["phone": phone])
    }

    func verifyOTP(phone: String, code: String,
                   fullName: String? = nil, isOwner: Bool? = nil) async throws -> AuthResponse {
        struct Body: Encodable {
            let phone: String; let code: String
            let fullName: String?; let isOwner: Bool?
        }
        let res: AuthResponse = try await request(
            "auth/otp/verify", method: "POST",
            body: Body(phone: phone, code: code, fullName: fullName, isOwner: isOwner)
        )
        store(token: res.token, refreshToken: res.refreshToken)
        return res
    }

    // MARK: - Identity verification (Didit)

    /// Start a check. Returns the one-shot hosted URL to open in a browser
    /// sheet — the documents go straight to the provider, never through us.
    func startIdentityVerification() async throws -> IdentitySessionDTO {
        try await request("verification/session", method: "POST", authorized: true)
    }

    /// Current verification state. Polled after the hosted flow closes, since
    /// the provider's webhook may still be in flight.
    func identityVerificationStatus() async throws -> IdentityStatusDTO {
        try await request("verification/me", authorized: true)
    }

    // MARK: - Social sign-in

    /// Exchange an Apple identity token for a Mobly session. Same response
    /// shape as the OTP verify — token + refresh + user — so the rest of the
    /// app treats it identically.
    func signInWithApple(idToken: String, fullName: String? = nil,
                         nonce: String? = nil) async throws -> AuthResponse {
        struct Body: Encodable { let idToken: String; let fullName: String?; let nonce: String? }
        let res: AuthResponse = try await request(
            "auth/apple", method: "POST",
            body: Body(idToken: idToken, fullName: fullName, nonce: nonce)
        )
        store(token: res.token, refreshToken: res.refreshToken)
        return res
    }

    /// Send the Google-issued ID token to our backend for verification.
    func signInWithGoogle(idToken: String) async throws -> AuthResponse {
        struct Body: Encodable { let idToken: String }
        let res: AuthResponse = try await request(
            "auth/google", method: "POST", body: Body(idToken: idToken)
        )
        store(token: res.token, refreshToken: res.refreshToken)
        return res
    }

    // MARK: - Signup (two-step: validate+send, then verify+create)

    struct SignupStartResponse: Decodable {
        let sent: Bool
        let phone: String
        let codeLength: Int
        let devCode: String?
    }

    struct SignupBody: Encodable {
        let fullName: String
        let phone: String
        let email: String
        let password: String
        var code: String? = nil
    }

    func signupStart(_ body: SignupBody) async throws -> SignupStartResponse {
        try await request("auth/signup/start", method: "POST", body: body)
    }

    func signupVerify(_ body: SignupBody) async throws -> AuthResponse {
        let res: AuthResponse = try await request("auth/signup/verify", method: "POST", body: body)
        store(token: res.token, refreshToken: res.refreshToken)
        return res
    }

    struct AvailabilityResponse: Decodable {
        let phoneTaken: Bool?
        let emailTaken: Bool?
        /// Masked address one or two characters away from this one — almost
        /// certainly the same person mistyping.
        let similarEmail: String?
    }

    /// Live availability, used to flag a taken number/e-mail while typing.
    func checkAvailability(phone: String?, email: String?) async throws -> AvailabilityResponse {
        struct Body: Encodable { let phone: String?; let email: String? }
        return try await request("auth/signup/check", method: "POST",
                                 body: Body(phone: phone, email: email), retries: 0)
    }

    // MARK: - Password reset

    struct ForgotResponse: Decodable {
        let sent: Bool
        /// Display-only, e.g. "+237 6•• •• •• 66". The real number stays on the
        /// server so an e-mail can't be traded for a phone number.
        let maskedPhone: String
        /// Opaque, signed, 15-minute token identifying the account being reset.
        let resetToken: String
        let codeLength: Int
        let devCode: String?
    }

    func forgotPassword(identifier: String) async throws -> ForgotResponse {
        struct Body: Encodable { let identifier: String }
        return try await request("auth/password/forgot", method: "POST",
                                 body: Body(identifier: identifier))
    }

    func resetPassword(resetToken: String, code: String,
                       password: String) async throws -> AuthResponse {
        struct Body: Encodable { let resetToken: String; let code: String; let password: String }
        let res: AuthResponse = try await request(
            "auth/password/reset", method: "POST",
            body: Body(resetToken: resetToken, code: code, password: password)
        )
        store(token: res.token, refreshToken: res.refreshToken)
        return res
    }

    func logout(allDevices: Bool = false) async {
        struct Body: Encodable { let refreshToken: String?; let allDevices: Bool }
        // Best effort: the local session is cleared regardless, so a network
        // failure can't strand the user looking signed in.
        _ = try? await request(
            "auth/logout", method: "POST",
            body: Body(refreshToken: refreshToken, allDevices: allDevices),
            authorized: true, retries: 0
        ) as EmptyResponse
        clearSession()
    }

    func me() async throws -> UserDTO {
        struct Wrap: Decodable { let user: UserDTO }
        let w: Wrap = try await request("auth/me", authorized: true)
        return w.user
    }

    func updateMe(fullName: String? = nil, email: String? = nil,
                  isOwner: Bool? = nil, avatarColor: String? = nil) async throws -> UserDTO {
        struct Body: Encodable {
            let fullName: String?; let email: String?; let isOwner: Bool?
            let avatarColor: String?
        }
        struct Wrap: Decodable { let user: UserDTO }
        let w: Wrap = try await request(
            "auth/me", method: "PATCH",
            body: Body(fullName: fullName, email: email, isOwner: isOwner, avatarColor: avatarColor),
            authorized: true
        )
        return w.user
    }

    // MARK: - Listings

    func searchListings(query: String? = nil, category: String? = nil,
                        city: String? = nil, limit: Int = 200) async throws -> [ListingDTO] {
        var q: [String: String] = ["limit": String(limit)]
        if let query { q["query"] = query }
        if let category, category != "Tous" { q["category"] = category }
        if let city { q["city"] = city }
        struct Wrap: Decodable { let items: [ListingDTO] }
        let w: Wrap = try await request("listings", query: q)
        return w.items
    }

    func listing(id: String) async throws -> ListingDTO {
        struct Wrap: Decodable { let listing: ListingDTO }
        let w: Wrap = try await request("listings/\(id)")
        return w.listing
    }

    /// Fire-and-forget view tracker. Hits the same `GET /listings/:id` the
    /// full loader would, but with a `source` tag so the owner's stats can
    /// break traffic down by origin. Errors are swallowed — a missed view is
    /// far cheaper than a blocked detail page.
    @discardableResult
    func trackListingView(id: String, source: String?) async throws -> Bool {
        var q: [String: String] = [:]
        if let s = source { q["source"] = s }
        let _: ListingDTO? = try? await {
            struct Wrap: Decodable { let listing: ListingDTO }
            let w: Wrap = try await request("listings/\(id)", query: q)
            return w.listing
        }()
        return true
    }

    /// Publish an owner's annonce (POST /listings). Matches the zod schema on
    /// backend/src/routes/listings.routes.ts — any missing/typed-wrong field
    /// gets a 400 back rather than a friendly message, so keep it in sync.
    struct CreateListingBody: Encodable {
        let title: String
        let category: String
        let deal: String            // "RENT" | "SALE"
        let region: String?
        let city: String
        let neighborhood: String?
        let priceFcfa: Int
        let furnished: Bool
        let rooms: Int
        let about: String?
        let tags: [String]
        let coverUrl: String?
        let imageName: String?
        let photos: [String]
        let lat: Double?
        let lng: Double?
    }

    // MARK: - Owner stats

    struct OwnerListingStats: Decodable {
        struct Metrics: Decodable {
            let views: Int
            let contacts: Int
            let favorites: Int
            let visits: Int
            let contactRate: Double
            let deltas7d: Deltas
            /// Optional: the server returns null when the previous period had
            /// too little traffic for a percentage to mean anything. The UI
            /// hides the badge rather than printing a nonsense "+6100%".
            struct Deltas: Decodable {
                let views: Int?
                let contacts: Int?
                let favorites: Int?
            }
        }
        struct DailyPoint: Decodable {
            let date: String
            let label: String
            let views: Int
        }
        struct SourceBucket: Decodable {
            let source: String
            let count: Int
            let percent: Int
        }
        let listing: ListingDTO
        let metrics: Metrics
        let daily: [DailyPoint]
        let sources: [SourceBucket]
        let generatedAt: String
    }

    func ownerListingStats(id: String) async throws -> OwnerListingStats {
        try await request("owner/stats/\(id)", authorized: true)
    }

    /// Aggregate dashboard figures. `deltas30d` values are optional on purpose:
    /// nil means there is no prior 30-day period to compare against, and the
    /// UI hides the trend badge rather than inventing one.
    struct OwnerOverview: Decodable {
        struct Window: Decodable { let views: Int; let contacts: Int; let favorites: Int }
        struct Deltas: Decodable { let views: Int?; let contacts: Int?; let favorites: Int? }
        let listings: Int
        let boosted: Int
        let views: Int
        let contacts: Int
        let favorites: Int
        let last30d: Window
        let deltas30d: Deltas
    }

    func ownerOverview() async throws -> OwnerOverview {
        try await request("owner/overview", authorized: true)
    }

    /// Public profile of any user (chat header taps → PeerProfileView).
    /// Deliberately narrow: no phone / email, only fields safe to share.
    struct PublicUserDTO: Decodable {
        let id: String
        let fullName: String
        let avatarUrl: String?
        let avatarColor: String?
        let verified: Bool
        let isOwner: Bool
        let city: String?
        let region: String?
        let createdAt: Date
        let listingsCount: Int
        let avgRating: Double?
        let totalReviews: Int
    }

    func user(id: String) async throws -> PublicUserDTO {
        struct Wrap: Decodable { let user: PublicUserDTO }
        let w: Wrap = try await request("users/\(id)")
        return w.user
    }

    /// PATCH /listings/:id/availability — flip disponible / indisponible.
    /// The server's public search excludes `available=false`, so this is what
    /// actually pulls the annonce off the map, home feed and search list.
    func setListingAvailability(id: String, available: Bool) async throws -> ListingDTO {
        struct Body: Encodable { let available: Bool }
        struct Wrap: Decodable { let listing: ListingDTO }
        let w: Wrap = try await request(
            "listings/\(id)/availability", method: "PATCH",
            body: Body(available: available), authorized: true
        )
        return w.listing
    }

    func createListing(_ body: CreateListingBody) async throws -> ListingDTO {
        struct Wrap: Decodable { let listing: ListingDTO }
        let w: Wrap = try await request("listings", method: "POST",
                                        body: body, authorized: true)
        return w.listing
    }

    /// PATCH /listings/:id — edit an existing owner annonce. Same field set
    /// as `CreateListingBody`; the server accepts a partial payload.
    func updateListing(id: String, body: CreateListingBody) async throws -> ListingDTO {
        struct Wrap: Decodable { let listing: ListingDTO }
        let w: Wrap = try await request("listings/\(id)", method: "PATCH",
                                        body: body, authorized: true)
        return w.listing
    }

    // MARK: - Favorites

    func favorites() async throws -> [ListingDTO] {
        struct Wrap: Decodable { let items: [ListingDTO] }
        let w: Wrap = try await request("favorites", authorized: true)
        return w.items
    }

    func addFavorite(listingId: String) async throws {
        _ = try await request("favorites/\(listingId)", method: "POST",
                              authorized: true) as EmptyResponse
    }

    func removeFavorite(listingId: String) async throws {
        _ = try await request("favorites/\(listingId)", method: "DELETE",
                              authorized: true) as EmptyResponse
    }

    // MARK: - Photo uploads

    struct UploadedPhoto: Decodable {
        let url: String
        let publicId: String
        let width: Int?
        let height: Int?
    }

    /// Upload one or more image blobs to Cloudinary via our backend proxy.
    /// Order is preserved: `items[i]` corresponds to `photos[i]`, so the
    /// caller can drop the returned URLs straight into `Listing.photos`.
    /// Each blob is sent as a JPEG under the multipart field name `photos`.
    func uploadOwnerPhotos(_ photos: [Data]) async throws -> [UploadedPhoto] {
        guard !photos.isEmpty else { return [] }
        let boundary = "Mobly-\(UUID().uuidString)"
        var body = Data()

        // Build the multipart body by hand — no third-party dep, and the
        // existing `request(...)` helper only knows JSON. Each part carries
        // the same field name ("photos") so multer/express reads them as an
        // array (upload.array('photos', 30)).
        for (i, jpeg) in photos.enumerated() {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"photos\"; filename=\"photo-\(i).jpg\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
            body.append(jpeg)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: baseURL.appendingPathComponent("uploads/photos"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        // Cloudinary round-trip + network — bump the timeouts so a slower
        // Douala connection doesn't kill a legitimate multi-photo upload.
        req.timeoutInterval = 90
        req.httpBody = body

        let (data, resp) = try await session.upload(for: req, from: body)
        guard let http = resp as? HTTPURLResponse else {
            throw APIError(status: 0, code: .unknown, message: "Upload failed",
                           requestId: nil, fields: [:])
        }
        if !(200..<300).contains(http.statusCode) {
            struct ErrBody: Decodable { let error: String? }
            let parsed = try? decoder.decode(ErrBody.self, from: data)
            throw APIError(status: http.statusCode, code: .unknown,
                           message: parsed?.error ?? "Upload failed (\(http.statusCode))",
                           requestId: nil, fields: [:])
        }
        struct Wrap: Decodable { let items: [UploadedPhoto] }
        let w = try decoder.decode(Wrap.self, from: data)
        return w.items
    }

    /// Upload the signed-in user's avatar. One image, field name `avatar`.
    /// Returns the new secure_url; also persisted to the User row server-side.
    func uploadAvatar(_ jpeg: Data) async throws -> String {
        let boundary = "Mobly-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"avatar\"; filename=\"avatar.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(jpeg)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: baseURL.appendingPathComponent("uploads/avatar"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.timeoutInterval = 60
        req.httpBody = body

        let (data, resp) = try await session.upload(for: req, from: body)
        guard let http = resp as? HTTPURLResponse else {
            throw APIError(status: 0, code: .unknown, message: "Upload failed",
                           requestId: nil, fields: [:])
        }
        if !(200..<300).contains(http.statusCode) {
            struct ErrBody: Decodable { let error: String? }
            let parsed = try? decoder.decode(ErrBody.self, from: data)
            throw APIError(status: http.statusCode, code: .unknown,
                           message: parsed?.error ?? "Upload failed (\(http.statusCode))",
                           requestId: nil, fields: [:])
        }
        struct Wrap: Decodable { let avatarUrl: String }
        return try decoder.decode(Wrap.self, from: data).avatarUrl
    }

    // MARK: - Owner

    func myAnnonces() async throws -> [ListingDTO] {
        struct Wrap: Decodable { let items: [ListingDTO] }
        let w: Wrap = try await request("owner/annonces", authorized: true)
        return w.items
    }

    func boost(listingId: String, days: Int) async throws -> ListingDTO {
        struct Wrap: Decodable { let listing: ListingDTO }
        let w: Wrap = try await request("boost/\(listingId)", method: "POST",
                                        body: ["days": days], authorized: true)
        return w.listing
    }

    // MARK: - Visit requests

    func requestVisit(listingId: String, scheduledAt: Date,
                      note: String? = nil) async throws -> VisitRequestDTO {
        struct Body: Encodable { let scheduledAt: String; let note: String? }
        struct Wrap: Decodable { let visit: VisitRequestDTO }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let w: Wrap = try await request(
            "listings/\(listingId)/visits", method: "POST",
            body: Body(scheduledAt: iso.string(from: scheduledAt), note: note),
            authorized: true
        )
        return w.visit
    }

    func inviteVisit(listingId: String, visitorId: String, scheduledAt: Date,
                     note: String? = nil) async throws -> VisitRequestDTO {
        struct Body: Encodable { let visitorId: String; let scheduledAt: String; let note: String? }
        struct Wrap: Decodable { let visit: VisitRequestDTO }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let w: Wrap = try await request(
            "listings/\(listingId)/visits/invite", method: "POST",
            body: Body(visitorId: visitorId, scheduledAt: iso.string(from: scheduledAt), note: note),
            authorized: true
        )
        return w.visit
    }

    func ownerVisits() async throws -> [VisitRequestDTO] {
        struct Wrap: Decodable { let items: [VisitRequestDTO] }
        let w: Wrap = try await request("owner/visits", authorized: true)
        return w.items
    }

    func myVisits() async throws -> [VisitRequestDTO] {
        struct Wrap: Decodable { let items: [VisitRequestDTO] }
        let w: Wrap = try await request("me/visits", authorized: true)
        return w.items
    }

    func updateVisit(id: String, status: String? = nil, scheduledAt: Date? = nil,
                     note: String? = nil) async throws -> VisitRequestDTO {
        struct Body: Encodable { let status: String?; let scheduledAt: String?; let note: String? }
        struct Wrap: Decodable { let visit: VisitRequestDTO }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let w: Wrap = try await request(
            "visits/\(id)", method: "PATCH",
            body: Body(
                status: status,
                scheduledAt: scheduledAt.map { iso.string(from: $0) },
                note: note
            ),
            authorized: true
        )
        return w.visit
    }
}

// MARK: - DTOs (match the backend serializers)

struct EmptyResponse: Decodable {}

struct OTPRequestResponse: Decodable {
    let sent: Bool
    let devCode: String?   // present only when the server runs in dev mode
}

struct AuthResponse: Decodable {
    let token: String
    let refreshToken: String?
    let refreshExpiresAt: Date?
    let user: UserDTO
}

struct UserDTO: Decodable, Identifiable {
    let id: String
    let phone: String
    let fullName: String
    let email: String?
    let isOwner: Bool
    let verified: Bool
    /// Pièce d'identité contrôlée par Didit — distinct from `verified`, which
    /// only means the phone number was confirmed. Optional so the locally
    /// hand-built UserDTO JSON (avatar refresh, DEBUG fixtures) still decodes.
    let identityVerified: Bool?
    /// Set from the device location, not typed by the user.
    let city: String?
    let region: String?
    let rating: Double?
    let avatarUrl: String?
    /// Personal accent colour picked by the user. Nil = use the deterministic
    /// palette fallback (`AvatarPalette.color(for:)`).
    let avatarColor: String?
    /// True for the small handful of accounts with the Mobly admin flag. Gates
    /// the entry point to AdminDashboardView on the Profile screen.
    let isAdmin: Bool?
}

struct IdentitySessionDTO: Decodable {
    let checkId: String
    /// Provider-hosted verification page. Single use — never cache it.
    let url: String
    let status: String
}

struct IdentityStatusDTO: Decodable {
    let identityVerified: Bool
    let verifiedAt: Date?
    /// NONE · PENDING · IN_REVIEW · APPROVED · DECLINED · ABANDONED
    let status: String
    /// Why a check was refused, when the provider says. Shown to the user.
    let reason: String?
}

struct ListingDTO: Codable, Identifiable {
    let id: String
    let title: String
    let category: String
    let deal: String?
    let deals: [String]
    let city: String
    let neighborhood: String?
    let region: String?
    let location: String
    let priceFcfa: Int
    let price: String
    let priceUnit: String?
    let furnished: Bool
    let rooms: Int
    let subtitle: String
    let about: String
    let rating: Double?
    let reviewCount: Int
    let verified: Bool
    let tags: [String]
    let coverUrl: String?
    let imageName: String?
    let photos: [String]?
    let available: Bool
    let status: String
    let boosted: Bool
    let views: Int
    let contacts: Int
    let favorites: Int
    let boostDaysLeft: Int?
    let lat: Double?
    let lng: Double?
    let owner: OwnerRef?

    struct OwnerRef: Codable {
        let id: String
        let fullName: String
        let verified: Bool
        let avatarUrl: String?
    }
}

struct VisitRequestDTO: Codable, Identifiable {
    let id: String
    let listingId: String
    let listing: VisitListingRef?
    let visitorId: String
    let visitor: VisitPersonRef?
    let ownerId: String
    let owner: VisitPersonRef?
    let scheduledAt: Date
    let status: String       // REQUESTED | CONFIRMED | CANCELLED | COMPLETED | NO_SHOW
    let note: String?
    let createdAt: Date
    let updatedAt: Date

    struct VisitListingRef: Codable {
        let id: String
        let title: String
        let imageName: String?
        let coverUrl: String?
        let priceFcfa: Int
        let neighborhood: String?
        let city: String?
        let ownerId: String
    }
    struct VisitPersonRef: Codable {
        let id: String
        let fullName: String?
        let avatarUrl: String?
        let phone: String?
        let verified: Bool
    }
}

/// Type-erasing wrapper so `Encodable` bodies can be JSON-encoded.
private struct AnyEncodable: Encodable {
    private let encodeFunc: (Encoder) throws -> Void
    init(_ wrapped: Encodable) { encodeFunc = wrapped.encode }
    func encode(to encoder: Encoder) throws { try encodeFunc(encoder) }
}
