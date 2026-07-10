import CoreLocation
import MapKit
#if DEBUG
import os

// MYR-223 — standing label-pipeline probe: every reverse-geocode outcome and
// its throttle classification is logged (DEBUG only) so the streaming-fix probe
// (CLAUDE.md "Streaming-fix camera probe") can capture the throttle/backoff
// behavior a static fix can never show. Filter with:
//   log stream --predicate 'subsystem == "app.myrobotaxi.ios" AND category == "label"'
let mrtLabelLog = Logger(subsystem: "app.myrobotaxi.ios", category: "label")
#endif

@inline(__always)
func mrtLabelTrace(_ message: @autoclosure () -> String) {
    #if DEBUG
    let text = message()
    mrtLabelLog.info("\(text, privacy: .public)")
    #endif
}

// MARK: - Pin-label resolution outcome (MYR-223 deliverable 1)
//
// The old seam returned a bare `String?`, which CONFLATED two very different
// non-results: "the geocoder answered but nothing is precise enough here" (a
// genuine mid-block/city/far-parcel point) and "the geocoder didn't answer at
// all" (throttled by a burst of drags, offline, transient network). On-device,
// reverse geocoders THROTTLE aggressive drag bursts (`MKError.loadingThrottled`
// / `CLError.network`) — and the old ladder degraded EVERY such failure straight
// to the neutral "Pinned location", so a pin resting on a named road showed
// neutral (the client's on-device evidence). This three-way outcome lets the
// caller RETRY a transient failure with backoff while the pin stays settled, and
// only degrade to neutral on a genuine `.unresolved` or after retries exhaust.
enum PinLabelResolution: Equatable, Sendable {
    /// A precise pickup label resolved (the ladder's output) — show it.
    case resolved(String)
    /// The geocoder answered, but nothing precise enough (bare city / ZIP / a
    /// far-parcel snap) — a genuine unresolvable point. Degrade to neutral; a
    /// retry would return the same nothing.
    case unresolved
    /// The geocoder FAILED to answer (throttled / offline / transient) — retry
    /// with backoff before degrading; the point may well resolve once the rate
    /// limit clears. Distinct from `.unresolved` precisely so a throttled burst
    /// never silently becomes neutral.
    case failed
}

// MARK: - Pin-drop reverse-geocode seam (MYR-212 deliverables 1 & 2)
//
// The authoritative pin's street-level label: as the rider drags the map and it
// settles, the confirmed pickup coordinate is the map's live center (see
// `SharedViewerState.pinDropCoordinate`) and THIS resolves that coordinate to a
// human label. Split out as a seam so the label ladder is unit-testable with a
// fake (no `CLGeocoder`, no network) and so the simulated flow renders
// byte-identically (the sim conformer reports `.unresolved` → the pin keeps its
// fixture string).
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
//   keeps the calm neutral fallback instead.
@MainActor
protocol RidePinLabeling: AnyObject {
    /// Reverse-geocode a coordinate to a `PinLabelResolution` (MYR-223): the
    /// street-level pickup label, a genuine `.unresolved`, or a transient
    /// `.failed` the caller should retry. The simulated conformer always returns
    /// `.unresolved`.
    func resolve(for coordinate: CLLocationCoordinate2D) async -> PinLabelResolution
}

extension RidePinLabeling {
    /// Convenience projection to the pre-MYR-223 `String?` shape — a resolved
    /// label or `nil` for either non-result. Kept for call sites / tests that
    /// only care whether a precise label exists (the retry/backoff pipeline in
    /// `SharedViewerState` uses the full `resolve(for:)` outcome).
    func label(for coordinate: CLLocationCoordinate2D) async -> String? {
        if case .resolved(let label) = await resolve(for: coordinate) { return label }
        return nil
    }
}

// MARK: - Simulated (no-op — keeps sim pixel-identical)

/// M1 default: never resolves a label, so the pin keeps its fixture string
/// ("Folsom & 2nd St") and every simulated pin-drop scene renders identically.
@MainActor
final class SimulatedPinLabeler: RidePinLabeling {
    func resolve(for coordinate: CLLocationCoordinate2D) async -> PinLabelResolution { .unresolved }
}

// MARK: - Live (modern MapKit / CLGeocoder, street-first ladder + guards)

/// The live conformer: one reverse geocode per settled coordinate, mapped
/// through the street-first ladder above and the MYR-216-3c DISTANCE GUARD.
/// A geocode that ANSWERS but resolves to nothing precise returns `.unresolved`;
/// a geocode that FAILS (throttled / offline) returns `.failed` so the caller can
/// retry with backoff rather than degrade a throttled burst straight to neutral
/// (MYR-223 deliverable 1).
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

    /// The raw outcome of one system reverse geocode — separates a geocoder that
    /// ANSWERED (success / empty) from one that FAILED (threw), so the throttle
    /// classification lives at the boundary and the ladder above stays pure
    /// (MYR-223).
    enum ResolveOutcome: Sendable, Equatable {
        /// The geocoder returned a placemark.
        case success(GeocodeResult)
        /// The geocoder answered with no usable placemark (genuine no-result).
        case empty
        /// The geocoder threw a throttle / network / transient error — retry.
        case failed

        static func == (lhs: ResolveOutcome, rhs: ResolveOutcome) -> Bool {
            switch (lhs, rhs) {
            case (.empty, .empty), (.failed, .failed): return true
            case (.success, .success): return true
            default: return false
            }
        }
    }

    /// Injectable geocode source so tests can exercise the ladder + guards — and
    /// now the throttle/backoff pipeline — without a real geocoder (which also
    /// throttles aggressively).
    typealias Resolver = @Sendable (CLLocation) async -> ResolveOutcome

    private let resolver: Resolver

    init(resolve: Resolver? = nil) {
        self.resolver = resolve ?? Self.systemResolve
    }

    func resolve(for coordinate: CLLocationCoordinate2D) async -> PinLabelResolution {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        switch await resolver(location) {
        case .failed:
            return .failed
        case .empty:
            return .unresolved
        case .success(let result):
            if let label = Self.label(from: result.fields, snappedLocation: result.snappedLocation, pin: coordinate) {
                return .resolved(label)
            }
            // The geocoder answered, but the ladder / far-parcel guard rejected
            // it (bare city, ZIP, a parcel snap on a different road) — a genuine
            // unresolvable point, NOT a throttle. Retrying returns the same
            // nothing, so degrade to neutral immediately.
            return .unresolved
        }
    }

    /// The system reverse geocoder — modern MapKit on iOS 26+, CLGeocoder before
    /// it (MYR-216-3c.1). Both return the structured `Fields` + snapped point on
    /// success; a thrown error is CLASSIFIED (throttle/transient → `.failed`,
    /// genuine no-result → `.empty`) rather than swallowed to nil (MYR-223).
    static func systemResolve(_ location: CLLocation) async -> ResolveOutcome {
        if #available(iOS 26.0, *) {
            guard let request = MKReverseGeocodingRequest(location: location) else { return .empty }
            do {
                let items = try await request.mapItems
                guard let item = items.first else { return .empty }
                // MKAddress / MKAddressRepresentations expose no structured street
                // components (only city-level + a full-address string), so the
                // (deprecated-on-26 but still-populated) `placemark` is the only
                // source of thoroughfare/subThoroughfare for the ladder. `location`
                // is the modern snapped point for the distance guard.
                return .success(GeocodeResult(fields: Fields(from: item.placemark), snappedLocation: item.location.coordinate))
            } catch {
                return classify(error)
            }
        } else {
            let geocoder = CLGeocoder()
            do {
                guard let placemark = try await geocoder.reverseGeocodeLocation(location).first else { return .empty }
                return .success(GeocodeResult(fields: Fields(from: placemark), snappedLocation: placemark.location?.coordinate))
            } catch {
                return classify(error)
            }
        }
    }

    /// Classify a reverse-geocode error into RETRY (`.failed`) vs. genuine
    /// NO-RESULT (`.empty`) — MYR-223 deliverable 1's failure-classification
    /// table. The device geocoders surface rate limiting as:
    ///   • `MKError.loadingThrottled` (3) — the modern MapKit rate-limit signal;
    ///   • `CLError.network` (2) — CLGeocoder's rate-limit/transient-network code
    ///     (it throttles rapid reverse-geocodes to a network error).
    /// Only an explicit "no placemark here" (`MKError.placemarkNotFound`,
    /// `CLError.geocodeFoundNoResult`) is a genuine `.empty`; EVERYTHING ELSE —
    /// including `.serverFailure` / `.unknown` and any unrecognized error — is
    /// treated as transient and retried, the conservative choice that never
    /// degrades a throttled burst to neutral (the client's on-device defect).
    /// Codes are logged at DEBUG so the streaming probe can read what the device
    /// actually surfaces.
    static func classify(_ error: Error) -> ResolveOutcome {
        if let clError = error as? CLError {
            mrtLabelTrace("geocode CLError code=\(clError.code.rawValue)")
            switch clError.code {
            case .geocodeFoundNoResult:
                return .empty
            default:
                // .network (throttle/transient), .geocodeCanceled, etc → retry.
                return .failed
            }
        }
        if let mkError = error as? MKError {
            mrtLabelTrace("geocode MKError code=\(mkError.errorCode)")
            switch mkError.code {
            case .placemarkNotFound:
                return .empty
            default:
                // .loadingThrottled, .serverFailure, .unknown, … → retry.
                return .failed
            }
        }
        mrtLabelTrace("geocode error (unclassified) → failed: \(error)")
        return .failed
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
