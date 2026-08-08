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
