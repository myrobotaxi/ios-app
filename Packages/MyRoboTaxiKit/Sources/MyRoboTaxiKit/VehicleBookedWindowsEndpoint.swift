import Foundation
import MyRobotaxiContracts

// MARK: - Schedule-picker conflict read (MYR-385, rest-api.md §7.22)
//
// **THIS FILE DECLARES NO WIRE SHAPE, AND THAT IS THE POINT.** Unlike its
// neighbours (`VehicleServiceWindowPayloads`, `VehiclePlatePayloads`,
// `VehicleRideSharePayloads`), §7.22 is a READ, so contracts codegen covers it in
// full: `VehicleBookedWindowsResponse` and `BookedWindow` come from
// `MyRobotaxiContracts` (v0.26.0, `schemas/booked-windows.schema.json`). All that
// is authored here is the SEAM.
//
// The read side of the MYR-383 booking gate. The gate refuses a colliding
// reservation at create with `409 vehicle_unavailable` / `subCode: time_conflict`;
// in r15 that refusal was the FIRST thing the rider heard — the picker offered
// noon for a car the rider had themselves already booked at noon — and a refusal
// arriving after somebody has committed to a choice reads as a bug rather than as
// a rule. This lets the picker dim the slot instead.
//
// FIVE PROPERTIES OF THE SURFACE SHAPE EVERY CONSUMER, and each is a way to get
// it wrong:
//
//  1. **CONCRETE INSTANTS, NEVER AN ANCHOR PLUS A RADIUS.** The ±45min half-width
//     is a PRODUCT GUESS that lives in exactly one place on the server
//     (`store.RideConflictWindow`), is passed to SQL as a bind parameter, and is
//     encoded in no schema, no enum and no client. The server resolves it and
//     emits the ENDPOINTS. Consumers MUST NOT re-derive, re-centre, pad, round or
//     infer it — a client that hard-codes 45 minutes silently disagrees with the
//     gate the day the number moves.
//  2. **THE INTERVAL IS OPEN AT BOTH ENDS.** The gate's comparison is strictly
//     inside, so a reservation for exactly `start` or exactly `end` is ACCEPTED
//     (two rides touching at a boundary are a legal back-to-back booking). Dim
//     `start < slot < end` and nothing else; dimming the endpoints refuses a slot
//     the server would have taken.
//  3. **A SNAPSHOT, NOT A SUBSCRIPTION.** Windows appear and vanish underneath the
//     response, and the ACTIVE-INSTANT arm anchors on the server's clock, so it
//     SLIDES forward while the response does not. The create-time `409
//     time_conflict` therefore stays the AUTHORITY; this read reduces how often a
//     rider meets it and does not replace it.
//  4. **`items: []` MEANS "NO RESERVATIONS", NOT "WIDE OPEN".** §7.22 deliberately
//     does not consult the §7.18 ride-share pause or the §7.16 service window —
//     both refuse a create, neither describes a window — so a paused or in-service
//     car answers with its real, usually empty, window list. Reading an empty list
//     as "this car is free" would undo two other gates at once.
//  5. **AUTHORIZATION IS THE RIDE-CREATE GATE, BYTE FOR BYTE** — owner, or a
//     viewer whose accepted grant carries the ride capability. A caller a create
//     would turn away is turned away here too, so the endpoint is never an oracle
//     that answers a question `POST /api/ride-requests` would not.
//
// `pending` changes the WORDS ("already requested" rather than the untrue
// "booked"), never the availability — the create path counts pending claims in
// full. `own` tracks the RIDER, so an owner sees `own: false` for rides other
// people booked in their car.

/// The rider schedule picker's conflict read (MYR-385), factored into its own
/// protocol so callers depend only on "which windows is this car spoken for in"
/// and can be tested with a stub — the same narrowing pattern as
/// ``VehicleServiceWindowEndpoint`` / ``VehiclePlateEndpoint``. `RestClient` is
/// the production conformer.
public protocol VehicleBookedWindowsEndpoint: Sendable {
    /// `GET /api/vehicles/{vehicleId}/booked-windows?from=&to=` (§7.22) — the
    /// vehicle's blocked intervals overlapping `[from, to]`, ordered by `start`.
    ///
    /// The bounds are `Date`s rather than strings ON PURPOSE. §7.22 carries a
    /// query-string caveat with teeth: a literal `+` in an RFC 3339 numeric offset
    /// decodes to a SPACE on the server and the value then arrives unparseable, a
    /// `400`. `URLComponents` does not percent-encode `+` in a query value (it is a
    /// legal query character), so a string-taking signature would have made that
    /// trap reachable from every call site. Taking instants and formatting them
    /// here as UTC `Z` makes it unreachable instead.
    ///
    /// Throws a typed `RestError.http` on any non-2xx: `400 invalid_request`
    /// (`from == to`, `from > to`, an unparseable bound, or a span exceeding the
    /// server's 14-day cap — the server REFUSES rather than clamping, because a
    /// shortened answer looks complete and would under-dim), `401 auth_failed`,
    /// `403 vehicle_not_owned` (the ride-create gate, unchanged), `404 not_found`,
    /// `500` on a store failure — **never** an empty `items` in place of an error.
    func bookedWindows(vehicleID: String, from: Date, to: Date) async throws -> VehicleBookedWindowsResponse
}

/// §7.22's range cap, restated here so a caller can size its own request against
/// the bound it will be judged by.
///
/// **DO NOT CLAMP TO IT.** The server refuses an over-long span rather than
/// silently shortening it, for the reason a shortened answer is indistinguishable
/// from a complete one and would under-dim the picker. A caller needing a longer
/// horizon issues several calls; a caller that clamps has invented a partial
/// answer and called it whole.
public enum BookedWindowsRange {
    /// 14 days — `store.MaxBookedWindowRange`, injected into the §7.22 handler.
    public static let maximum: TimeInterval = 14 * 24 * 60 * 60
}
