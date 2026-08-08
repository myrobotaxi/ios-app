import CoreLocation
import Foundation
import MyRobotaxiContracts

// MARK: - RiderVehicleProjection (MYR-336) — the VIEWER's half of a live snapshot
//
// The rider watches a car that is (usually) not theirs. MYR-184 gave that car its
// real IDENTITY — name/model/plate off the §7.0 catalog row through the
// production `VehicleContractMapping.vehicle` — and MYR-343 settled WHICH car
// (owned first, else the first grant). MYR-336 gives it real MOTION, and the
// question that comes with motion is: how much of a live `VehicleState` may reach
// a rider's screen?
//
// The answer is deliberately narrow, and it is a CLIENT rule on top of a server
// one. §7.5 already viewer-masks the snapshot a `role: viewer` receives, so the
// owner-only strings mostly are not on the wire in the first place. But the rider
// map and the owner sheet consume the SAME `Vehicle` type, and the owner path
// folds the snapshot over the summary wholesale (`VehicleContractMapping
// .vehicle(summary:state:)`: VIN, software version, FSD designation, colour,
// trim-composed model, plate). Handing the rider that fold would mean the client
// re-deriving owner-facing identity from a stream the moment a server ever
// widened the mask — a `!= nil` away from rendering a stranger's VIN.
//
// So the rider's fold is exactly TWO facts, which are the only two the map has
// any use for:
//
//   • WHERE the car is  (`VehicleActivity`'s coordinate / route geometry)
//   • WHAT it is doing  (driving vs. stationary — the same `activity` case split)
//
// Identity stays on the CATALOG ROW, which is the surface the server masks for
// this rider and the one MYR-184 already fought to make honest. Nothing else on
// `Vehicle` is reachable from telemetry here, and `RiderVehicleProjectionTests`
// asserts that by handing the projection a state carrying every owner-only field
// populated and requiring the result to be unchanged in all of them.
//
// Pure + static, so both rules are testable with no socket, no view, no clock.
enum RiderVehicleProjection {

    /// Contract §2.3 — `(0, 0)` is the "no fix" sentinel, not the Gulf of Guinea.
    ///
    /// This is the honesty gate for the whole file: with no fix there is nothing
    /// true to say about where the car is, so the projection returns the catalog
    /// row untouched (i.e. `VehicleContractMapping.placeholderActivity`'s
    /// "Locating…") rather than parking the rider's car on the equator.
    static func hasFix(_ state: VehicleState?) -> Bool {
        guard let state else { return false }
        return !(state.latitude == 0 && state.longitude == 0)
    }

    /// The watched vehicle's live coordinate, or `nil` when there is no fix yet.
    ///
    /// `nil` is load-bearing downstream: it is what keeps MYR-341's pickup ETA
    /// quiet ("Where to?", never a fabricated minute) and what leaves
    /// `SharedViewerState.mapRegionCenter` on its next fallback instead of
    /// centring the rider's map on 0,0.
    static func coordinate(from state: VehicleState?) -> CLLocationCoordinate2D? {
        guard let state, hasFix(state) else { return nil }
        return VehicleContractMapping.position(from: state)
    }

    /// The watched vehicle's live COMPASS HEADING (degrees clockwise from north),
    /// or `nil` when there is no fix to have a heading at.
    ///
    /// MYR-460 — the external-beta report *"car heading not changing direction
    /// with tesla telemetry car heading"*. The field has been on the wire since
    /// contracts shipped `VehicleState` and the merger has always folded it
    /// (`VehicleStateMerger`, `case "heading"`), but it died HERE: this
    /// projection folds `activity` alone, `Vehicle`/`VehicleActivity` have no
    /// heading, and so the tracking glyph rotated to a bearing derived from
    /// `trackProgress` along the polyline instead. On the live path that is the
    /// MYR-393 defect in the rotational axis — the same clock-driven guess,
    /// pointing the car down a road it may not be on.
    ///
    /// **Gated on `hasFix` for the same reason the coordinate is.** §2.3's
    /// `(0, 0)` sentinel means the car reported no position, and the contract
    /// groups `{latitude, longitude, heading}` as ATOMIC — heading is present iff
    /// the coordinates are. A heading returned without a fix would be
    /// `VehicleStateBaseline.forDeltaSeed`'s zero (MYR-449), i.e. "due north" as
    /// a rendering of "the car has said nothing", which is exactly the false
    /// confidence `hasFix` exists to refuse.
    static func heading(from state: VehicleState?) -> Double? {
        guard let state, hasFix(state) else { return nil }
        return Double(state.heading)
    }

    /// The car's OWN navigation polyline (`navRouteCoordinates`), or `[]` when the
    /// wire carries none that is real geometry.
    ///
    /// MYR-482 — the external-beta report *"no route line to the destination for the
    /// whole trip"*, on a car whose dash was actively navigating. Nothing on the
    /// rider's tracking surface has ever read Tesla's own route: the map draws
    /// `RideRouteStore.leg2`, which is an MKDirections **pickup → destination**
    /// preview fetched once at accept time. This is the missing hop, and it is the
    /// exact twin of MYR-460's heading hop — the field has been on the wire and
    /// folded by the merger since contracts shipped, it already reaches the rider
    /// through `activity` (`VehicleContractMapping.drivingTrip`), and only the
    /// tracking map never asked for it.
    ///
    /// **`RideRoutePolyline.isReal` is applied HERE, once** (MYR-293): a 2-point
    /// "route" is a claim about a path and not a path, so it is refused at the
    /// source rather than by each consumer. `[]` is what makes the caller's next
    /// rung reachable.
    ///
    /// Deliberately NOT gated on `hasFix`: the nav group and the gps group are
    /// different atomic groups, and a route Tesla decoded is geometry whether or
    /// not this particular frame also carried a position.
    static func navRoute(from state: VehicleState?) -> [CLLocationCoordinate2D] {
        guard let state else { return [] }
        let route = VehicleContractMapping.routeCoordinates(from: state.navRouteCoordinates)
        return RideRoutePolyline.isReal(route) ? route : []
    }

    /// Fold ONLY position + status from a live snapshot onto the catalog row.
    ///
    /// Every other field of `vehicle` is carried through verbatim — see this
    /// file's header for why that is a rule rather than an oversight.
    static func apply(_ state: VehicleState?, to vehicle: Vehicle) -> Vehicle {
        guard let state, hasFix(state) else { return vehicle }
        return Vehicle(
            id: vehicle.id,
            name: vehicle.name,
            model: vehicle.model,
            colorName: vehicle.colorName,
            plate: vehicle.plate,
            seatHeat: vehicle.seatHeat,
            seatClimate: vehicle.seatClimate,
            // THE ONE FIELD THE STREAM MAY WRITE.
            activity: VehicleContractMapping.activity(from: state),
            vin: vehicle.vin,
            softwareVersion: vehicle.softwareVersion,
            fsdVersion: vehicle.fsdVersion,
            tirePressures: vehicle.tirePressures
        )
    }
}
