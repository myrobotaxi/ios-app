import CoreLocation
import MapKit

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

// MARK: - Live (modern MapKit / CLGeocoder, street-first ladder + guards)

/// The live conformer: one reverse geocode per settled coordinate, mapped
/// through the street-first ladder above and the MYR-216-3c DISTANCE GUARD.
/// Geocode failure (offline / throttled) returns `nil` — the caller degrades to
/// the neutral label rather than keeping a stale street (MYR-216-3b).
///
/// MYR-216-3c.1 — resolution source: on iOS 26+ this uses MapKit's modern
/// `MKReverseGeocodingRequest` (CLGeocoder is deprecated there), which is backed
/// by the SAME data as the rendered map, so its snapped point agrees better with
/// what the rider sees under the glyph; iOS 17–25 falls back to `CLGeocoder`.
/// Both paths land on one `CLPlacemark`-shaped `Fields` projection + the
/// geocoder's snapped point, so the ladder + distance guard are shared and
/// unit-testable with faked placemarks.
@MainActor
final class LivePinLabeler: RidePinLabeling {
    /// A reverse-geocode result: the address fields + the point the geocoder
    /// actually SNAPPED to (a parcel centroid, often offset from the query) —
    /// the distance guard compares that point to the pin (MYR-216-3c.2).
    struct GeocodeResult: Sendable {
        var fields: Fields
        var snappedLocation: CLLocationCoordinate2D?
    }

    /// Injectable geocode source so tests can exercise the ladder + guards
    /// without a real geocoder (which also throttles aggressively).
    typealias Resolver = @Sendable (CLLocation) async -> GeocodeResult?

    private let resolve: Resolver

    init(resolve: Resolver? = nil) {
        self.resolve = resolve ?? Self.systemResolve
    }

    func label(for coordinate: CLLocationCoordinate2D) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let result = await resolve(location) else { return nil }
        return Self.label(from: result.fields, snappedLocation: result.snappedLocation, pin: coordinate)
    }

    /// The system reverse geocoder — modern MapKit on iOS 26+, CLGeocoder before
    /// it (MYR-216-3c.1). Both return the structured `Fields` + snapped point.
    static func systemResolve(_ location: CLLocation) async -> GeocodeResult? {
        if #available(iOS 26.0, *) {
            guard let request = MKReverseGeocodingRequest(location: location),
                  let items = try? await request.mapItems,
                  let item = items.first else { return nil }
            // MKAddress / MKAddressRepresentations expose no structured street
            // components (only city-level + a full-address string), so the
            // (deprecated-on-26 but still-populated) `placemark` is the only
            // source of thoroughfare/subThoroughfare for the ladder. `location`
            // is the modern snapped point for the distance guard.
            return GeocodeResult(fields: Fields(from: item.placemark), snappedLocation: item.location.coordinate)
        } else {
            let geocoder = CLGeocoder()
            guard let placemark = try? await geocoder.reverseGeocodeLocation(location).first else { return nil }
            return GeocodeResult(fields: Fields(from: placemark), snappedLocation: placemark.location?.coordinate)
        }
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

        init(subThoroughfare: String? = nil, thoroughfare: String? = nil, areasOfInterest: [String]? = nil,
             name: String? = nil, subLocality: String? = nil, locality: String? = nil, postalCode: String? = nil) {
            self.subThoroughfare = subThoroughfare
            self.thoroughfare = thoroughfare
            self.areasOfInterest = areasOfInterest
            self.name = name
            self.subLocality = subLocality
            self.locality = locality
            self.postalCode = postalCode
        }

        /// Projection of a real `CLPlacemark` (both live paths + `LiveUserLocation`).
        init(from placemark: CLPlacemark) {
            self.init(
                subThoroughfare: placemark.subThoroughfare,
                thoroughfare: placemark.thoroughfare,
                areasOfInterest: placemark.areasOfInterest,
                name: placemark.name,
                subLocality: placemark.subLocality,
                locality: placemark.locality,
                postalCode: placemark.postalCode
            )
        }
    }

    // MARK: MYR-216-3c.2 — distance guard

    /// The pin label with the DISTANCE GUARD applied (MYR-216-3c.2): CLGeocoder /
    /// MapKit snap the query to the nearest ADDRESS PARCEL, which can be a block
    /// off the road under the pin (client evidence: pin on Town & Country Blvd,
    /// parcel "4555 Warwick Ln"). When the snapped point is farther than
    /// `farThresholdMeters` from the pin, never present its house number:
    ///   • a house-numbered far result is a parcel snap to a DIFFERENT road →
    ///     degrade to neutral (`nil`);
    ///   • a street-level far result (no house number) is likelier the road
    ///     itself → show the bare street.
    /// (Neither `CLPlacemark` nor `MKMapItem` exposes an independent thoroughfare
    /// snapped-point, so subThoroughfare presence is the conservative proxy for
    /// the coordinator's "thoroughfare's snapped point is near" test — it never
    /// shows a confidently-wrong house address.) Near results run the full ladder.
    static func label(from fields: Fields, snappedLocation: CLLocationCoordinate2D?,
                      pin: CLLocationCoordinate2D, farThresholdMeters: Double = 50) -> String? {
        if let snapped = snappedLocation, distanceMeters(snapped, pin) > farThresholdMeters {
            if nonEmpty(fields.subThoroughfare) != nil { return nil }
            return nonEmpty(fields.thoroughfare)
        }
        return streetLabel(from: fields)
    }

    /// Great-circle distance in meters between two coordinates.
    static func distanceMeters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    /// Adapter for a real `CLPlacemark` (used by `LiveUserLocation`'s device
    /// label — the pin path goes through `label(from:snappedLocation:pin:)`).
    static func streetLabel(from placemark: CLPlacemark) -> String? {
        streetLabel(from: Fields(from: placemark))
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
