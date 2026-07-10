import CoreLocation

// MARK: - TripEstimate (MYR-212 deliverable 5 — one estimate per destination)
//
// The live search + pin-drop path produces `RidePlace`s with NO trip
// miles/minutes (search distances are straight-line from the region center, and
// the pin pickup carries 0/0) — so Review showed "0 min · 0.0 mi trip" and
// Booking fell back to the fixture-ish 14 mi / 28 min defaults (client QA round
// 2, defect 5). This computes ONE estimate per destination selection, stored on
// the draft so Review / Booking / the pending pill all read the same numbers.
//
// METHOD (documented decision): a straight-line great-circle distance between
// the confirmed pickup and the destination, inflated by a fixed road-detour
// factor, with a flat average urban speed for the minutes. No `MKDirections`:
// a single routed estimate would be one network call, but it is deferred with
// the rest of live routing to MYR-176/177, and a deterministic closed-form
// estimate keeps this unit-testable with no network and identical across the
// sim (fixture destinations already carry their own miles/minutes and are never
// re-estimated — see `estimate(from:to:)`'s caller gate on `minutes == 0`).
enum TripEstimate {
    /// Real road distance runs longer than the straight line — a 1.3× detour
    /// factor is the common rideshare rule-of-thumb for dense metros.
    static let detourFactor: Double = 1.3
    /// Flat average speed (mph) blending surface streets + brief highway — a
    /// sane urban heuristic in place of a routed duration (MYR-176/177).
    static let averageSpeedMph: Double = 24

    /// Straight-line miles between two coordinates (great-circle).
    static func straightLineMiles(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let from = CLLocation(latitude: a.latitude, longitude: a.longitude)
        let to = CLLocation(latitude: b.latitude, longitude: b.longitude)
        return from.distance(from: to) * 0.000621371 // meters → miles
    }

    /// Trip miles + minutes for a pickup → destination pair. Miles are the
    /// detour-inflated straight-line distance; minutes derive from the flat
    /// average speed, clamped to ≥ 1 so a very short hop never shows "0 min".
    static func estimate(from pickup: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) -> (miles: Double, minutes: Int) {
        let miles = straightLineMiles(from: pickup, to: destination) * detourFactor
        let minutes = max(1, Int((miles / averageSpeedMph * 60).rounded()))
        return (miles, minutes)
    }

    /// Returns `place` with computed trip miles/minutes when it carries none
    /// (`minutes == 0`, the live search / pin-drop case) — otherwise `place`
    /// untouched, so fixture destinations (which ship real miles/minutes) stay
    /// byte-identical in the simulated flow.
    static func applied(to place: RidePlace, pickup: CLLocationCoordinate2D) -> RidePlace {
        guard place.minutes == 0 else { return place }
        let est = estimate(from: pickup, to: place.coordinate)
        return RidePlace(
            id: place.id,
            label: place.label,
            subtitle: place.subtitle,
            miles: est.miles,
            minutes: est.minutes,
            icon: place.icon,
            coordinate: place.coordinate
        )
    }
}
