import CoreLocation

/// Central lookup: city / quartier name → GPS coordinate.
///
/// Used everywhere the app needs to place a listing on a map without a
/// server-supplied lat/lng — the listing detail card, Explore fallback, and
/// the pin picker's initial camera. Kept as a single source of truth so a
/// coordinate update to one city fixes every surface at once.
enum CityCoordinates {
    /// Ordered longest-key first so a "Bonapriso, Douala" search hits the
    /// specific quartier before the generic city.
    private static let table: [(key: String, lat: Double, lon: Double)] = [
        // Douala + quartiers
        ("bonamoussadi", 4.0933, 9.7451), ("bonapriso", 4.0300, 9.7060),
        ("bonanjo", 4.0463, 9.6884), ("bonabéri", 4.0742, 9.6669),
        ("bonaberi", 4.0742, 9.6669), ("bonaloka", 4.0603, 9.7062),
        ("logbessou", 4.0842, 9.7742), ("logpom", 4.0870, 9.7683),
        ("makepé", 4.0800, 9.7550), ("makepe", 4.0800, 9.7550),
        ("ndokotti", 4.0480, 9.7413), ("new bell", 4.0450, 9.7420),
        ("akwa", 4.0520, 9.7020), ("deido", 4.0620, 9.7020),
        ("bali", 4.0450, 9.7000), ("kotto", 4.0888, 9.7605),
        ("douala", 4.0511, 9.7679),
        // Yaoundé + quartiers
        ("bastos", 3.8880, 11.5160), ("nlongkak", 3.8880, 11.5230),
        ("essos", 3.8620, 11.5350), ("nsam", 3.8480, 11.5100),
        ("mvog-mbi", 3.8560, 11.5220), ("nsimeyong", 3.8280, 11.4930),
        ("biyem-assi", 3.8352, 11.4820), ("biyemassi", 3.8352, 11.4820),
        ("mendong", 3.8290, 11.4650), ("odza", 3.8020, 11.5450),
        ("ekounou", 3.8330, 11.5480), ("mvan", 3.8220, 11.5160),
        ("yaoundé", 3.8480, 11.5021), ("yaounde", 3.8480, 11.5021),
        // Other regional capitals + coastal
        ("bafoussam", 5.4780, 10.4180), ("dschang", 5.4460, 10.0630),
        ("foumban", 5.7250, 10.9010), ("bamenda", 5.9630, 10.1590),
        ("kumbo", 6.2010, 10.6740), ("buéa", 4.1540, 9.2920),
        ("buea", 4.1540, 9.2920), ("limbé", 4.0190, 9.2150),
        ("limbe", 4.0190, 9.2150), ("kumba", 4.6390, 9.4470),
        ("tiko", 4.0750, 9.3600), ("mutengene", 4.1000, 9.3160),
        ("kribi", 2.9390, 9.9070), ("ebolowa", 2.9010, 11.1500),
        ("sangmélima", 2.9330, 11.9840), ("bertoua", 4.5780, 13.6810),
        ("garoua", 9.3020, 13.4000), ("ngaoundéré", 7.3200, 13.5800),
        ("ngaoundere", 7.3200, 13.5800), ("maroua", 10.5910, 14.3150),
        ("kousséri", 12.0770, 15.0300),
    ]

    /// Return the best-matching coordinate for a location string such as
    /// "Bonapriso, Douala" or just "Kribi". Returns nil when the string
    /// doesn't match any known city — callers pick their own fallback so
    /// each surface can decide whether to hide the map or default to Douala.
    static func coordinate(for location: String) -> CLLocationCoordinate2D? {
        let hay = location.lowercased()
        // Longest-key first via the table's own order.
        for entry in table where hay.contains(entry.key) {
            return CLLocationCoordinate2D(latitude: entry.lat, longitude: entry.lon)
        }
        return nil
    }
}
