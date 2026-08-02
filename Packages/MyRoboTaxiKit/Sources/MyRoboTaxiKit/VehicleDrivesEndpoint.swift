import Foundation
import MyRobotaxiContracts

// MARK: - The two drive reads, as a seam (MYR-422; rest-api.md §7.2 + §7.4)
//
// **THIS FILE DECLARES NO WIRE SHAPE.** Both reads are covered by contracts
// codegen (`DrivesListResponse` / `DriveSummary`, `DriveRoute` / `RoutePoint`), so
// all that is authored here is the SEAM — the same narrowing
// `VehicleBookedWindowsEndpoint` is, and for the same two reasons: a caller
// depends on the question rather than on `RestClient`, and a DEBUG capture scene
// can inject a wire stub and still run the shipping code above it.
//
// `LiveDrivesFeed` (MYR-203, the owner's Drives tab) holds a concrete `RestClient`
// and is deliberately left alone: it is a paginating, `drive_ended`-refreshing
// list feed, and the rider's post-ride summary needs one question answered once
// ("which drive, if any, IS this ride, and what did the car actually drive?").
// Sharing the feed would mean giving the summary a cursor, a page cache and a
// refresh policy it has no use for.
//
// **THE ACCESS FACT THAT SHAPES EVERY CONSUMER: DRIVES ARE OWNER-ONLY.** MYR-369
// retired the `live_history` share tier and made `SharedVehicleGrant.grantsHistory`
// `false` for every viewer, so a viewer-tier rider's drives read is a **403** by
// design. That is not an error condition to surface — it is the ordinary answer
// for most riders, and the only correct response to it is to fall through to the
// next source of geometry in silence. See `RideSummaryDriveRouteStore`, which
// folds every failure (403, offline, a decode) into the same "no Tesla route"
// verdict.
public protocol VehicleDrivesEndpoint: Sendable {
    /// `GET /api/vehicles/{vehicleId}/drives` (§7.2) — one page of the vehicle's
    /// completed drives, newest first. The envelope IS the contract, so it is
    /// returned whole.
    ///
    /// Throws `RestError.http(status: 403, …)` for a caller who may watch the car
    /// but not read its history (MYR-369), and `401` for an expired session.
    func drives(vehicleID: String, cursor: String?, limit: Int) async throws -> DrivesListResponse

    /// `GET /api/drives/{driveId}/route` (§7.4) — the drive's full GPS polyline,
    /// oldest first. `routePoints` is ALWAYS an array (`[]`, never null), so
    /// callers branch on `.isEmpty` rather than on optionality.
    ///
    /// Heavy (~3.6k points / ~250 KB for an hour's drive) and therefore fetched
    /// LAZILY, never per list row.
    func driveRoute(id: String) async throws -> DriveRoute
}
