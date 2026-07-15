import CoreLocation
import Foundation
import MyRoboTaxiKit
import MyRobotaxiContracts

// MARK: - Ride-request backend seam (MYR-209)
//
// The two Kit capabilities `LiveRideRequestService` needs, expressed as narrow
// protocols so the service can be unit-tested against stubs with no network
// (mirrors how `LiveVehicleFleet` injects `HTTPPerforming` / `WebSocketChannelFactory`):
//
//  • `RideRequestAPI`   — the REST calls (rest-api.md §7.8). `RestClient` conforms
//                         as-is; its method signatures already match.
//  • `RideEventStreaming` — the account-wide ride-frame stream + connect lifecycle
//                         (`TelemetrySocket.rideEvents()`, MYR-209 Kit deliverable).
//
// Both are `Sendable` and their requirements are `async`, so an actor
// (`TelemetrySocket`) and a `Sendable` struct (`RestClient`) satisfy them without
// bridging.

protocol RideRequestAPI: Sendable {
    /// The caller's vehicle catalog — used to resolve the create target vehicle
    /// in live mode (see `LiveRideRequestService.resolveVehicleID`).
    func vehicles() async throws -> [VehicleSummary]
    func createRideRequest(_ body: RideRequestCreateRequest) async throws -> RideRequest
    /// The authenticated rider's own requests, newest first (rest-api.md §7.8) —
    /// used by `LiveRideRequestService.reconcileCreate` to discover whether a
    /// create that errored client-side actually landed on the server.
    func rideRequests(cursor: String?, limit: Int) async throws -> RideRequestsListResponse
    func rideRequest(id: String) async throws -> RideRequest
    func cancelRideRequest(id: String) async throws -> RideRequest
    func acceptRideRequest(id: String) async throws -> RideRequest
    func declineRideRequest(id: String) async throws -> RideRequest
    func incomingRideRequests(cursor: String?, limit: Int) async throws -> RideRequestsListResponse
}

extension RestClient: RideRequestAPI {}

protocol RideEventStreaming: Sendable {
    func rideEvents() async -> AsyncStream<RideRequestEvent>
    func connect() async
    func disconnect() async
}

extension TelemetrySocket: RideEventStreaming {}

// MARK: - Contract → app mapping (MYR-209)
//
// Folds a wire `MyRobotaxiContracts.RideRequest` onto the app's fixture-shaped
// `RideRequestRecord` so the EXISTING rider/owner sheets render a live ride with
// no UI change. Deliberately lossy — documented v1 gaps:
//
//  • Fleet-member identity: the wire record carries only `vehicleId`, not the
//    rich `FleetMember` card fields (owner name, colorName, battery, plate) the
//    fixture picker supplies. Until a live fleet-picker join lands (needs the
//    MYR-91 shared-viewer access set + a live Review picker — out of scope here),
//    a live record reuses `RideRequestFixtures.fleet[0]` for those display-only
//    fields. Names/plates in a live capture are therefore fixture stand-ins.
//  • Distance / duration: the wire `RidePlace` has no miles/minutes (those are a
//    routing concern, MYR-176/177). `place(_:)` maps them to 0; `record(from:)`
//    then fills the DESTINATION's estimate client-side from the pickup→dropoff
//    coordinates via `TripEstimate` (MYR-219 deliverable 1 — the same closed-form
//    the rider's Review/Booking already uses through `enterReview()`), so the
//    owner incoming card no longer shows "DISTANCE 0.0 mi / DRIVE TIME ~0 min".
//
// MYR-229 fixes the one gap that WAS a fixture leak rather than a documented
// v1 stand-in: pickup/destination `label`/`address` were already read off the
// real wire `RidePlace` (`place(_:)` below), but the owner card's REQUESTER
// name was hardcoded to the fixture "Sam" regardless of mode. `record(from:)`
// now folds contracts v0.11.0's `RideRequest.requesterName` onto
// `RideRequestRecord.requesterName` (defensive "Rider" fallback if the wire
// omits it), so a live incoming request shows the real requester.
enum RideRequestContractMapping {

    static func place(_ wire: MyRobotaxiContracts.RidePlace) -> RidePlace {
        RidePlace(
            id: wire.label,
            label: wire.label,
            subtitle: wire.address,
            miles: 0,
            minutes: 0,
            icon: "mappin",
            coordinate: CLLocationCoordinate2D(latitude: wire.lat, longitude: wire.lng)
        )
    }

    static func passenger(_ ride: RideRequest) -> RidePassenger? {
        guard let name = ride.passengerName, !name.isEmpty else { return nil }
        return RidePassenger(name: name, phone: ride.passengerPhone ?? "")
    }

    static func schedule(from scheduledFor: String?) -> RideSchedule? {
        guard let scheduledFor, let date = parseISO(scheduledFor) else { return nil }
        let dayFormatter = DateFormatter()
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        let calendar = Calendar.current
        let day: String
        if calendar.isDateInToday(date) { day = "Today" }
        else if calendar.isDateInTomorrow(date) { day = "Tomorrow" }
        else { dayFormatter.dateFormat = "EEE"; day = dayFormatter.string(from: date) }
        return RideSchedule(day: day, time: timeFormatter.string(from: date))
    }

    /// Map the wire lifecycle onto the app's 3-state sheet status. `requested →
    /// pending`; `accepted / enroute / arrived / completed → accepted` (v1 has no
    /// distinct enroute/arrived/completed UI — MYR-176/177); `declined → declined`.
    /// `cancelled` (and anything unrecognized) returns `nil`: the caller drops the
    /// active request rather than showing a dead card.
    static func status(_ wire: MyRobotaxiContracts.RideRequestStatus) -> RideRequestStatus? {
        switch wire {
        case .requested: return .pending
        case .accepted, .enroute, .arrived, .completed: return .accepted
        case .declined: return .declined
        case .cancelled, .unrecognized: return nil
        }
    }

    /// Build a full `RideRequestRecord` from a wire record — used on the OWNER
    /// side when a `ride_request_created` frame surfaces a request this device has
    /// no local draft for. Returns `nil` for a terminal/cancelled wire status.
    static func record(from ride: RideRequest) -> RideRequestRecord? {
        guard let appStatus = status(ride.status) else { return nil }
        let pickup = place(ride.pickup)
        let input = RideRequestInput(
            pickup: pickup,
            // MYR-219 deliverable 1: the wire dropoff carries no miles/minutes
            // (routing is MYR-176/177), so `place(_:)` maps them to 0 — which made
            // the owner incoming card's DISTANCE/DRIVE TIME read "0.0 mi / ~0 min"
            // for a live request. Fill the estimate from the pickup→dropoff
            // coordinates client-side. `TripEstimate.applied` gates on
            // `minutes == 0`, so it only fires for this live wire path; the
            // fixture/sim records (built with baked miles/minutes and never routed
            // through this mapping) are untouched.
            destination: TripEstimate.applied(to: place(ride.dropoff), pickup: pickup.coordinate),
            fleetMemberID: RideRequestFixtures.fleet[0].id, // display-only fallback — see enum header
            passenger: passenger(ride),
            schedule: schedule(from: ride.scheduledFor)
        )
        var record = RideRequestRecord(
            id: ride.id,
            input: input,
            status: appStatus,
            requestedAt: parseISO(ride.createdAt) ?? Date()
        )
        record.acceptedAt = ride.acceptedAt.flatMap(parseISO)
        // MYR-229: contracts v0.11.0's `requesterName` (server "first name ->
        // email local-part -> Rider" fallback). Defensive fallback here too —
        // even if the wire omits it (the field is OPTIONAL/additive), a LIVE
        // record must never fall through to the fixture "Sam"
        // (`RideRequestRecord.requesterDisplayName`'s doc comment, CLAUDE.md
        // "no fixtures on the live path").
        record.requesterName = ride.requesterName ?? "Rider"
        // v1 has no live-tracking progress (MYR-176/177). An accepted ride mounts
        // the tracking sheet at the static seed so it shows "heading to pickup"
        // without inventing a progress ticker.
        if appStatus == .accepted {
            record.trackProgress = RideRequestTiming.autoAcceptInitialProgress
        }
        return record
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseISO(_ string: String) -> Date? {
        isoFractional.date(from: string) ?? isoPlain.date(from: string)
    }
}
