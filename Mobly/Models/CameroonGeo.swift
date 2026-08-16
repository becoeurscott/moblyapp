import Foundation
import CoreLocation

/// Cameroon administrative geography for the location picker: 10 régions →
/// villes → quartiers. City lists lead with the regional capital. Quartier lists
/// cover the main cities (esp. Douala/Yaoundé, the pilot markets); any city
/// without a list falls back to free text in the UI.
struct CmRegion: Identifiable, Hashable {
    let name: String
    let cities: [String]
    var id: String { name }
}

enum CameroonGeo {
    static let regions: [CmRegion] = [
        CmRegion(name: "Littoral",     cities: ["Douala", "Nkongsamba", "Édéa", "Loum", "Manjo", "Mbanga"]),
        CmRegion(name: "Centre",       cities: ["Yaoundé", "Mbalmayo", "Obala", "Bafia", "Nanga-Eboko", "Akonolinga"]),
        CmRegion(name: "Ouest",        cities: ["Bafoussam", "Dschang", "Foumban", "Mbouda", "Bandjoun", "Bafang"]),
        CmRegion(name: "Sud-Ouest",    cities: ["Buéa", "Limbé", "Kumba", "Tiko", "Mamfe", "Mutengene"]),
        CmRegion(name: "Nord-Ouest",   cities: ["Bamenda", "Kumbo", "Ndop", "Wum", "Fundong", "Bali"]),
        CmRegion(name: "Sud",          cities: ["Ebolowa", "Kribi", "Sangmélima", "Ambam", "Djoum"]),
        CmRegion(name: "Est",          cities: ["Bertoua", "Batouri", "Abong-Mbang", "Yokadouma", "Bélabo"]),
        CmRegion(name: "Adamaoua",     cities: ["Ngaoundéré", "Meiganga", "Tibati", "Banyo", "Tignère"]),
        CmRegion(name: "Nord",         cities: ["Garoua", "Guider", "Figuil", "Poli", "Lagdo"]),
        CmRegion(name: "Extrême-Nord", cities: ["Maroua", "Kousséri", "Mokolo", "Yagoua", "Kaélé"]),
    ]

    static let quartiers: [String: [String]] = [
        "Douala": ["Akwa", "Bonapriso", "Bonanjo", "Bali", "Deido", "Bonamoussadi",
                   "Makepe", "Bonabéri", "New Bell", "Ndokotti", "Logbessou", "Kotto",
                   "Logpom", "Yassa", "Bépanda", "Nyalla", "Cité des Palmiers", "Japoma"],
        "Yaoundé": ["Bastos", "Nlongkak", "Essos", "Nsam", "Mvog-Mbi", "Nsimeyong",
                    "Biyem-Assi", "Mendong", "Odza", "Ekounou", "Mimboman", "Ngousso",
                    "Emana", "Nkolbisson", "Etoudi", "Tsinga", "Messa", "Mvan"],
        "Bafoussam": ["Tamdja", "Kamkop", "Djeleng", "Tougang", "Banengo", "Famla", "Ndiendam"],
        "Kribi": ["Dombé", "Mpangou", "Talla", "Afan-Mabé", "Bwambé", "Ngoyé"],
        "Limbé": ["Down Beach", "Bota", "Mile 4", "Church Street", "New Town", "Middle Farms"],
        "Buéa": ["Molyko", "Great Soppo", "Bonduma", "Bomaka", "Mile 16", "Muea", "Bokwango"],
        "Bamenda": ["Up Station", "Commercial Avenue", "Nkwen", "Mankon", "Bambili", "Ntarikon"],
        "Garoua": ["Plateau", "Roumdé Adjia", "Poumpoumré", "Djamboutou", "Kolléré"],
        "Maroua": ["Domayo", "Djarengol", "Founangué", "Pitoaré", "Kakataré"],
        "Ngaoundéré": ["Baladji", "Dang", "Burkina", "Mbideng", "Joli-Soir"],
        "Bertoua": ["Nkolbikon", "Mokolo", "Tigaza", "Kano", "Enia"],
        "Nkongsamba": ["Bonahang", "Ekangté", "Nsoung", "Bonaberi"],
        "Édéa": ["Ekité", "Bilalang", "Pongo", "Mbanda"],
        "Dschang": ["Foto", "Foréké", "Paid Ground", "Tsinkop"],
        "Foumban": ["Njissé", "Mantoum", "Koutaba"],
        "Kumba": ["Fiango", "Kosala", "Buea Road", "Mbeng"],
    ]

    static func quartiers(for city: String) -> [String] { quartiers[city] ?? [] }

    /// Which region a city belongs to (for reverse-mapping when editing).
    static func region(for city: String) -> String? {
        regions.first { $0.cities.contains(city) }?.name
    }

    /// City centroids used to open the pin picker at the right spot. The
    /// values are approximate town-centres — good enough as a starting camera
    /// position; the user then drags to the exact building. Cities not listed
    /// here fall back to the country centre (Yaoundé area).
    private static let cityCoords: [String: (lat: Double, lng: Double)] = [
        "Douala":       (4.0511,  9.7679),
        "Yaoundé":      (3.8480,  11.5021),
        "Bafoussam":    (5.4780,  10.4173),
        "Buéa":         (4.1550,  9.2410),
        "Limbé":        (4.0227,  9.2137),
        "Bamenda":      (5.9597,  10.1462),
        "Kribi":        (2.9333,  9.9070),
        "Garoua":       (9.3018,  13.3921),
        "Maroua":       (10.5910, 14.3159),
        "Ngaoundéré":   (7.3167,  13.5833),
        "Bertoua":      (4.5787,  13.6849),
        "Ebolowa":      (2.9000,  11.1500),
        "Nkongsamba":   (4.9547,  9.9412),
        "Édéa":         (3.8000,  10.1333),
        "Dschang":      (5.4436,  10.0553),
        "Foumban":      (5.7167,  10.9000),
        "Kumba":        (4.6363,  9.4469),
        "Mbalmayo":     (3.5167,  11.5000),
        "Sangmélima":   (2.9333,  11.9833),
    ]

    /// Best-effort centroid for a city. Falls back to Cameroon's geographic
    /// centre so the map never opens on (0,0).
    static func coordinate(for city: String) -> CLLocationCoordinate2D {
        if let c = cityCoords[city] {
            return CLLocationCoordinate2D(latitude: c.lat, longitude: c.lng)
        }
        return CLLocationCoordinate2D(latitude: 5.6, longitude: 12.7)
    }
}
