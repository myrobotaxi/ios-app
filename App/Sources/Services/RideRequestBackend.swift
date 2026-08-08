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
    /// MYR-360 — the owner's ACCEPTED, strictly-FUTURE reservations for ONE
    /// vehicle, soonest first (`GET /api/ride-requests/incoming
    /// ?upcomingForVehicle={id}`). The pause warning's whole input: it is what the
    /// owner is about to strand by pausing ride sharing, so it is read BEFORE the
    /// pause is committed rather than reconciled afterwards.
    func upcomingReservations(vehicleID: String, cursor: String?, limit: Int) async throws -> RideRequestsListResponse
}

extension RestClient: RideRequestAPI {}

protocol RideEventStreaming: Sendable {
    func rideEvents() async -> AsyncStream<RideRequestEvent>
    func connect() async
    func disconnect() async
    /// MYR-424 — the app came to the foreground; recover the connection if it has
    /// settled. See the extension below for why this had to exist.
    func handleForeground() async
}

extension RideEventStreaming {
    /// Default: nothing to recover. Test doubles and any future non-socket stream
    /// inherit this; only the real socket has a supervisor that can settle.
    func handleForeground() async {}
}

// MYR-424 — THE RIDE SOCKET WAS THE ONE SOCKET NOBODY WOKE UP.
//
// `TelemetrySocket.handleForegroundTransition()` has always existed (NFR-3.36a),
// and the app wires it for the owner fleet (`LiveVehicleFleet`) and for the
// rider's vehicle locator (`RiderLiveVehicleLocator`). The socket that carries
// RIDE frames — composed separately in `RideRequestComposition`, per that file's
// own note — was never given it. That matters because `TelemetrySocket.supervise()`
// BREAKS OUT PERMANENTLY on a terminal failure (`auth_failed`): it clears its
// supervisor, settles `.disconnected`, and never retries. `handleForegroundTransition`
// is the only thing in the API that restarts a nil supervisor. So a ride socket
// that went terminal once stayed dead for the whole process, and the rider
// pipeline went deaf to every `ride_status_changed` frame — MYR-387's finding,
// still uncovered on this socket, and the second of the two roads into r20.
extension TelemetrySocket: RideEventStreaming {
    func handleForeground() async { handleForegroundTransition() }
}

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

    // MARK: - Schedule → wire `scheduledFor` (MYR-179)
    //
    // The INVERSE of `schedule(from:)` above, and the piece MYR-179 says was
    // missing: `LiveRideRequestService.createBody` used to send `scheduledFor:
    // nil` with a "deferred" comment, so a "Sat 5:30 PM" reservation was an
    // INSTANT ride server-side (verified in production: every `go_ride_requests`
    // row had `scheduled_for IS NULL`), and every scheduled exemption — the
    // per-rider `ride_active` guard, the per-vehicle one-active-ride index
    // (MYR-266), MYR-313's accept-gate exemption — silently never applied.
    //
    // The app's `RideSchedule` is a pair of DISPLAY strings straight off the
    // picker (`RideScheduleDays.days(now:)` × `RideScheduleTimes.grid`):
    // a day token and a 12-hour wall clock ("5:30 PM"). MYR-370 made the day
    // token carry its DATE ("Thu, Aug 6") instead of a bare weekday; the bare
    // weekdays below are the legacy shape, still resolved so a schedule
    // committed by an older build stays readable.
    // Resolution therefore needs a calendar + an instant, both INJECTED so the
    // rule is deterministic under test (the `DriveContractMapping.dateGroup(…,
    // now:)` precedent) and correct at runtime, where the defaults are the
    // rider's own device clock and time zone.

    /// Resolve a picked day/time into the RFC 3339 UTC instant the create body
    /// carries, or `nil` for an on-demand ("Now") request / an unparseable time.
    ///
    /// Rules (all evaluated in `calendar`'s time zone — the rider's, at submit):
    ///  • "Today" (and any unrecognized token): today's date at the picked wall
    ///    clock, rolled forward ONE day when that instant has already passed —
    ///    a reservation is never in the past.
    ///  • "Tomorrow": the next calendar day at the picked wall clock.
    ///  • A weekday token ("Thu"…"Mon", the picker's explicit days): the NEXT
    ///    date carrying that weekday, starting from today; when that lands on
    ///    today and the wall clock has already passed, the following week's.
    ///
    /// Encoded UTC with milliseconds — the exact shape the server emits
    /// ("2026-07-11T06:30:00.000Z"), so a create round-trips through
    /// `schedule(from:)` to the same card copy the rider saw.
    static func scheduledFor(
        from schedule: RideSchedule?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        guard let date = scheduledDate(from: schedule, now: now, calendar: calendar) else { return nil }
        return isoUTC.string(from: date)
    }

    /// The resolved absolute instant behind `scheduledFor(from:)` — split out so
    /// the encoding matrix can assert the instant itself, not a string.
    static func scheduledDate(
        from schedule: RideSchedule?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date? {
        guard let schedule, let clock = clockComponents(schedule.time) else { return nil }
        let today = calendar.startOfDay(for: now)
        let token = schedule.day.trimmingCharacters(in: .whitespaces).lowercased()

        let day: Date
        let rollBy: Int // days added when the resolved instant is already past
        switch token {
        case "tomorrow":
            day = calendar.date(byAdding: .day, value: 1, to: today) ?? today
            rollBy = 0 // tomorrow's wall clock is never in the past
        case _ where RideScheduleDays.datedTokenDayStart(forToken: schedule.day, now: now, calendar: calendar) != nil:
            // MYR-370 — an EXPLICIT DATE ("Thu, Aug 6"), which is what the picker
            // mints from its third chip on. There is nothing to roll: the token
            // names one calendar day, and that day is printed on the chip, on the
            // "Set pickup ·" CTA and on the Review badge. Rolling it would move
            // the reservation off the date the rider was shown — which is the
            // MYR-370 defect itself, just arrived at from the other direction.
            day = RideScheduleDays.datedTokenDayStart(forToken: schedule.day, now: now, calendar: calendar) ?? today
            rollBy = 0
        case _ where weekdayIndex(token) != nil:
            // An EXPLICIT picked weekday: the next date carrying it (today counts).
            let target = weekdayIndex(token)!
            let current = calendar.component(.weekday, from: today)
            let delta = (target - current + 7) % 7
            day = calendar.date(byAdding: .day, value: delta, to: today) ?? today
            rollBy = 7 // "Sat" at a time already gone today means NEXT Saturday
        default:
            day = today // "Today", and any token the picker grows later
            rollBy = 1
        }

        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = clock.hour
        components.minute = clock.minute
        components.second = 0
        guard let resolved = calendar.date(from: components) else { return nil }
        guard resolved <= now, rollBy > 0 else { return resolved }
        return calendar.date(byAdding: .day, value: rollBy, to: resolved) ?? resolved
    }

    /// "5:30 PM" → (17, 30). Parsed with a FIXED locale + UTC so the picker's
    /// English 12-hour strings resolve to plain numbers regardless of the
    /// device's locale/zone; the zone is applied later by `calendar`.
    private static func clockComponents(_ time: String) -> (hour: Int, minute: Int)? {
        guard let parsed = clockParser.date(from: time.trimmingCharacters(in: .whitespaces)) else { return nil }
        let components = utcCalendar.dateComponents([.hour, .minute], from: parsed)
        guard let hour = components.hour, let minute = components.minute else { return nil }
        return (hour, minute)
    }

    /// "thu" → 5 (`Calendar`'s Sunday-based weekday index), or `nil` when the
    /// token isn't a weekday (→ the "Today" branch).
    private static func weekdayIndex(_ token: String) -> Int? {
        weekdayTokens.firstIndex(of: token).map { $0 + 1 }
    }

    /// Sunday-first, matching `Calendar.component(.weekday:)`'s 1...7.
    private static let weekdayTokens = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    private static let clockParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "h:mm a"
        return f
    }()

    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()

    /// The wire's documented `scheduledFor` shape: RFC 3339 UTC with
    /// milliseconds, exactly as the server emits it.
    private static let isoUTC: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    /// Map the wire lifecycle onto the app's sheet status (MYR-270 — owner-driven
    /// dispatch v2). `requested → pending`; `accepted → accepted` (leg 1, car → pickup);
    /// `arrived → arrived` (car at the curb, awaiting the rider's Start — a DISTINCT
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
        // MYR-414 — the server's own drop-off instant. It has been on the wire
        // since §7.8 shipped and nothing in this app read it, which is why the
        // rider's summary had no honest end for its trip span and fell back to
        // re-labelling the search sheet's ESTIMATE as what the ride took. Mapped
        // here, in the ONE wire→record rule, so both pipelines get it from the same
        // place. **`enrouteObservedAt` is deliberately NOT set here**: this method
        // is a FIRST SIGHTING (a frame for a ride we do not hold, a cold adoption),
        // and a first sighting has observed no transition — see `RideTripSpan`.
        record.completedAt = ride.completedAt.flatMap(parseISO)
        // MYR-376/377 — THE THREE RESERVATION FACTS.
        //
        // `record(from:)` folded `scheduledFor` into a pair of DISPLAY strings and
        // dropped `dispatchStatus`/`dispatchedAt` on the floor — the app source had
        // literally zero references to either — so no surface in this app could
        // tell a reservation the server had dispatched from one it had not. That
        // absence is the whole of the MYR-376 defect: the owner's dispatch card is
        // gated on status alone, and `accepted` is `accepted` whether the ride is
        // happening now or tomorrow at noon.
        //
        // Carried unconditionally rather than only for scheduled rides: an INSTANT
        // ride is dispatched at accept time, and a client that can see that is a
        // client that can stop guessing later.
        record.scheduledFor = ride.scheduledFor.flatMap(parseISO)
        record.dispatchStatus = ride.dispatchStatus
        record.dispatchedAt = ride.dispatchedAt.flatMap(parseISO)
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
