#if DEBUG
import Foundation
import MyRoboTaxiKit
import MyRobotaxiContracts

// MARK: - DebugServiceWindowEndpoint (MYR-316 — drift-gate / screenshot only)
//
// A stand-in for `PUT /api/tesla/vehicles/{id}/service-window`, so the DEBUG
// service scenes can exercise the REAL `setServiceWindow` path (endpoint call →
// adopt the server's RESOLVED echo → notice on failure) without a live backend.
//
// It reproduces the two server behaviours that actually shape the client:
//
//  1. **"Must be in the future"** → `400 invalid_request`. The app already
//     prevents this locally, so this arm is what proves the defensive path is
//     wired rather than decorative.
//  2. **TESLA PRECEDENCE.** When `teslaEstimate` is set, the response ECHOES
//     TESLA'S instant, not the owner's — which is the single most surprising
//     thing about this endpoint and the reason the executor must adopt the echo
//     instead of the value it sent. A stub that echoed the submission back would
//     make a broken client look correct.
//
// Release builds never compile this file.
struct DebugServiceWindowEndpoint: VehicleServiceWindowEndpoint {
    /// When set, every write fails with this error instead (drives the notice
    /// captures).
    var failure: RestError?
    /// Tesla's own `service_data.service_etc`, when the visit has one. Non-nil
    /// makes this stub outrank the owner's submission exactly as the server does.
    var teslaEstimate: String?

    func setServiceWindow(expectedEndAt: String?, vehicleID: String) async throws -> VehicleServiceWindowResponse {
        if let failure { throw failure }

        // The server's own validation: a submitted instant must parse and must be
        // in the future. A CLEAR (nil) skips it — there is nothing to validate.
        if let expectedEndAt {
            guard let parsed = Self.parse(expectedEndAt), parsed > Date() else {
                throw RestError.http(
                    status: 400,
                    code: ErrorPayload.Code(rawValue: "invalid_request"),
                    message: "expectedEndAt must be a future RFC 3339 instant",
                    subCode: nil
                )
            }
        }

        // Precedence: (1) Tesla's estimate, (2) the owner's entry, (3) null.
        return VehicleServiceWindowResponse(
            vehicleId: vehicleID,
            serviceEstimatedEndAt: teslaEstimate ?? expectedEndAt
        )
    }

    private static func parse(_ value: String) -> Date? {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: value) ?? fractional.date(from: value)
    }
}
#endif
