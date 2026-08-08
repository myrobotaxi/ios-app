import Foundation
import MyRobotaxiContracts

// MARK: - VehicleStateBaseline (MYR-449)
//
// THE EMPTY STATE A LIVE FRAME CAN BE FOLDED ONTO WHEN NO SNAPSHOT EVER LANDED.
//
// `VehicleStateMerger.apply(fields:to:)` opens with `var state = original`: it is
// a FOLD, so it needs something to fold onto, and until this type existed the
// only thing that could ever supply that was the cold REST `/snapshot`. That made
// one REST read the gate on the entire live surface — see `LiveVehicleState`'s
// `seedsStateFromDeltas` for the defect that produced.
//
// **EVERY VALUE HERE IS THE SCHEMA'S OWN "NOTHING REPORTED" VALUE, NEVER A GUESS.**
// That is what makes a delta-seeded state honest rather than a fabricated car:
//
//   • `latitude`/`longitude` are `0, 0` — §2.3's NO-FIX SENTINEL, which
//     `RiderVehicleProjection.hasFix` and `OwnerMapCamera` already refuse to draw.
//     So a baseline that never receives a GPS delta renders NO marker, exactly as
//     a missing state does. The seeding cannot invent a position.
//   • `status` is `.offline`, which the schema names as the DB default for a
//     vehicle that has reported nothing (`gear` group nullability note).
//   • Every identity string is EMPTY and every number `0` — the same values the
//     schema documents as its non-nullable defaults "on initial vehicle creation".
//     `VehicleContractMapping.nonEmpty` already reads an empty string as unknown.
//   • `lastUpdated` is empty, so `parseTimestamp` answers `nil` and every
//     freshness surface reads "not reported yet" rather than "just now". A
//     baseline must never be able to claim currency it has not got.
//
// The snapshot-only fields (VIN, software version, trim, service window, plate…)
// are all `nil` and STAY nil: the merger declines to fold them by design
// (MYR-298's tripwire), so a delta-seeded state carries exactly the streamed
// fields the car actually sent and nothing else. `LiveVehicleState
// .snapshotReadIssuedAt` remains `nil` for such a state, which is the public
// signal that no snapshot stands behind it.
public enum VehicleStateBaseline {

    /// The zero state for `vehicleId`, suitable only as a fold target for live
    /// deltas. Never emitted as a `.snapshot` event and never handed to a
    /// consumer on its own — an unfolded baseline is indistinguishable from
    /// "nothing known", which is precisely what it means.
    public static func forDeltaSeed(vehicleId: String) -> VehicleState {
        VehicleState(
            vehicleId: vehicleId,
            name: "",
            model: "",
            year: 0,
            color: "",
            status: .offline,
            speed: 0,
            heading: 0,
            latitude: 0,
            longitude: 0,
            locationName: "",
            locationAddress: "",
            chargeLevel: 0,
            estimatedRange: 0,
            odometerMiles: 0,
            fsdMilesSinceReset: 0,
            lastUpdated: ""
        )
    }
}
