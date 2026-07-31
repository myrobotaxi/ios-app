import CoreLocation
import Foundation
import MapKit

// MARK: - OwnerMapCamera (MYR-387) — the map may never open on Null Island
//
// `VehicleMapView.recenter` wrote its region as
// `center: centerOverride ?? vehiclePosition.coordinate`, unconditionally. On the
// owner map `centerOverride` is always nil, so the centre is whatever
// `VehicleActivity` carries — and on the LIVE path, before a snapshot exists,
// that is `VehicleContractMapping.placeholderActivity`, which parks the car at
// **latitude 0, longitude 0** with the label "Locating…". The `.driving`
// placeholder is no better: its route is `[]`, and `VehicleRoute.position(along:
// [], progress:)` also answers `(0, 0)`.
//
// (0, 0) is the Gulf of Guinea. On a dark, muted, POI-free `.standard` map style
// it renders as a uniform near-black rectangle with a "Lunar" pin floating in the
// middle of the Atlantic — which is exactly the "COMPLETELY BLACK map area" half
// of the client's report, and the state owner Home settles into for the rest of
// the session once the MYR-326 cold-read budget expires.
//
// The contract has said so all along: websocket-protocol §2.3 makes `(0, 0)` the
// **"no fix" sentinel**, and `VehicleContractMapping.position(from:)`'s own doc
// comment already promises that "callers treat it as last-known geometry, never a
// valid Gulf-of-Guinea location". The RIDER side kept that promise — MYR-336's
// `RiderVehicleProjection.hasFix` is the gate, and it is what keeps
// `SharedViewerState.mapRegionCenter` off the equator and MYR-341's pickup ETA
// quiet. **The OWNER side never had the equivalent.** This is it.
//
// Pure + static, so the invariant is provable with no map, no view and no fleet.
enum OwnerMapCamera {

    /// websocket-protocol §2.3 — `(0, 0)` is "no fix", not a place.
    ///
    /// Deliberately the SAME predicate as `RiderVehicleProjection.hasFix`, phrased
    /// over a coordinate rather than a `VehicleState` so the map (which has already
    /// been through `VehicleActivity`) can ask it too. A coordinate MapKit itself
    /// would reject is treated as no fix for the same reason.
    static func hasFix(_ coordinate: CLLocationCoordinate2D) -> Bool {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return false }
        return !(coordinate.latitude == 0 && coordinate.longitude == 0)
    }

    /// Where a camera write may point, and how wide.
    struct Target: Equatable {
        /// The centre to write, or `nil` when nothing true can be said about
        /// where the car is — in which case the caller must NOT write a region
        /// at all and leaves MapKit on its own wide framing.
        var center: CLLocationCoordinate2D?
        var spanDelta: Double
        var source: Source

        static func == (lhs: Target, rhs: Target) -> Bool {
            lhs.source == rhs.source
                && lhs.spanDelta == rhs.spanDelta
                && lhs.center?.latitude == rhs.center?.latitude
                && lhs.center?.longitude == rhs.center?.longitude
        }
    }

    enum Source: Equatable {
        /// An explicit centre from the caller (the rider map's device fix).
        case override
        /// The vehicle's own live coordinate.
        case liveFix
        /// The last real position this car was seen at, off the device cache.
        case lastKnown
        /// Nothing. The camera is not written.
        case unpositioned
    }

    /// A last-known position is where the car WAS, not where it is, so it opens
    /// wider than a live fix — enough that the neighbourhood reads as context
    /// rather than as a claim about the current parking space. ~4× the standard
    /// `MRTMetrics.mapRegionSpanDelta` neighbourhood span.
    static let lastKnownSpanMultiplier: Double = 4

    /// Resolve the camera target for one frame.
    ///
    /// Precedence, and why:
    ///   1. `override` — the caller's explicit centre (the rider's own device
    ///      fix). It is about the VIEWER, not the car, and outranks everything.
    ///   2. the vehicle's live coordinate, **if it has a fix**. This is the
    ///      overwhelmingly common case and is byte-identical to what shipped
    ///      before, which is why no simulated capture moves: every fixture
    ///      vehicle carries a real San Francisco coordinate.
    ///   3. the device's cached last-known position for this car, widened.
    ///   4. nothing — `.unpositioned`. **Not a fabricated "sane default" city**:
    ///      a map centred on Cupertino is a lie with better lighting. The caller
    ///      leaves MapKit's own wide framing up, which claims nothing.
    static func resolve(
        vehicle: CLLocationCoordinate2D,
        override: CLLocationCoordinate2D? = nil,
        lastKnown: CLLocationCoordinate2D? = nil,
        spanDelta: Double
    ) -> Target {
        if let override, hasFix(override) {
            return Target(center: override, spanDelta: spanDelta, source: .override)
        }
        if hasFix(vehicle) {
            return Target(center: vehicle, spanDelta: spanDelta, source: .liveFix)
        }
        if let lastKnown, hasFix(lastKnown) {
            return Target(
                center: lastKnown,
                spanDelta: spanDelta * lastKnownSpanMultiplier,
                source: .lastKnown
            )
        }
        return Target(center: nil, spanDelta: spanDelta, source: .unpositioned)
    }

    /// The `MKCoordinateRegion` for a target, or `nil` when there is none to
    /// write. Kept separate from `resolve` so the RULE is testable without
    /// MapKit's non-`Equatable` region type.
    static func region(for target: Target) -> MKCoordinateRegion? {
        guard let center = target.center else { return nil }
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(
                latitudeDelta: target.spanDelta,
                longitudeDelta: target.spanDelta
            )
        )
    }

    /// Whether the vehicle MARKER may be drawn this frame.
    ///
    /// Separate from the camera on purpose: a last-known camera is honest context
    /// ("this is roughly where your car lives"), but a gold pin is a claim that
    /// the car is THERE, right now. With no live fix there is no such claim to
    /// make, so the pin is withheld even while the map is positioned — and it is
    /// never, under any circumstance, drawn at `(0, 0)`.
    static func drawsVehicleMarker(vehicle: CLLocationCoordinate2D) -> Bool {
        hasFix(vehicle)
    }
}
