#if DEBUG
import Foundation
import MyRoboTaxiKit
import MyRobotaxiContracts

// MARK: - DebugRideRequestEndpoint (MYR-360 — drift-gate / screenshot only)
//
// A stand-in for the ride-request REST surface, so the two ride-share PAUSE WARNING
// scenes can drive the SHIPPING path end to end without a live backend:
//
//   `RideSharePauseFlow.setEnabled(false, …)`
//     → the production `LiveUpcomingReservations`
//       → `GET /api/ride-requests/incoming?upcomingForVehicle=…` (this stub)
//         → `RideRequestContractMapping.record(from:)` (the real fold)
//           → `IncomingRequestDisplay.resolve(…)` (the real name rule)
//             → `RideSharePauseDialog.warning(…)` (the real copy)
//
// So every string in the capture — the pickup stamps, the rider names, the
// pluralised confirm label, the "+N more" rollup — is what the shipping code
// produced from a wire payload, not a hand-set array. Same "real code path,
// injected wire" precedent as `DebugServiceWindowEndpoint` and
// `DebugShareEndpoint`.
//
// Only the two upcoming-reservation methods are meaningful; everything else on
// `RideRequestAPI` exists to keep the conformance total and is never called by
// this flow. Release builds never compile this file.
struct DebugRideRequestEndpoint: RideRequestAPI {
    /// The wire rows the scene's vehicle has booked, soonest first — exactly as the
    /// server orders them. Answers the OWNER-scoped incoming/upcoming endpoint.
    var reservations: [MyRobotaxiContracts.RideRequest] = []
    /// MYR-377 — the RIDER-scoped list (`GET /api/ride-requests`), which is a
    /// different endpoint answering a different question, so it is a different
    /// array rather than the same one served twice.
    var rides: [MyRobotaxiContracts.RideRequest] = []

    func upcomingReservations(vehicleID: String, cursor: String?, limit: Int) async throws -> RideRequestsListResponse {
        // ONE page, final: `hasMore: false` + a null cursor, the shape the endpoint
        // answers for any realistic reservation count. The paging loop's bound is
        // asserted in unit tests, not captured.
        RideRequestsListResponse(items: reservations, hasMore: false)
    }

    func declineRideRequest(id: String) async throws -> RideRequest {
        guard let ride = (reservations + rides).first(where: { $0.id == id }) else {
            throw RestError.http(status: 404, code: nil, message: nil, subCode: nil)
        }
        return ride
    }

    /// MYR-377 — the rider's own list, one page, final.
    func rideRequests(cursor: String?, limit: Int) async throws -> RideRequestsListResponse {
        RideRequestsListResponse(items: rides, hasMore: false)
    }

    // MARK: Unused conformance (never reached from these flows)

    func vehicles() async throws -> [VehicleSummary] { [] }
    func createRideRequest(_ body: RideRequestCreateRequest) async throws -> RideRequest {
        throw RestError.http(status: 501, code: nil, message: nil, subCode: nil)
    }
    func rideRequest(id: String) async throws -> RideRequest { try await declineRideRequest(id: id) }
    func cancelRideRequest(id: String) async throws -> RideRequest { try await declineRideRequest(id: id) }
    func acceptRideRequest(id: String) async throws -> RideRequest { try await declineRideRequest(id: id) }
    func pickedUp(rideID: String) async throws -> RideRequest { try await declineRideRequest(id: rideID) }
    func start(rideID: String) async throws -> RideRequest { try await declineRideRequest(id: rideID) }
    func droppedOff(rideID: String) async throws -> RideRequest { try await declineRideRequest(id: rideID) }
    func incomingRideRequests(cursor: String?, limit: Int) async throws -> RideRequestsListResponse {
        RideRequestsListResponse(items: [], hasMore: false)
    }
}

// MARK: - The scenes' wire payloads

extension DebugRideRequestEndpoint {
    /// One ACCEPTED, future, scheduled reservation on `vehicleId`, shaped exactly as
    /// the server emits one. `requesterName` is the server-resolved FIRST name;
    /// passing `nil` produces the nameless case, which the client must render
    /// honestly rather than fill in.
    ///
    /// MYR-376/377 — `status` and the two DISPATCH fields are parameters now, all
    /// defaulted to the pre-existing values (`accepted`, undispatched), so every
    /// row the MYR-360 scenes build is byte-identical. They exist because the whole
    /// point of the reservation-lifecycle captures is the difference between a
    /// reservation the sweeper has fired for and one it has not.
    static func reservation(
        id: String,
        vehicleID: String,
        requesterName: String?,
        scheduledFor: Date,
        status: MyRobotaxiContracts.RideRequestStatus = .accepted,
        dispatchedAt: Date? = nil,
        dispatchStatus: MyRobotaxiContracts.DispatchStatus? = nil
    ) -> MyRobotaxiContracts.RideRequest {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        iso.timeZone = TimeZone(secondsFromGMT: 0)
        let created = iso.string(from: Date())
        return MyRobotaxiContracts.RideRequest(
            id: id,
            riderId: "cluser0000000000rider0",
            ownerId: "cluser0000000000owner0",
            vehicleId: vehicleID,
            pickup: MyRobotaxiContracts.RidePlace(lat: 37.7749, lng: -122.4194, label: "Home"),
            dropoff: MyRobotaxiContracts.RidePlace(
                lat: 37.6156,
                lng: -122.3900,
                label: "SFO \u{00B7} Terminal 2",
                address: "San Francisco International"
            ),
            status: status,
            scheduledFor: iso.string(from: scheduledFor),
            createdAt: created,
            updatedAt: created,
            // A `requested` row has not been accepted, so it must not carry an
            // `acceptedAt` — a wire shape the server does not emit is a stub that
            // teaches the client something untrue (MYR-362).
            acceptedAt: status == .requested ? nil : created,
            dispatchStatus: dispatchStatus,
            dispatchedAt: dispatchedAt.map { iso.string(from: $0) },
            requesterName: requesterName
        )
    }

    /// The client's own condition, as a date: the NEXT Saturday at 5:30 PM local —
    /// the reservation time MYR-312/313 captured, and the one in the issue's copy.
    /// Computed relative to `now` rather than hardcoded, for the same reason
    /// `DebugScene.sampleServiceEnd` is: a literal drifts into the past and the
    /// endpoint's own future-only predicate would then exclude it.
    static func sampleReservationDate(
        daysAhead: Int = 0,
        hour: Int = 17,
        minute: Int = 30,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date {
        let today = calendar.startOfDay(for: now)
        let currentWeekday = calendar.component(.weekday, from: today)
        let toSaturday = ((7 - currentWeekday + 7) % 7 == 0) ? 7 : (7 - currentWeekday + 7) % 7
        let saturday = calendar.date(byAdding: .day, value: toSaturday + daysAhead, to: today) ?? today
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: saturday) ?? saturday
    }
}
#endif
