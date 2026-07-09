import Foundation
import CoreLocation

// MARK: - PlaceLabeler (MYR-204, deliverable 3)
//
// Client-side labeling for a drive's endpoints on the Drive Summary header
// (the "A → B" title). A live drive arrives with only reverse-geocoded street
// addresses from the backend (e.g. "4222 Stratus Way, Frisco, Texas 75034…");
// this resolves each endpoint coordinate (the route's first / last point) to a
// friendlier label through a three-layer degrade ladder:
//
//   (a) a SAVED place (MYR-171 `RideRequestFixtures.savedPlaces`) within
//       ~150 m of the endpoint → its name ("Home" / "Work"); else
//   (b) a reverse-geocoded POI or locality name (`CLGeocoder`), with a hard
//       timeout so a slow/unreachable geocode never blocks the header; else
//   (c) the caller's existing address string (`Drive.from` / `Drive.to`) —
//       the same calm fallback the backend mapping already provides.
//
// Results are cached per (drive id, endpoint) for the session, so reopening a
// summary — or a re-render — never re-geocodes. An actor: the cache is mutated
// off the main thread and the geocode is awaited without hopping the UI.
//
// Applied ONLY to live drives (the summary gates this on an empty baked route);
// sim fixtures keep their curated `from`/`to` verbatim, so the simulated
// summary is byte-for-byte unchanged.
actor PlaceLabeler {
    private let savedPlaces: [RidePlace]
    private let proximityMeters: CLLocationDistance
    private let geocodeTimeout: Duration
    /// Resolved labels keyed by "\(driveID)|start" / "\(driveID)|end".
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

    /// Resolve the display label for one drive endpoint, running the (a)→(b)→(c)
    /// ladder above. Cached per `cacheKey`.
    func label(
        for coordinate: CLLocationCoordinate2D,
        fallback fallbackAddress: String,
        cacheKey: String
    ) async -> String {
        if let cached = cache[cacheKey] { return cached }
        let resolved = await resolve(coordinate: coordinate, fallback: fallbackAddress)
        cache[cacheKey] = resolved
        return resolved
    }

    private func resolve(coordinate: CLLocationCoordinate2D, fallback: String) async -> String {
        // (a) saved-place proximity match.
        if let saved = nearestSavedPlace(to: coordinate) { return saved.label }
        // (b) POI / locality reverse geocode (timeout-guarded).
        if let geocoded = await reverseGeocodedName(for: coordinate) { return geocoded }
        // (c) keep the address the caller already has.
        return fallback
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

    /// Reverse-geocode `coordinate` to a POI (`areasOfInterest`) or locality
    /// name, racing a `geocodeTimeout` sleep so a slow lookup degrades to the
    /// address rather than stalling the header. A fresh `CLGeocoder` per call
    /// keeps the (non-Sendable) geocoder out of the actor's stored state.
    private func reverseGeocodedName(for coordinate: CLLocationCoordinate2D) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let timeout = geocodeTimeout
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                let geocoder = CLGeocoder()
                let placemarks = try? await geocoder.reverseGeocodeLocation(location)
                return PlaceLabeler.name(from: placemarks?.first)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let winner = await group.next() ?? nil
            group.cancelAll()
            return winner
        }
    }

    /// A friendly name from a placemark: a point-of-interest first (e.g. "Klyde
    /// Warren Park"), else the locality (city, e.g. "Frisco"). Returns nil when
    /// the placemark yields only a bare street address — the caller then keeps
    /// its own address string. Static + pure so it is unit-testable.
    static func name(from placemark: CLPlacemark?) -> String? {
        guard let placemark else { return nil }
        if let poi = placemark.areasOfInterest?.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return poi
        }
        if let locality = placemark.locality, !locality.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return locality
        }
        return nil
    }
}
