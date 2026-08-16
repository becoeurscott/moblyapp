import Foundation
import Combine
import MapKit

/// Live address / place completion for the Explore search bar — same engine
/// Apple Maps uses. Emits suggestions as the user types, then resolves the
/// chosen suggestion to a real coordinate so the camera can zoom to it.
///
/// Scoped to Cameroon so a search for "kribi" doesn't come back with the
/// Belgian town of the same name.
@MainActor
final class LocationSearchCompleter: NSObject, ObservableObject {
    static let shared = LocationSearchCompleter()

    struct Suggestion: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let subtitle: String
        // Kept internally so `resolve(_:)` can hand it back to MKLocalSearch
        // without re-typing the string.
        let native: MKLocalSearchCompletion
        static func == (a: Suggestion, b: Suggestion) -> Bool {
            a.title == b.title && a.subtitle == b.subtitle
        }
    }

    @Published private(set) var suggestions: [Suggestion] = []

    private let completer = MKLocalSearchCompleter()
    /// Bias completion to Cameroon so worldwide matches don't outrank local ones.
    private let cameroonRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 5.7, longitude: 12.35),
        span:   MKCoordinateSpan(latitudeDelta: 12, longitudeDelta: 12))

    override init() {
        super.init()
        completer.delegate = self
        completer.region = cameroonRegion
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { suggestions = []; completer.queryFragment = ""; return }
        completer.queryFragment = q
    }

    /// Resolve a suggestion to a coordinate. Returns nil on failure so the
    /// caller can fall back to a name-based lookup.
    func resolve(_ s: Suggestion) async -> CLLocationCoordinate2D? {
        let req = MKLocalSearch.Request(completion: s.native)
        do {
            let response = try await MKLocalSearch(request: req).start()
            return response.mapItems.first?.placemark.coordinate
        } catch {
            return nil
        }
    }
}

extension LocationSearchCompleter: MKLocalSearchCompleterDelegate {
    /// Every well-known Cameroonian city / région / neighbourhood string
    /// that MKLocalSearchCompleter is likely to emit. Filtering completions
    /// against this set + explicit country name gives a hard Cameroon-only
    /// restriction (region-biasing alone still lets Belgian towns through).
    private static let cameroonTokens: Set<String> = [
        "cameroon", "cameroun",
        // 10 régions
        "littoral", "centre", "ouest", "sud-ouest", "sud ouest",
        "nord-ouest", "nord ouest", "sud", "est",
        "adamaoua", "adamawa", "nord", "extrême-nord", "extreme-nord",
        "far north",
        // Major cities + coastal
        "douala", "yaoundé", "yaounde", "bafoussam", "dschang",
        "foumban", "bamenda", "kumbo", "buéa", "buea", "limbé",
        "limbe", "kumba", "tiko", "mutengene", "kribi", "ebolowa",
        "sangmélima", "sangmelima", "bertoua", "batouri", "abong-mbang",
        "yokadouma", "ngaoundéré", "ngaoundere", "meiganga", "tibati",
        "banyo", "tignère", "tignere", "garoua", "guider", "figuil",
        "poli", "lagdo", "maroua", "kousséri", "kousseri", "mokolo",
        "yagoua", "kaélé", "kaele", "édéa", "edea", "loum", "manjo",
        "mbanga", "nkongsamba", "mbalmayo", "obala", "bafia",
        "nanga-eboko", "akonolinga",
    ]

    private static func isCameroon(_ c: MKLocalSearchCompletion) -> Bool {
        let hay = (c.title + " " + c.subtitle).lowercased()
        // Any known Cameroonian token in either title or subtitle keeps it.
        // Empty subtitle usually means MapKit couldn't attach a country →
        // fall through to the token match; only drop when we can prove it
        // is somewhere else.
        return cameroonTokens.contains(where: { hay.contains($0) })
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let mapped = completer.results
            .filter(Self.isCameroon)
            .map { Suggestion(title: $0.title, subtitle: $0.subtitle, native: $0) }
        // Cap so the dropdown never grows unbounded; 8 fits below the bar.
        let capped = Array(mapped.prefix(8))
        Task { @MainActor in self.suggestions = capped }
    }
    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.suggestions = [] }
    }
}
