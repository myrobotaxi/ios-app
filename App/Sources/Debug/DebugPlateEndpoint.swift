#if DEBUG
import Foundation
import MyRoboTaxiKit
import MyRobotaxiContracts

// MARK: - DebugPlateEndpoint (MYR-286 — drift-gate / screenshot only)
//
// A stand-in for the §7.14 `PUT /api/tesla/vehicles/{id}/plate` write, so the
// DEBUG vehicle-details scenes can exercise the REAL `setPlate` path (endpoint
// call → adopt the server's normalized echo → notice on failure) without a live
// backend. It reproduces the server's rule EXACTLY as rest-api.md §7.14 states
// it — normalize first, validate second — because a stub that validated the raw
// input would reject `"  abc 1234  "`, which the real server accepts.
//
// Release builds never compile this file.
struct DebugPlateEndpoint: VehiclePlateEndpoint {
    /// When set, every write fails with this error instead (drives the notice
    /// captures — e.g. a `400 invalid_request` for "That plate doesn't look right").
    var failure: RestError?

    func setLicensePlate(_ plate: String, vehicleID: String) async throws -> VehiclePlateResponse {
        if let failure { throw failure }
        // §7.14 step 2: trim then uppercase — and NOTHING else. Interior spacing is
        // preserved verbatim ("ABC 1234" and "ABC1234" are different plates in some
        // jurisdictions, so collapsing them would rewrite the owner's answer).
        let normalized = plate.trimmingCharacters(in: .whitespaces).uppercased()
        // §7.14 step 2, second half: `^[A-Z0-9 -]*$` and ≤ 10, against the
        // NORMALIZED value.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -")
        guard normalized.count <= 10,
              normalized.unicodeScalars.allSatisfy(allowed.contains)
        else {
            // The rejected value is P1 and is never echoed back in the message.
            throw RestError.http(
                status: 400,
                code: ErrorPayload.Code(rawValue: "invalid_request"),
                message: "plate must be at most 10 characters from [A-Z0-9 -]",
                subCode: nil
            )
        }
        return VehiclePlateResponse(vehicleId: vehicleID, licensePlate: normalized)
    }
}
#endif
