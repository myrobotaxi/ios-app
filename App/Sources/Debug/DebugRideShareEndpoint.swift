#if DEBUG
import Foundation
import MyRoboTaxiKit

// MARK: - DebugRideShareEndpoint (MYR-342 — drift-gate / screenshot only)
//
// A stand-in for `PUT /api/tesla/vehicles/{id}/ride-share` (rest-api.md §7.18), so
// the DEBUG owner scenes can exercise the REAL `setRideShareEnabled` path
// (optimistic flip → endpoint call → adopt the server's echo, or roll back and
// settle a notice) without a live backend.
//
// It reproduces the two server behaviours that actually shape the client:
//
//  1. **THE ECHO IS THE ANSWER.** §7.18 says this server writes exactly what was
//     asked, so the stub echoes the submission — and the executor adopts the
//     ECHO rather than the bool it sent, which is the rule that keeps a future
//     coercing server from breaking it. (Contrast `DebugServiceWindowEndpoint`,
//     whose whole point is an echo that DISAGREES: there, Tesla's estimate
//     outranks the owner. Nothing outranks the owner here.)
//  2. **A FAILED WRITE IS NEVER A SUCCESS.** With `failure` set, every write
//     throws — which is what drives the ROLLBACK capture. §7.18 is explicit about
//     why that matters: a `200` over a failed write "would leave an owner
//     believing their car is paused while it is still taking requests", and a
//     client that kept the optimistic position would produce exactly that belief
//     without any server bug at all.
//
// Release builds never compile this file.
struct DebugRideShareEndpoint: VehicleRideShareEndpoint {
    /// When set, every write fails with this error instead (drives the rollback +
    /// notice capture).
    var failure: RestError?

    func setRideShareEnabled(_ enabled: Bool, vehicleID: String) async throws -> VehicleRideShareResponse {
        if let failure { throw failure }
        return VehicleRideShareResponse(vehicleId: vehicleID, enabled: enabled)
    }
}

/// Which of the three ride-share row states a capture scene wants (MYR-342).
///
/// The row has exactly three renderings and each needs a different WIRE outcome to
/// reach it honestly, which is why this is an endpoint selector rather than a view
/// flag: what the capture shows must be what the shipping executor produced.
///   • `.succeeds` — the resting ON / PAUSED states. The echo lands, the position
///     is adopted, no notice.
///   • `.hangs` — the PENDING state, parked in flight (see below).
///   • `.fails` — the ROLLBACK: the row snaps back to the server's position and
///     the notice line appears beneath it.
enum DebugRideShareWriteOutcome {
    case succeeds
    case hangs
    case fails

    var endpoint: any VehicleRideShareEndpoint {
        switch self {
        case .succeeds: DebugRideShareEndpoint()
        case .hangs: DebugHangingRideShareEndpoint()
        case .fails: DebugRideShareEndpoint(
            // A plain 500: §7.18's store-layer failure, the one the contract
            // insists must never be reported as success.
            failure: .http(status: 500, code: nil, message: "store failure", subCode: nil)
        )
        }
    }
}

/// A ride-share stub that never answers — for the PENDING capture.
///
/// The in-flight state lasts milliseconds against a healthy backend and cannot be
/// screenshotted by racing it, so the scene parks the write in flight instead: the
/// row's spinner is then the REAL `uiState(for: .rideShare).isPending`, raised by
/// the shipping `beginPending`, rather than a hand-set flag. The same
/// park-in-one-branch precedent as MYR-326's `DebugLoadingFleet`.
struct DebugHangingRideShareEndpoint: VehicleRideShareEndpoint {
    func setRideShareEnabled(_ enabled: Bool, vehicleID: String) async throws -> VehicleRideShareResponse {
        // Never resolves, and never spins a CPU. Cancellation is the only exit,
        // which is what the app does when the scene goes away.
        try await Task.sleep(for: .seconds(86_400))
        return VehicleRideShareResponse(vehicleId: vehicleID, enabled: enabled)
    }
}
#endif
