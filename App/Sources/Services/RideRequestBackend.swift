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
    /// MYR-270 — owner confirms pickup (`accepted → arrived`), idempotent on an
    /// already-`arrived` ride (200), else `409`. Owner-only.
    func pickedUp(rideID: String) async throws -> RideRequest
    /// MYR-270 — rider starts the ride (`arrived → enroute`), pushing the dropoff
    /// nav server-side. Idempotent on already-`enroute` (200), else `409`. Rider-only.
    func start(rideID: String) async throws -> RideRequest
    /// MYR-270 — owner completes the ride (`enroute → completed`), idempotent on
    /// already-`completed` (200), else `409`. Owner-only.
    func droppedOff(rideID: String) async throws -> RideRequest
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
//    fixture picker supplies. MYR-264 — the real `vehicleId` is now PRESERVED as
//    the record's `fleetMemberID` (it was being overwritten with the fixture
//    `fleet[0].id`, which leaked "Model Y"/"Alex" onto the LIVE owner sheet). The
//    owner incoming surface JOINs that id to the real loaded fleet for the true
//    vehicle name; the rider surfaces use `SharedViewerState.liveFleetMember`
//    (MYR-212). `RideRequestInput.fleetMember` still resolves the id against the
//    fixtures, but that fallback is consulted on the SIM path only — a live id
//    matches no fixture, and every live fleet-member field renders off the real
//    join instead (MYR-228: no fixtures on the live path).
//  • Rider identity: MYR-264 preserves the wire `requesterName` onto the record so
//    the owner sheet shows the REAL rider ("<Name> wants a ride"), falling back to
//    a neutral role label only when the wire carried no name.
//  • Distance / duration: the wire `RidePlace` has no miles/minutes (those are a
//    routing concern, MYR-176/177). `place(_:)` maps them to 0; `record(from:)`
//    then fills the DESTINATION's estimate client-side from the pickup→dropoff
//    coordinates via `TripEstimate` (MYR-219 deliverable 1 — the same closed-form
//    the rider's Review/Booking already uses through `enterReview()`), so the
//    owner incoming card no longer shows "DISTANCE 0.0 mi / DRIVE TIME ~0 min".
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

    /// Map the wire lifecycle onto the app's sheet status (MYR-270 — owner-driven
    /// dispatch v2). `requested → pending`; `accepted → accepted` (leg 1, car → pickup);
    /// `arrived → arrived` (rider picked up, awaiting the rider's Start — a DISTINCT
    /// app state now, no longer folded into enroute); `enroute → enroute` (leg 2, ride
    /// started, car → dropoff); `completed → completed` (dropped off); `declined →
    /// declined`. `cancelled` (and anything unrecognized) returns `nil`: the caller
    /// drops the active request rather than showing a dead card. Each of accepted/
    /// arrived/enroute/completed is preserved 1:1 so the owner status line + action
    /// button and the rider's Start CTA read the real state off this status (MYR-270).
    static func status(_ wire: MyRobotaxiContracts.RideRequestStatus) -> RideRequestStatus? {
        switch wire {
        case .requested: return .pending
        case .accepted: return .accepted
        case .arrived: return .arrived
        case .enroute: return .enroute
        case .completed: return .completed
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
            // MYR-264: preserve the REAL vehicle id (was `fleet[0].id`) so the owner
            // sheet can join it to the real fleet for the true vehicle name.
            fleetMemberID: ride.vehicleId,
            passenger: passenger(ride),
            schedule: schedule(from: ride.scheduledFor),
            // MYR-264: carry the REAL rider name through so the owner sheet shows
            // "<Name> wants a ride" (neutral fallback when the wire omits it).
            requesterName: ride.requesterName
        )
        var record = RideRequestRecord(
            id: ride.id,
            input: input,
            status: appStatus,
            requestedAt: parseISO(ride.createdAt) ?? Date()
        )
        record.acceptedAt = ride.acceptedAt.flatMap(parseISO)
        // MYR-265: v1 has no per-second progress ticker (MYR-176/177), so each
        // live leg mounts the tracking sheet at a STATIC anchor that positions
        // `TrackingLeg`/`atPickup`/the leg-fit camera correctly for that leg:
        //  • accepted (leg 1) → the heading-to-pickup seed;
        //  • enroute  (leg 2) → the aboard/heading-to-drop-off seed;
        //  • completed        → arrived (>= 0.999) so the rider lands on the summary.
        // Scheduled reservations never seed a live trip.
        if record.input.schedule == nil {
            switch appStatus {
            // MYR-270: accepted (leg 1) and arrived (car at pickup, awaiting start)
            // both mount the leg-1 heading-to-pickup framing — the rider sheet's
            // arrived "Your car is here" stage reads off the STATUS, not progress.
            case .accepted, .arrived: record.trackProgress = RideRequestTiming.autoAcceptInitialProgress
            case .enroute: record.trackProgress = record.enrouteSeedProgress
            case .completed: record.trackProgress = 1
            default: break
            }
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
