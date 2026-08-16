import Foundation
import CoreLocation
import Combine

/// Device location → city name.
///
/// Only the **city** is ever kept. The coordinate is used to reverse-geocode
/// and then discarded — storing a precise position for every user would be
/// collecting far more than the feature needs, and it's the kind of data that
/// becomes a liability the moment the database leaks.
@MainActor
final class LocationService: NSObject, ObservableObject {
    static let shared = LocationService()

    enum Status { case unknown, denied, resolving, resolved }

    @Published private(set) var status: Status = .unknown
    /// Localised city, e.g. "Douala". Nil until resolved or if refused.
    @Published private(set) var city: String?
    @Published private(set) var region: String?

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    /// Set once per launch so a permission change doesn't re-geocode in a loop.
    private var resolving = false
    /// Callbacks waiting on a one-shot precise fix (chat "Position" attachment).
    /// The coordinate is delivered to each and then dropped — never stored.
    private var oneShotWaiters: [(CLLocationCoordinate2D?) -> Void] = []
    private var oneShotPending = false

    private override init() {
        super.init()
        manager.delegate = self
        // City-level is all we need, and it's dramatically cheaper on battery
        // than the default best-accuracy fix.
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Ask for permission and resolve the city.
    ///
    /// Safe to call repeatedly — it no-ops once permission is settled, so it
    /// can hang off app launch without nagging on every foreground.
    func requestIfNeeded() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            status = .denied
        case .authorizedWhenInUse, .authorizedAlways:
            resolve()
        @unknown default:
            break
        }
    }

    private func resolve() {
        guard !resolving, city == nil else { return }
        resolving = true
        status = .resolving
        manager.requestLocation()
    }

    /// Fetch a fresh, precise coordinate for sharing in chat. Not persisted.
    /// Returns nil when permission is denied or no fix is available.
    func requestOneShotCoordinate() async -> CLLocationCoordinate2D? {
        await withCheckedContinuation { cont in
            switch manager.authorizationStatus {
            case .denied, .restricted:
                cont.resume(returning: nil)
            case .notDetermined:
                oneShotWaiters.append { cont.resume(returning: $0) }
                oneShotPending = true
                manager.requestWhenInUseAuthorization()
            case .authorizedWhenInUse, .authorizedAlways:
                oneShotWaiters.append { cont.resume(returning: $0) }
                oneShotPending = true
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
    }

    private func reverseGeocode(_ location: CLLocation) {
        geocoder.reverseGeocodeLocation(location) { [weak self] places, _ in
            Task { @MainActor in
                guard let self else { return }
                self.resolving = false
                guard let place = places?.first else {
                    self.status = .denied
                    return
                }
                // `locality` is the city; fall back to the wider area for
                // places that don't report one.
                self.city = place.locality
                    ?? place.subAdministrativeArea
                    ?? place.administrativeArea
                self.region = place.administrativeArea
                self.status = self.city == nil ? .denied : .resolved

                if let city = self.city {
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
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                self.resolve()
                if self.oneShotPending { manager.requestLocation() }
            case .denied, .restricted:
                self.status = .denied
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
            self.reverseGeocode(location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        Task { @MainActor in
            self.resolving = false
            self.resolveOneShot(nil)
            // No fix available (common indoors, or in the simulator with no
            // location set) — leave the city unknown rather than guessing.
            if self.city == nil { self.status = .denied }
        }
    }
}
