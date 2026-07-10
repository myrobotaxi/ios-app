import CoreLocation

// MARK: - Pin-drop reverse-geocode seam (MYR-212 deliverables 1 & 2)
//
// The authoritative pin's street-level label: as the rider drags the map and it
// settles, the confirmed pickup coordinate is the map's live center (see
// `SharedViewerState.pinDropCoordinate`) and THIS resolves that coordinate to a
// human label. Split out as a seam so the label ladder is unit-testable with a
// fake (no `CLGeocoder`, no network) and so the simulated flow renders
// byte-identically (the sim conformer reports `nil` → the pin keeps its fixture
// string).
//
// LABEL LADDER (MYR-212 defect 1): STREET-LEVEL first, never a bare city. The
// client's pin resolved to "Frisco" (city) because the old `LiveUserLocation`
// ladder fell through to `locality`. A pickup pin must name a spot precise
// enough to meet a car at, so the ladder is:
//   subThoroughfare + thoroughfare  (e.g. "1200 Grandscape Blvd")
//     → thoroughfare                (street)
//     → name / POI                  (e.g. "Grandscape")
//     → subLocality                 (neighborhood)
//   and NOTHING below that — a bare city is not a pickup spot, so the caller
//   keeps the calm "Current location" fallback instead.
@MainActor
protocol RidePinLabeling: AnyObject {
    /// Reverse-geocode a coordinate to a street-level pickup label, or `nil`
    /// when it can't be resolved to something precise enough (the caller keeps
    /// its fallback). The simulated conformer always returns `nil`.
    func label(for coordinate: CLLocationCoordinate2D) async -> String?
}

// MARK: - Simulated (no-op — keeps sim pixel-identical)

/// M1 default: never resolves a label, so the pin keeps its fixture string
/// ("Folsom & 2nd St") and every simulated pin-drop scene renders identically.
@MainActor
final class SimulatedPinLabeler: RidePinLabeling {
    func label(for coordinate: CLLocationCoordinate2D) async -> String? { nil }
}

// MARK: - Live (CLGeocoder, street-first ladder)

/// The live conformer: one `CLGeocoder.reverseGeocodeLocation` per settled
/// coordinate, mapped through the street-first ladder above. Geocode failure
/// (offline / throttled) returns `nil` — the pin quietly keeps its last label.
@MainActor
final class LivePinLabeler: RidePinLabeling {
    /// Injectable placemark source so tests can exercise the ladder without
    /// `CLGeocoder`'s network (which also throttles aggressively).
    typealias PlacemarkResolver = @Sendable (CLLocation) async -> CLPlacemark?

    private let resolve: PlacemarkResolver

    init(resolve: PlacemarkResolver? = nil) {
        self.resolve = resolve ?? { location in
            let geocoder = CLGeocoder()
            return try? await geocoder.reverseGeocodeLocation(location).first
        }
    }

    func label(for coordinate: CLLocationCoordinate2D) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let placemark = await resolve(location) else { return nil }
        return Self.streetLabel(from: placemark)
    }

    /// The address fields the ladder reads — a tiny, testable projection of
    /// `CLPlacemark` (which can't be constructed with these fields in a test).
    struct Fields {
        var subThoroughfare: String?
        var thoroughfare: String?
        var areasOfInterest: [String]?
        var name: String?
        var subLocality: String?
        var locality: String?
        var postalCode: String?
    }

    /// Adapter for a real `CLPlacemark` (the live path + `LiveUserLocation`).
    static func streetLabel(from placemark: CLPlacemark) -> String? {
        streetLabel(from: Fields(
            subThoroughfare: placemark.subThoroughfare,
            thoroughfare: placemark.thoroughfare,
            areasOfInterest: placemark.areasOfInterest,
            name: placemark.name,
            subLocality: placemark.subLocality,
            locality: placemark.locality,
            postalCode: placemark.postalCode
        ))
    }

    /// The street-first ladder (see the protocol header). Pure so it's testable
    /// with hand-built fields, no `CLGeocoder` / `CLPlacemark`.
    static func streetLabel(from fields: Fields) -> String? {
        if let street = nonEmpty(fields.thoroughfare) {
            if let number = nonEmpty(fields.subThoroughfare) {
                return "\(number) \(street)"
            }
            return street
        }
        if let poi = fields.areasOfInterest?.compactMap(nonEmpty).first {
            return poi
        }
        // MYR-213: `placemark.name` for a mid-block / non-addressable point in a
        // suburb is often the bare ZIP ("75034") or the city — NOT a pickup spot.
        // The client's pin degraded to exactly this. Accept `name` only when it's
        // a real place string: not the postal code, not the city, and not a bare
        // number (a lone house number or ZIP with no street is meaningless).
        if let name = nonEmpty(fields.name),
           name != fields.locality,
           name != nonEmpty(fields.postalCode),
           !isBareNumber(name) {
            return name
        }
        if let neighborhood = nonEmpty(fields.subLocality) {
            return neighborhood
        }
        // Deliberately NOT `locality` / `postalCode` — a bare city or ZIP is not a
        // pickup spot; the caller keeps its previous street label / "Pinned location".
        return nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// A token with no letters (e.g. "75034", "4220", "75034-1234") — a ZIP or a
    /// lone house number, never a street on its own.
    private static func isBareNumber(_ value: String) -> Bool {
        !value.contains { $0.isLetter }
    }
}
