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
//  2. **IT ECHOES THE OWNER COLUMN** — `expectedEndAt`, the instant just
//     submitted, never the resolved `serviceEstimatedEndAt`. That is §7.16's own
//     rule ("echoing the resolved value would make a client believe its write had
//     been overruled when it has merely been outranked"), and MYR-362 is what it
//     cost to have this stub say otherwise: it answered with a field the server
//     has never emitted, so the scene proved a decode that could not work against
//     a real backend. A stub is only evidence to the extent it is the wire.
//
// Release builds never compile this file.
struct DebugServiceWindowEndpoint: VehicleServiceWindowEndpoint {
    /// When set, every write fails with this error instead (drives the notice
    /// captures).
    var failure: RestError?

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

        // The OWNER column, verbatim — RFC 3339 UTC without fractional seconds,
        // the exact shape `formatInstantOrNil` emits. Tesla precedence is a READ
        // concern and shows up on the next `/snapshot`, not here.
        return VehicleServiceWindowResponse(
            vehicleId: vehicleID,
            expectedEndAt: expectedEndAt.flatMap(Self.parse).map(Self.wire.string(from:))
        )
    }

    /// RFC 3339 UTC, seconds precision — `time.RFC3339`, which is what the Go
    /// handler formats its echo with.
    private static let wire: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    private static func parse(_ value: String) -> Date? {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: value) ?? fractional.date(from: value)
    }
}
#endif
