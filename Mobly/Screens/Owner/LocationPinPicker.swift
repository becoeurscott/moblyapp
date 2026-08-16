import SwiftUI
import MapKit

/// Full-screen MapKit picker: drop a pin on the exact building the listing
/// is in. Presented after the user has chosen région / ville / quartier so
/// the map opens already centered on that quartier — zoomed tight enough that
/// the user only has a couple of streets to nudge across, not a whole city.
///
/// Uses a `UIViewRepresentable` bridge to `MKMapView` because SwiftUI's own
/// `Map` doesn't expose satellite / hybrid types the way we want, and doesn't
/// let us tilt the camera 45° into a proper 3D view.
struct LocationPinPicker: View {
    /// Fallback centre when no better one is known — usually the ville
    /// centroid. Used before the geocoder returns, and if the geocoder fails.
    let initial: CLLocationCoordinate2D
    /// Pre-existing pin, when the user is editing an already-placed listing.
    let existing: CLLocationCoordinate2D?
    /// Free-text location the user just picked ("Ekounou, Yaoundé"). Fed to
    /// `CLGeocoder` on appear so the map opens centred on the actual quartier
    /// instead of a coarse ville centroid.
    let searchQuery: String?
    var onConfirm: (CLLocationCoordinate2D) -> Void
    var onCancel: () -> Void

    @State private var pin: CLLocationCoordinate2D
    @State private var mapType: MKMapType
    @State private var is3D = false
    @StateObject private var here = HereLocation()
    /// Bumped whenever we want the MKMapView bridge to recentre — the pin
    /// binding alone doesn't trigger a camera move.
    @State private var recentreTick = 0
    /// True while the initial geocode is in flight. The map is hidden behind
    /// a loading veil until we know where to point the camera, so the user
    /// never sees a quick jump from the ville centroid to the quartier.
    @State private var isGeocoding = false
    @State private var didFirstReveal = false
    @State private var veilSpin = false

    init(initial: CLLocationCoordinate2D,
         existing: CLLocationCoordinate2D? = nil,
         searchQuery: String? = nil,
         onConfirm: @escaping (CLLocationCoordinate2D) -> Void,
         onCancel: @escaping () -> Void) {
        self.initial = initial
        self.existing = existing
        self.searchQuery = searchQuery
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _pin = State(initialValue: existing ?? initial)
        _mapType = State(initialValue: .hybridFlyover)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            MapPickerContainer(
                pin: $pin,
                mapType: mapType,
                is3D: is3D,
                initial: initial,
                recentreTick: recentreTick
            )
            .ignoresSafeArea()
            .opacity(didFirstReveal ? 1 : 0.35)
            .animation(.easeInOut(duration: 0.35), value: didFirstReveal)

            // Fixed centered pin — the map moves under it, giving the same
            // familiar "drag the map to move the pin" behaviour Apple Maps
            // and Uber use.
            VStack(spacing: 0) {
                Spacer()
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(Color.moblyAccent)
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 4)
                    .offset(y: -18) // point aligns with the geographic centre
                Spacer()
                Spacer()
            }
            .allowsHitTesting(false)

            topBar
            controlColumn
            confirmBar

            if !didFirstReveal {
                loadingVeil
                    .transition(.opacity)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task {
            here.request()
            if existing == nil, let q = searchQuery,
               !q.trimmingCharacters(in: .whitespaces).isEmpty {
                await centerOnQuery(q)
            }
            // Reveal even if the geocoder failed — the veil is a "we're
            // pointing the camera at the right thing" moment, not a hard
            // requirement to have a resolved pin.
            withAnimation(.easeInOut(duration: 0.35)) { didFirstReveal = true }
        }
    }

    private var loadingVeil: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()

            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.14), lineWidth: 5)
                        .frame(width: 68, height: 68)
                    Circle()
                        .trim(from: 0, to: 0.72)
                        .stroke(Color.moblyAccent,
                                style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .frame(width: 68, height: 68)
                        .rotationEffect(.degrees(veilSpin ? 360 : 0))
                        .animation(.linear(duration: 1.1).repeatForever(autoreverses: false),
                                   value: veilSpin)
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.moblyAccent)
                }
                VStack(spacing: 6) {
                    Text("Chargement de la zone…")
                        .font(.moblyHeading(15))
                        .foregroundStyle(.white)
                    if let q = searchQuery, !q.isEmpty {
                        Text(LT(q))
                            .font(.moblyBody(12.5))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                }
            }
        }
        .onAppear { veilSpin = true }
    }

    /// Geocode a free-text location and, if it resolves, move the pin +
    /// camera to it. Silent on failure — we keep the ville centroid.
    private func centerOnQuery(_ q: String) async {
        isGeocoding = true
        defer { isGeocoding = false }
        let coder = CLGeocoder()
        let biased = q.contains("Cameroun") ? q : "\(q), Cameroun"
        let placemark = try? await coder.geocodeAddressString(biased).first
        guard let coord = placemark?.location?.coordinate else { return }
        pin = coord
        recentreTick += 1
    }

    // MARK: Top bar (Cancel)

    private var topBar: some View {
        VStack {
            HStack {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(.black.opacity(0.55)))
                }
                Spacer()
                Text("Placez la punaise")
                    .font(.moblyHeading(15))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Capsule().fill(.black.opacity(0.55)))
                Spacer()
                Color.clear.frame(width: 42, height: 42)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            Spacer()
        }
    }

    // MARK: Right-edge controls (satellite ↔ standard, 3D toggle)

    private var controlColumn: some View {
        VStack {
            Spacer(minLength: 0).frame(height: 90)
            HStack {
                Spacer()
                VStack(spacing: 10) {
                    controlButton(icon: mapType == .standard ? "globe.europe.africa.fill" : "map",
                                  label: mapType == .standard ? "Satellite" : "Standard") {
                        mapType = (mapType == .standard) ? .hybridFlyover : .standard
                    }
                    controlButton(icon: is3D ? "view.2d" : "view.3d",
                                  label: is3D ? "2D" : "3D") {
                        is3D.toggle()
                    }
                    controlButton(icon: "location.north.line.fill", label: "Ma\nposition") {
                        // Snap to the device's current location if we have it.
                        // If not, kick off a fresh request — the user is
                        // making it clear they want to try again.
                        if let c = here.coordinate {
                            pin = c
                            recentreTick += 1
                        } else {
                            here.request()
                        }
                    }
                    controlButton(icon: "building.2.fill", label: "Ville") {
                        // Recentre on the initial ville centroid — bail-out
                        // when the user zoomed to another continent.
                        pin = initial
                        recentreTick += 1
                    }
                }
                .padding(.trailing, 14)
            }
            Spacer()
            Spacer(minLength: 0).frame(height: 200)
        }
    }

    private func controlButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                Text(LT(label)).font(.moblyBody(9, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(width: 54, height: 54)
            .background(Circle().fill(.black.opacity(0.55)))
        }
    }

    // MARK: Confirm bar (coord readout + Save button)

    private var confirmBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Image(systemName: "location.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.moblyAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Position choisie").font(.moblyBody(11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    Text(String(format: "%.5f, %.5f", pin.latitude, pin.longitude))
                        .font(.moblyBody(13, weight: .semibold))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                }
                Spacer()
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16).fill(.black.opacity(0.55)))

            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onConfirm(pin)
            } label: {
                HStack(spacing: 8) {
                    Text("Confirmer l'emplacement").font(.moblyHeading(15))
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 54)
                .background(Capsule().fill(Color.moblyAccent))
                .shadow(color: Color.moblyAccent.opacity(0.4), radius: 12, y: 6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 30)
    }
}

// MARK: - UIKit bridge

private struct MapPickerContainer: UIViewRepresentable {
    @Binding var pin: CLLocationCoordinate2D
    let mapType: MKMapType
    let is3D: Bool
    let initial: CLLocationCoordinate2D
    /// Bumped by the SwiftUI parent when it wants the camera to recentre on
    /// the current `pin` (e.g. after "Ma position" or "Ville" is tapped).
    let recentreTick: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsCompass = false
        map.showsScale = false
        map.showsUserLocation = true       // blue dot for the device position
        map.pointOfInterestFilter = .includingAll
        map.mapType = mapType
        // All standard MKMapView gestures on: single-tap does nothing (we
        // don't want the fixed pin to shift under a tap), pinch zooms,
        // double-tap zooms in, two-finger tap zooms out, pan drags.
        map.isPitchEnabled = true
        map.isRotateEnabled = true
        map.isZoomEnabled = true
        map.isScrollEnabled = true

        // Wide neighbourhood view (~6 km across) so the user can see all the
        // main streets and landmarks of the quartier at once. From here they
        // pinch in or double-tap to zoom to the exact building.
        let region = MKCoordinateRegion(
            center: pin,
            span: MKCoordinateSpan(latitudeDelta: 0.055, longitudeDelta: 0.055)
        )
        map.setRegion(region, animated: false)
        context.coordinator.lastTick = recentreTick
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        if map.mapType != mapType { map.mapType = mapType }

        // Explicit recentre from the parent (geocoder result, Ma position,
        // Ville). Wide enough that the user sees the whole neighbourhood
        // and its major streets — they then pinch in to zoom to the exact
        // building. Any tighter and the initial framing feels like a jail
        // cell that hides the surroundings they need to orient themselves.
        if context.coordinator.lastTick != recentreTick {
            context.coordinator.lastTick = recentreTick
            context.coordinator.isProgrammatic = true
            let cam = MKMapCamera(
                lookingAtCenter: pin,
                fromDistance: is3D ? 2200 : 4000,
                pitch: is3D ? 55 : 0,
                heading: map.camera.heading
            )
            map.setCamera(cam, animated: true)
        }

        let targetPitch: CGFloat = is3D ? 55 : 0
        if abs(map.camera.pitch - targetPitch) > 0.5 {
            let cam = MKMapCamera(
                lookingAtCenter: map.centerCoordinate,
                fromDistance: is3D ? 900 : 2000,
                pitch: targetPitch,
                heading: map.camera.heading
            )
            map.setCamera(cam, animated: true)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: MapPickerContainer
        var lastTick: Int = -1
        var isProgrammatic = false
        init(_ parent: MapPickerContainer) { self.parent = parent }
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            // Skip the sync when we caused the move ourselves — otherwise a
            // rebind would fight the animation.
            if isProgrammatic {
                isProgrammatic = false
                parent.pin = mapView.centerCoordinate
                return
            }
            parent.pin = mapView.centerCoordinate
        }
    }
}

// MARK: - Location fetch

/// Minimal one-shot location helper. Doesn't touch `LocationService.shared`
/// (which by design keeps only the reverse-geocoded city and discards the
/// coordinate) — the pin picker needs the raw fix.
@MainActor
final class HereLocation: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var coordinate: CLLocationCoordinate2D?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func request() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        default:
            break
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse
            || manager.authorizationStatus == .authorizedAlways {
            manager.requestLocation()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in self.coordinate = loc.coordinate }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        // Silent — the map still opens on the ville centroid.
    }
}
