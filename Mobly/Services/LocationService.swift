import Foundation
import CoreLocation
import Combine
import UIKit
import SwiftUI

/// Device location → city name, plus an approximate position for "près de
/// vous".
///
/// Only the **city** is ever persisted (on the profile). The position lives in
/// memory for this launch only, rounded to ~1 km — enough to rank the nearest
/// annonces, never saved, never sent anywhere but the feed query.
///
/// While the app is in the foreground the position is *followed*
/// (`startTracking`), not read once: someone opening Mobly in Akwa and again in
/// Bonamoussadi an hour later must see what's near them now. Tracking stops in
/// the background — "when in use" is all we ask for.
@MainActor
final class LocationService: NSObject, ObservableObject {
    static let shared = LocationService()

    enum Status { case unknown, denied, resolving, resolved }

    @Published private(set) var status: Status = .unknown
    /// Localised city, e.g. "Douala". Nil until resolved or if refused.
    @Published private(set) var city: String?
    /// ISO country code of the resolved position, e.g. "CM". Nil until
    /// resolved or refused. Lets the feed tell an in-market user from someone
    /// browsing from abroad, for whom "près de chez vous" means nothing.
    @Published private(set) var countryCode: String?
    @Published private(set) var region: String?

    /// Rounded (~1 km) position of the device, in memory only. Nil until a fix
    /// arrives or when permission is refused.
    struct Approx: Equatable { let lat: Double; let lng: Double }
    @Published private(set) var approximate: Approx?
    /// Exact position, for on-device use only (centring the map on the user,
    /// sorting the cards around them). Never sent anywhere — anything that
    /// leaves the phone uses `approximate`.
    @Published private(set) var precise: Approx?

    /// Current permission, republished so screens can ask for it.
    @Published private(set) var authorization: CLAuthorizationStatus

    /// The system prompt can still be shown.
    var canAskPermission: Bool { authorization == .notDetermined }
    /// Refused or restricted: only Réglages can turn it back on.
    var isDenied: Bool { authorization == .denied || authorization == .restricted }
    var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    /// Following the position (foreground) vs idle (background).
    private var tracking = false
    /// Where the city was last looked up. The geocoder is rate-limited, so a
    /// new lookup only happens after a real move, not on every fix.
    private var lastGeocoded: CLLocation?
    private static let regeocodeAfterMeters: CLLocationDistance = 2_000
    /// Callbacks waiting on a one-shot precise fix (chat "Position" attachment).
    /// The coordinate is delivered to each and then dropped — never stored.
    private var oneShotWaiters: [(CLLocationCoordinate2D?) -> Void] = []
    private var oneShotPending = false

    private override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        applyTrackingAccuracy()
    }

    /// City-level accuracy and a few hundred metres between updates: enough to
    /// notice a change of quartier, cheap on battery.
    private func applyTrackingAccuracy() {
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 300
    }

    // MARK: - Tracking

    /// Start following the position — called on launch and every return to the
    /// foreground. Safe to call repeatedly.
    ///
    /// Never asks for permission. The iOS dialog only ever appears after the
    /// user taps the button on one of Mobly's own location screens
    /// (`askForPermission`, `askThroughPrimer`): asked out of the blue, it
    /// spends iOS's one prompt before the user knows what it's for.
    func startTracking() {
        authorization = manager.authorizationStatus
        switch authorization {
        case .notDetermined:
            break
        case .denied, .restricted:
            status = .denied
        case .authorizedWhenInUse, .authorizedAlways:
            if city == nil { status = .resolving }
            tracking = true
            applyTrackingAccuracy()
            manager.startUpdatingLocation()
        @unknown default:
            break
        }
    }

    /// Stop following — the app went to the background.
    func stopTracking() {
        tracking = false
        manager.stopUpdatingLocation()
    }

    /// Kept for existing callers: starting to track is the request.
    func requestIfNeeded() { startTracking() }

    /// Ask again from an in-app prompt: the system dialog while it can still
    /// appear, otherwise Réglages, the only place a refusal can be undone.
    func askForPermission() {
        if canAskPermission {
            manager.requestWhenInUseAuthorization()
        } else if isDenied, let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Mobly's own location screen

    private let grantedBeforeKey = "location.grantedBefore"
    private let reofferSnoozeKey = "location.reofferSnoozedUntil"

    /// Granted at some point, yet iOS can ask again: the user picked "Allow
    /// Once" last time (a "While Using" answer would have stuck). They said
    /// yes once, so Mobly offers its location screen again before Home —
    /// unless they said "Plus tard" to it within the last day.
    var shouldReofferAtLaunch: Bool {
        guard manager.authorizationStatus == .notDetermined,
              UserDefaults.standard.bool(forKey: grantedBeforeKey) else { return false }
        let until = UserDefaults.standard.double(forKey: reofferSnoozeKey)
        return Date().timeIntervalSince1970 >= until
    }

    func snoozeReoffer() {
        UserDefaults.standard.set(Date().addingTimeInterval(24 * 3600).timeIntervalSince1970,
                                  forKey: reofferSnoozeKey)
    }

    private var primerContinuation: CheckedContinuation<Bool, Never>?

    /// For actions that need the position (share it in chat, centre the map,
    /// pin a listing): when iOS hasn't been asked yet, show Mobly's location
    /// screen first and let the user decide there. Returns whether location
    /// is allowed afterwards.
    func askThroughPrimer() async -> Bool {
        authorization = manager.authorizationStatus
        guard authorization == .notDetermined else { return isAuthorized }
        guard primerContinuation == nil, let top = Self.topViewController() else { return false }
        return await withCheckedContinuation { cont in
            primerContinuation = cont
            let host = UIHostingController(rootView: LocationPrimerScreen(context: .action) { [weak self] granted in
                top.presentedViewController?.dismiss(animated: true)
                self?.primerContinuation?.resume(returning: granted)
                self?.primerContinuation = nil
            }
            .environment(\.locale, Locale(identifier: AppLang.shared.code)))
            host.modalPresentationStyle = .fullScreen
            top.present(host, animated: true)
        }
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    // MARK: - One-shot precise fix

    /// Fetch a fresh, precise coordinate for sharing in chat. Not persisted.
    /// Returns nil when permission is denied or no fix is available.
    func requestOneShotCoordinate() async -> CLLocationCoordinate2D? {
        if manager.authorizationStatus == .notDetermined {
            guard await askThroughPrimer() else { return nil }
        }
        return await withCheckedContinuation { cont in
            switch manager.authorizationStatus {
            case .denied, .restricted:
                cont.resume(returning: nil)
            case .notDetermined:
                cont.resume(returning: nil)
            case .authorizedWhenInUse, .authorizedAlways:
                oneShotWaiters.append { cont.resume(returning: $0) }
                oneShotPending = true
                // Tracking runs at ~100 m and ignores small moves; a shared
                // position must be exact and fresh, so switch modes until the
                // fix lands, then go back.
                manager.stopUpdatingLocation()
                manager.desiredAccuracy = kCLLocationAccuracyBest
                manager.distanceFilter = kCLDistanceFilterNone
                manager.requestLocation()
            @unknown default:
                cont.resume(returning: nil)
            }
        }
    }

    private func resolveOneShot(_ coord: CLLocationCoordinate2D?) {
        guard oneShotPending else { return }
        oneShotPending = false
        let waiters = oneShotWaiters
        oneShotWaiters.removeAll()
        waiters.forEach { $0(coord) }
        applyTrackingAccuracy()
        if tracking { manager.startUpdatingLocation() }
    }

    // MARK: - Position → city

    private func handle(_ location: CLLocation) {
        let c = location.coordinate
        let exact = Approx(lat: c.latitude, lng: c.longitude)
        if exact != precise { precise = exact }
        let approx = Approx(lat: (c.latitude * 100).rounded() / 100,
                            lng: (c.longitude * 100).rounded() / 100)
        if approx != approximate { approximate = approx }

        if city == nil || lastGeocoded.map({ location.distance(from: $0) >= Self.regeocodeAfterMeters }) ?? true {
            lastGeocoded = location
            reverseGeocode(location)
        }
    }

    private func reverseGeocode(_ location: CLLocation) {
        geocoder.cancelGeocode()
        geocoder.reverseGeocodeLocation(location) { [weak self] places, _ in
            Task { @MainActor in
                guard let self else { return }
                guard let place = places?.first else {
                    // A failed lookup must not wipe a city we already had.
                    if self.city == nil { self.status = .denied }
                    return
                }
                // `locality` is the city; fall back to the wider area for
                // places that don't report one.
                let city = place.locality ?? place.subAdministrativeArea ?? place.administrativeArea
                if let city { self.city = city }
                self.region = place.administrativeArea
                self.countryCode = place.isoCountryCode
                self.status = self.city == nil ? .denied : .resolved

                if let city {
                    await self.syncToProfile(city: city, region: self.region)
                }
            }
        }
    }

    /// Persist the city on the account so it shows on the profile and survives
    /// reinstalls. Best-effort: a failure here must never block the app.
    private func syncToProfile(city: String, region: String?) async {
        guard MoblyAPI.shared.isAuthenticated else { return }
        // Don't spend a request when nothing changed.
        guard AuthStore.shared.user?.city != city else { return }
        struct Body: Encodable { let city: String; let region: String? }
        _ = try? await MoblyAPI.shared.request(
            "auth/me", method: "PATCH", body: Body(city: city, region: region), authorized: true
        ) as EmptyResponse
        await AuthStore.shared.bootstrap()
    }
}

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.authorization = manager.authorizationStatus
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                UserDefaults.standard.set(true, forKey: self.grantedBeforeKey)
                // Granted (first time, or back from Réglages): follow now —
                // unless the app is in the background, where we don't track.
                if UIApplication.shared.applicationState != .background { self.startTracking() }
                if self.oneShotPending { manager.requestLocation() }
            case .denied, .restricted:
                self.status = .denied
                self.approximate = nil
                self.precise = nil
                self.stopTracking()
                self.resolveOneShot(nil)
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.resolveOneShot(location.coordinate)
            self.handle(location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        Task { @MainActor in
            self.resolveOneShot(nil)
            // No fix available (common indoors, or in the simulator with no
            // location set) — leave the city unknown rather than guessing.
            if self.city == nil { self.status = .denied }
        }
    }
}
