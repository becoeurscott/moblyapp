import Foundation
import SwiftUI

/// The app's view of its own remotely-controlled configuration.
///
/// Mirrors `GET /config` on the backend: which features are on, the numeric
/// limits, the editable copy, and the minimum supported build. An operator
/// changes any of it from the admin dashboard and the app follows, without a
/// release.
///
/// Three properties make this safe to depend on:
///
/// 1. **It never blocks the app.** Every field has a default equal to the
///    behaviour that shipped, so a failed fetch, a cold launch, or an offline
///    device all leave the app fully usable. Failure means "everything works",
///    never "nothing works".
/// 2. **It is advisory, not authoritative.** The server enforces every one of
///    these rules independently. What lives here only decides whether a control
///    is *offered* — so a stale config can't unlock anything, it can only show
///    a button that then fails with the server's own explanation.
/// 3. **It updates live.** A socket `config` event triggers a refetch, so a
///    switch flipped in the dashboard lands in about a second. The launch,
///    foreground and periodic fetches are the fallback for a dropped socket.
@MainActor
final class RemoteConfigStore: ObservableObject {
    static let shared = RemoteConfigStore()

    @Published private(set) var config: RemoteConfig = .fallback
    /// Restrictions on *this* account, keyed by kind. Refreshed from
    /// `GET /auth/me` and by socket `restriction` events.
    @Published private(set) var restrictions: [String: RestrictionInfo] = [:]

    /// Set when the build is below the configured minimum. Drives a blocking
    /// cover — nothing else in the app will work until the user updates.
    @Published private(set) var update: ForceUpdate?

    /// The most recent refusal from the server, shown as a transient banner.
    /// Carries the operator's own French wording.
    @Published var blockedMessage: String?

    private let api = MoblyAPI.shared
    private var poller: Task<Void, Never>?
    /// Guards against two refreshes racing on launch + foreground.
    private var inFlight = false

    private init() {
        restoreCached()
    }

    // MARK: - Reading

    /// Is a feature available? Unknown keys read as enabled — a flag the server
    /// has but this build doesn't know must not disable anything.
    func isEnabled(_ flag: String) -> Bool {
        config.flags[flag]?.enabled ?? true
    }

    /// Why a feature is unavailable, in the operator's words.
    func message(for flag: String) -> String {
        config.flags[flag]?.message
            ?? config.copy.featureDisabledMessage
            ?? "Cette fonctionnalité est temporairement indisponible."
    }

    func restriction(_ kind: String) -> RestrictionInfo? { restrictions[kind] }
    func isRestricted(_ kind: String) -> Bool { restrictions[kind] != nil }

    /// One call for the common "may the user do this?" question, covering the
    /// global switch and the personal block together.
    ///
    /// Returns false *and* raises the banner, so a caller can write
    /// `guard config.can("chat.send", "MESSAGE_SEND") else { return }` and the
    /// user still learns why nothing happened.
    @discardableResult
    func can(_ flag: String, _ restrictionKind: String? = nil) -> Bool {
        if !isEnabled(flag) {
            report(blocked: message(for: flag))
            return false
        }
        if let kind = restrictionKind, let hit = restrictions[kind] {
            report(blocked: hit.reason)
            return false
        }
        return true
    }

    /// Silent variant, for deciding whether to *render* a control. Showing a
    /// banner while a view is merely laying out would be wrong.
    func allows(_ flag: String, _ restrictionKind: String? = nil) -> Bool {
        guard isEnabled(flag) else { return false }
        if let kind = restrictionKind { return restrictions[kind] == nil }
        return true
    }

    // MARK: - Signals from the network layer

    func report(blocked message: String) {
        blockedMessage = message
    }

    func forceUpdate(message: String, storeUrl: String?) {
        update = ForceUpdate(message: message, storeUrl: storeUrl)
    }

    /// Applied from a socket `restriction` event, so a block or a lift lands
    /// while the user is looking at the screen.
    func apply(kind: String, active: Bool, reason: String?, expiresAt: String?) {
        if active {
            restrictions[kind] = RestrictionInfo(
                kind: kind,
                reason: reason ?? "Action indisponible sur votre compte.",
                expiresAt: expiresAt
            )
        } else {
            restrictions.removeValue(forKey: kind)
        }
    }

    /// Replaces the whole set — used after `GET /auth/me`, which is the source
    /// of truth. Assigning wholesale (rather than merging) is what lets a
    /// restriction that expired server-side disappear here.
    func replaceRestrictions(_ list: [RestrictionInfo]) {
        restrictions = Dictionary(uniqueKeysWithValues: list.map { ($0.kind, $0) })
    }

    func clearRestrictions() { restrictions = [:] }

    // MARK: - Fetching

    func checkAtLaunch() async {
        await refresh()
        startPolling()
    }

    func refresh() async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        do {
            let fresh: RemoteConfig = try await api.request("config", authorized: false, retries: 0)
            config = fresh
            cache(fresh)
            checkVersion(against: fresh)
        } catch {
            // Deliberately silent. A configuration fetch that fails must not
            // interrupt the user — the last good copy (or the shipped
            // defaults) stays in force and the next poll tries again.
        }
    }

    /// Compare this build against the configured floor.
    private func checkVersion(against cfg: RemoteConfig) {
        guard let min = cfg.versions?.ios?.min, min != "0.0.0" else {
            update = nil
            return
        }
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        if compare(current, min) < 0 {
            update = ForceUpdate(
                message: cfg.versions?.ios?.forceMessage
                    ?? "Une nouvelle version de Mobly est nécessaire pour continuer.",
                storeUrl: cfg.versions?.ios?.storeUrl
            )
        } else {
            update = nil
        }
    }

    /// Numeric dotted-version compare, so "1.10.0" ranks above "1.9.9" —
    /// a string comparison gets that backwards.
    private func compare(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    /// Fallback for a dropped socket. Deliberately slow — the socket `config`
    /// event is the fast path, this only catches the case where it is gone.
    private func startPolling() {
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                await self?.refresh()
            }
        }
    }

    // MARK: - Disk cache
    //
    // Persisted so a cold launch on a bad connection starts from the last
    // known configuration rather than from the shipped defaults — otherwise a
    // feature an operator turned off would flicker back on at every launch.

    private var cacheURL: URL? {
        try? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask,
                 appropriateFor: nil, create: true)
            .appendingPathComponent("remote-config.json")
    }

    private func cache(_ cfg: RemoteConfig) {
        guard let url = cacheURL, let data = try? JSONEncoder().encode(cfg) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func restoreCached() {
        guard let url = cacheURL,
              let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(RemoteConfig.self, from: data)
        else { return }
        config = cfg
    }
}

// MARK: - Wire shapes

struct ForceUpdate: Equatable {
    let message: String
    let storeUrl: String?
}

struct RestrictionInfo: Codable, Equatable {
    let kind: String
    let reason: String
    let expiresAt: String?
}

/// Mirror of the backend's public configuration document.
///
/// Every field is optional with a default. A build that predates a new section
/// keeps decoding, and a section the server stops sending falls back rather
/// than failing the whole payload — which would take the config channel down
/// exactly when it is needed to fix something.
struct RemoteConfig: Codable, Equatable {
    struct Flag: Codable, Equatable {
        var enabled: Bool = true
        var message: String?
    }

    struct Limits: Codable, Equatable {
        var maxPhotosPerListing: Int = 30
        var maxListingsPerOwner: Int = 50
        var priceMinFcfa: Int = 0
        var priceMaxFcfa: Int = 500_000_000
        var titleMaxLength: Int = 120
        var aboutMaxLength: Int = 5_000
        var messageMaxLength: Int = 4_000
        var reviewMinChars: Int = 0
        var reviewMaxChars: Int = 2_000
        var visitNoteMaxLength: Int = 500
        var visitMinHoursAhead: Int = 0
        var favoritesMax: Int = 1_000
        var searchResultsMax: Int = 100
    }

    struct Banner: Codable, Equatable {
        var enabled: Bool = false
        var title: String?
        var body: String?
        var text: String?
        var level: String?
        var ctaLabel: String?
        var ctaUrl: String?
        var url: String?
    }

    struct Copy: Codable, Equatable {
        var featureDisabledMessage: String?
        var suspendedMessage: String?
        var signupClosedMessage: String?
        var homeBanner: Banner?
        var announcementBar: Banner?
        var supportEmail: String?
        var supportWhatsapp: String?
    }

    struct IOSVersions: Codable, Equatable {
        var min: String?
        var latest: String?
        var storeUrl: String?
        var forceMessage: String?
    }

    struct Versions: Codable, Equatable {
        var ios: IOSVersions?
    }

    struct BoostPlan: Codable, Equatable, Identifiable {
        var id: String
        var days: Int
        var priceFcfa: Int
        var label: String
        var popular: Bool = false
    }

    struct Boost: Codable, Equatable {
        var plans: [BoostPlan] = []
    }

    struct Geo: Codable, Equatable {
        var allowedCities: [String] = []
        var defaultCity: String?
    }

    var version: Int = 0
    var flags: [String: Flag] = [:]
    var limits: Limits = Limits()
    var copy: Copy = Copy()
    var versions: Versions?
    var boost: Boost?
    var geo: Geo?

    /// Everything on, today's numbers — the state the app shipped in.
    static let fallback = RemoteConfig()
}
