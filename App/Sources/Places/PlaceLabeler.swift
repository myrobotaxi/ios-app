import Foundation
import CoreLocation

// MARK: - PlaceLabeler (MYR-204, revised for MYR-208)
//
// Client-side labeling for a drive's endpoints on the Drive Summary header
// (the "A → B" title). A live drive arrives with only reverse-geocoded street
// addresses from the backend (e.g. "4222 Stratus Way, Frisco, Texas 75034…");
// this resolves the PAIR of endpoint coordinates (the route's first / last
// point) to friendlier labels through a degrade ladder:
//
//   (a) a SAVED place (MYR-171 `RideRequestFixtures.savedPlaces`) within
//       ~150 m of the endpoint → its name ("Home" / "Work"); else
//   (b) a reverse-geocoded POI ("Klyde Warren Park") or NEIGHBORHOOD
//       ("Highland Park") from `CLGeocoder`, with a hard timeout so a slow /
//       unreachable geocode never blocks the header; else
//   (c) the CITY — but only when the two endpoints sit in different cities
//       ("Frisco → Dallas"). An intra-city drive must never render the
//       useless "Dallas → Dallas" (client QA, Thomas 2026-07-09); else
//   (d) the caller's existing address string (`Drive.from` / `Drive.to`),
//       shortened to its street when the drive is known intra-city (the city
//       adds nothing the other endpoint doesn't share).
//
// The city rule is PAIRWISE — one endpoint's label depends on the other's —
// so resolution takes both endpoints at once (`labels(start:end:…)`), not one
// at a time. Results are cached per (drive id, endpoint) for the session, so
// reopening a summary — or a re-render — never re-geocodes. An actor: the
// cache is mutated off the main thread and the geocode is awaited without
// hopping the UI.
//
// Applied ONLY to live drives (the summary gates this on an empty baked route);
// sim fixtures keep their curated `from`/`to` verbatim, so the simulated
// summary is byte-for-byte unchanged.
actor PlaceLabeler {

    /// One endpoint's geocode outcome, before the pairwise city decision.
    /// `specific` is a saved-place / POI / neighborhood name (always usable);
    /// `locality` is the city (usable only when the pair's cities differ).
    struct ResolvedEndpoint: Equatable {
        var specific: String?
        var locality: String?
    }

    private let savedPlaces: [RidePlace]
    private let proximityMeters: CLLocationDistance
    private let geocodeTimeout: Duration
    /// Final labels keyed by "\(driveID)|start" / "\(driveID)|end".
    private var cache: [String: String] = [:]

    init(
        savedPlaces: [RidePlace],
        proximityMeters: CLLocationDistance = 150,
        geocodeTimeout: Duration = .seconds(3)
    ) {
        self.savedPlaces = savedPlaces
        self.proximityMeters = proximityMeters
        self.geocodeTimeout = geocodeTimeout
    }

    /// Resolve the display labels for a drive's endpoint pair, running the
    /// (a)→(d) ladder above with the pairwise city rule. Cached per drive.
    func labels(
        start: CLLocationCoordinate2D,
        end: CLLocationCoordinate2D,
        fallbacks: (start: String, end: String),
        driveID: String
    ) async -> (start: String, end: String) {
        let startKey = "\(driveID)|start", endKey = "\(driveID)|end"
        if let s = cache[startKey], let e = cache[endKey] { return (s, e) }
        async let resolvedStart = resolveEndpoint(start)
        async let resolvedEnd = resolveEndpoint(end)
        let pair = Self.pairLabels(
            start: await resolvedStart,
            end: await resolvedEnd,
            fallbacks: fallbacks
        )
        cache[startKey] = pair.start
        cache[endKey] = pair.end
        return pair
    }

    /// The pairwise label decision — pure + static so the city rule is
    /// unit-testable without any geocoding. `specific` always wins; the city
    /// renders only when it distinguishes the endpoints; an intra-city
    /// fallback drops the redundant ", City" from the address.
    static func pairLabels(
        start: ResolvedEndpoint,
        end: ResolvedEndpoint,
        fallbacks: (start: String, end: String)
    ) -> (start: String, end: String) {
        // Known-same only when BOTH cities resolved and match; two failed
        // geocodes (nil == nil) are unknown, not "same".
        let knownSameCity = start.locality != nil && start.locality == end.locality

        func finalLabel(_ endpoint: ResolvedEndpoint, other: ResolvedEndpoint, fallback: String) -> String {
            if let specific = endpoint.specific { return specific }
            if let city = endpoint.locality, city != other.locality { return city }
            return knownSameCity ? streetOnly(fallback) : fallback
        }
        return (
            finalLabel(start, other: end, fallback: fallbacks.start),
            finalLabel(end, other: start, fallback: fallbacks.end)
        )
    }

    /// "4222 Stratus Way, Frisco" → "4222 Stratus Way". Leaves a comma-less
    /// string (a curated fixture label or server place name) untouched.
    static func streetOnly(_ address: String) -> String {
        address.components(separatedBy: ", ").first ?? address
    }

    /// The nearest saved place within `proximityMeters`, or nil. Pure + sync so
    /// the ~150 m match is unit-testable without any geocoding.
    func nearestSavedPlace(to coordinate: CLLocationCoordinate2D) -> RidePlace? {
        let target = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        var best: (place: RidePlace, distance: CLLocationDistance)?
        for place in savedPlaces {
            let here = CLLocation(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude)
            let distance = target.distance(from: here)
            guard distance <= proximityMeters else { continue }
            if best == nil || distance < best!.distance {
                best = (place, distance)
            }
        }
        return best?.place
    }

    /// Resolve one endpoint: saved place (specific, no geocode) or a
    /// timeout-guarded reverse geocode (POI/neighborhood + city).
    func resolveEndpoint(_ coordinate: CLLocationCoordinate2D) async -> ResolvedEndpoint {
        if let saved = nearestSavedPlace(to: coordinate) {
            return ResolvedEndpoint(specific: saved.label, locality: nil)
        }
        return await reverseGeocodedEndpoint(for: coordinate)
    }

    /// Reverse-geocode `coordinate`, racing a `geocodeTimeout` sleep so a slow
    /// lookup degrades to the address rather than stalling the header. A fresh
    /// `CLGeocoder` per call keeps the (non-Sendable) geocoder out of the
    /// actor's stored state.
    private func reverseGeocodedEndpoint(for coordinate: CLLocationCoordinate2D) async -> ResolvedEndpoint {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let timeout = geocodeTimeout
        return await withTaskGroup(of: ResolvedEndpoint?.self) { group in
            group.addTask {
                let geocoder = CLGeocoder()
                let placemarks = try? await geocoder.reverseGeocodeLocation(location)
                return PlaceLabeler.endpoint(from: placemarks?.first)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let winner = await group.next() ?? nil
            group.cancelAll()
            return winner ?? ResolvedEndpoint(specific: nil, locality: nil)
        }
    }

    /// Split a placemark into the ladder's inputs: `specific` = a point of
    /// interest ("Klyde Warren Park") else the neighborhood (`subLocality`,
    /// e.g. "Highland Park" / "Oak Lawn"); `locality` = the city, held
    /// separately for the pairwise different-cities rule. Static + pure so it
    /// is unit-testable.
    static func endpoint(from placemark: CLPlacemark?) -> ResolvedEndpoint {
        guard let placemark else { return ResolvedEndpoint(specific: nil, locality: nil) }
        let poi = placemark.areasOfInterest?.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        let neighborhood = placemark.subLocality?.trimmingCharacters(in: .whitespacesAndNewlines)
        let city = placemark.locality?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ResolvedEndpoint(
            specific: poi ?? (neighborhood?.isEmpty == false ? neighborhood : nil),
            locality: city?.isEmpty == false ? city : nil
        )
    }
}
