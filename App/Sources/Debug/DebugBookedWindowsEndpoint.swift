#if DEBUG
import Foundation
import MyRoboTaxiKit
import MyRobotaxiContracts

// MARK: - DebugBookedWindowsEndpoint (MYR-385 — drift-gate / screenshot only)
//
// A stand-in for `GET /api/vehicles/{id}/booked-windows` (§7.22), so the
// `riderScheduleBooked` scene can photograph a picker with real dimmed slots
// without a live backend and a real reservation.
//
// It injects the WIRE and nothing else — the same "real code path, injected wire"
// precedent as `DebugServiceWindowEndpoint` / `DebugShareEndpoint` /
// `DebugVehicleDetailsFleet`. The capture then runs the SHIPPING
// `LiveRideBookedWindows` provider, the SHIPPING `RideBookedWindowMapping` parse,
// the SHIPPING `RideBookedWindowsStore` cache and the SHIPPING
// `RideScheduleFloor` grid rule, so a dimmed chip in the screenshot is proof the
// production chain produced it rather than proof a flag was set.
//
// It is a MODEL OF THE SERVER, not a mirror of this client (the MYR-368 stub
// lesson):
//
//  • It emits RFC 3339 UTC `Z` strings, seconds precision — `time.RFC3339`, what
//    the Go handler formats with — not `Date`s the app would never have to parse.
//  • It RESOLVES the ±45min half-width itself and emits concrete endpoints,
//    exactly as the server does, so nothing downstream is handed an anchor it
//    would have to re-centre. The constant lives HERE, in a DEBUG stub standing in
//    for the server that owns it, and reaches no shipping file.
//  • It HONOURS the requested range, returning only windows that overlap
//    `[from, to]`, so the picker's range derivation is exercised rather than
//    bypassed.
//
// Release builds never compile this file.
struct DebugBookedWindowsEndpoint: VehicleBookedWindowsEndpoint {

    /// One occupying ride: the instant it is anchored on, plus the two flags.
    struct Booking: Sendable {
        var anchor: Date
        var pending: Bool
        var own: Bool
    }

    var bookings: [Booking] = []

    /// When set, every read fails with this error instead — the FAIL-OPEN capture,
    /// which must be indistinguishable from a picker that never had this feature.
    var failure: RestError?

    /// The server's conflict half-width, resolved HERE because that is where it
    /// lives — `store.RideConflictWindow`, a bind parameter, encoded in no schema
    /// and no client. A shipping file that knew this number would be the exact
    /// defect §7.22's concrete-instants design exists to prevent.
    static let halfWidth: TimeInterval = 45 * 60

    func bookedWindows(vehicleID: String, from: Date, to: Date) async throws -> VehicleBookedWindowsResponse {
        if let failure { throw failure }
        let items = bookings
            .map { booking in
                BookedWindow(
                    start: Self.wire.string(from: booking.anchor.addingTimeInterval(-Self.halfWidth)),
                    end: Self.wire.string(from: booking.anchor.addingTimeInterval(Self.halfWidth)),
                    pending: booking.pending,
                    own: booking.own
                )
            }
            // The server returns windows OVERLAPPING the range, ordered by `start`.
            .filter { window in
                guard let start = Self.wire.date(from: window.start),
                      let end = Self.wire.date(from: window.end)
                else { return false }
                return end > from && start < to
            }
            .sorted { $0.start < $1.start }
        return VehicleBookedWindowsResponse(items: items)
    }

    /// RFC 3339 UTC, seconds precision, always `Z` — `time.RFC3339`.
    private static let wire: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()
}
#endif
