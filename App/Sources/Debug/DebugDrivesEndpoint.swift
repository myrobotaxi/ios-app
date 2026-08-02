#if DEBUG
import CoreLocation
import Foundation
import MyRoboTaxiKit
import MyRobotaxiContracts

// MARK: - DebugDrivesEndpoint (MYR-422 — drift-gate / screenshot only)
//
// A stand-in for `GET /api/vehicles/{id}/drives` (§7.2) and
// `GET /api/drives/{id}/route` (§7.4), so the post-ride summary's TESLA-DRIVEN rung
// can be photographed without a real Tesla, a real trip and an owner session.
//
// It injects the WIRE and nothing else — the `DebugBookedWindowsEndpoint` /
// `DebugServiceWindowEndpoint` precedent. The capture then runs the SHIPPING
// `LiveRideDriveRoutes` provider, the SHIPPING `RideDriveJoin` match + trim, the
// SHIPPING `RideSummaryDriveRouteStore` cache and the SHIPPING
// `RideSummaryRoute.resolve` ladder, so a driven line in the screenshot is proof
// the production chain produced it.
//
// It is a MODEL OF THE SERVER rather than a mirror of this client (the MYR-368 stub
// lesson), in three ways that matter to the join:
//
//  • It emits RFC 3339 UTC `Z` strings for every instant — `time.RFC3339`, what the
//    Go handler formats with — so the app's own parse runs.
//  • Its drive is DELIBERATELY WIDER THAN THE RIDE: the car left for the pickup
//    before the rider tapped Start and parked after the drop-off, which is the
//    ordinary shape of a self-ride and the reason the track has to be trimmed at
//    all. A stub whose drive matched the ride exactly would let the capture pass
//    with the trim deleted.
//  • Its `forbidden` arm answers the **403** a viewer-tier rider genuinely gets
//    (MYR-369), rather than an empty list — an empty list would exercise the
//    "no covering drive" path and prove nothing about the access one.
//
// Release builds never compile this file.
struct DebugDrivesEndpoint: VehicleDrivesEndpoint {

    /// One scripted drive: its window, and the track it recorded.
    struct ScriptedDrive: Sendable {
        var id: String
        var start: Date
        var end: Date
        /// Sampled positions, oldest first, spread evenly across `[start, end]`.
        var path: [CLLocationCoordinate2D]
    }

    var drives: [ScriptedDrive] = []

    /// When set, BOTH reads fail with this — the viewer-tier rider's 403, or an
    /// offline device. The summary must fall to the MKDirections rung in silence.
    var failure: RestError?

    func drives(vehicleID: String, cursor: String?, limit: Int) async throws -> DrivesListResponse {
        if let failure { throw failure }
        let items = drives.map { drive in
            DriveSummary(
                id: drive.id,
                vehicleId: vehicleID,
                startTime: Self.wire.string(from: drive.start),
                endTime: Self.wire.string(from: drive.end),
                date: Self.day.string(from: drive.start),
                distanceMiles: 0,
                durationSeconds: Int(drive.end.timeIntervalSince(drive.start)),
                avgSpeedMph: 0,
                maxSpeedMph: 0,
                startChargeLevel: 0,
                endChargeLevel: 0,
                fsdMiles: 0,
                fsdPercentage: 0,
                createdAt: Self.wire.string(from: drive.end)
            )
        }
        // §7.2 is newest-first.
        return DrivesListResponse(
            items: items.sorted { $0.startTime > $1.startTime },
            nextCursor: nil,
            hasMore: false
        )
    }

    func driveRoute(id: String) async throws -> DriveRoute {
        if let failure { throw failure }
        guard let drive = drives.first(where: { $0.id == id }) else {
            throw RestError.http(status: 404, code: .notFound, message: nil, subCode: nil)
        }
        let span = drive.end.timeIntervalSince(drive.start)
        let steps = max(drive.path.count - 1, 1)
        let points = drive.path.enumerated().map { index, coordinate in
            RoutePoint(
                lat: coordinate.latitude,
                lng: coordinate.longitude,
                speed: 0,
                heading: 0,
                timestamp: Self.wire.string(
                    from: drive.start.addingTimeInterval(span * Double(index) / Double(steps))
                )
            )
        }
        return DriveRoute(driveId: id, routePoints: points)
    }

    /// RFC 3339 UTC, seconds precision, always `Z` — `time.RFC3339`.
    private static let wire: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    /// The list row's `date` ("YYYY-MM-DD").
    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// The 403 a viewer-tier rider's drives read genuinely gets (MYR-369) — drives
    /// are owner-only, so this is the ORDINARY answer for most riders and the arm
    /// `riderSummaryLive` runs.
    static let forbidden = RestError.http(
        status: 403,
        code: .permissionDenied,
        message: "drives are owner-only",
        subCode: nil
    )
}
#endif
