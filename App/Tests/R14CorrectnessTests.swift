import XCTest
import MyRoboTaxiKit
import MyRobotaxiContracts
@testable import MyRoboTaxi

// MARK: - The r14 correctness batch (MYR-381)
//
// Four defects from one TestFlight session, and three of them turn out to be the
// same sentence pointed at different surfaces: **a ride that has ended is still
// driving the app**. A refused cancel kept its reason to itself; a declined record
// kept etching its route and re-raising its card; the reservation lists kept
// showing a world the socket had already corrected.
//
// The wire-level half of defect 1 lives in `ReservationCancelWireTests` (the
// request BYTES, through the production composition). This file is the rules.
final class R14CorrectnessTests: XCTestCase {

    // MARK: - 1. Cancel: classified, reconciled, recorded

    func testAServerRefusalAndAnUnansweredCallAreDifferentFailures() {
        XCTAssertEqual(
            ReservationCancelFailure.classify(RestError.http(status: 409, code: .conflict, message: nil, subCode: nil)),
            .refused(status: 409, code: "conflict")
        )
        XCTAssertEqual(
            ReservationCancelFailure.classify(RestError.http(status: 403, code: .permissionDenied, message: nil, subCode: nil)),
            .refused(status: 403, code: "permission_denied")
        )
        XCTAssertEqual(
            ReservationCancelFailure.classify(RestError.transport(underlying: URLError(.notConnectedToInternet))),
            .unreachable,
            "no answer is not a refusal — the client cannot assert what the server did"
        )
        XCTAssertEqual(
            ReservationCancelFailure.classify(RestError.decoding(underlying: URLError(.cannotParseResponse))),
            .unreachable
        )
        XCTAssertEqual(ReservationCancelFailure.classify(CancellationError()), .unreachable)
    }

    /// THE RECONCILE. The commonest refusal by far is a `409` on a ride that has
    /// already moved on, and the re-read both stores perform comes back without the
    /// row. Announcing that as a failure tells the rider their ride is still booked
    /// when it is not.
    func testARefusalWhoseReservationHasGoneIsNotReportedAtAll() {
        XCTAssertEqual(
            ReservationCancelOutcome.resolve(
                failure: .refused(status: 409, code: "conflict"),
                stillHeld: false,
                copy: .rider
            ),
            .cancelled
        )
        XCTAssertEqual(
            ReservationCancelOutcome.resolve(failure: nil, stillHeld: true, copy: .rider),
            .cancelled,
            "a 2xx is a cancel even if the list has not caught up yet"
        )
        XCTAssertEqual(
            ReservationCancelOutcome.resolve(
                failure: .refused(status: 409, code: "conflict"),
                stillHeld: true,
                copy: .rider
            ),
            .refused(notice: ReservationCancelCopy.rider.refused)
        )
        XCTAssertEqual(
            ReservationCancelOutcome.resolve(failure: .unreachable, stillHeld: true, copy: .owner),
            .refused(notice: ReservationCancelCopy.owner.unreachable)
        )
    }

    /// The two sentences must not be interchangeable: one says the server decided,
    /// the other says nobody answered, and a rider acts differently on each.
    func testTheTwoFailureSentencesSayDifferentThings() {
        for copy in [ReservationCancelCopy.rider, .owner] {
            XCTAssertNotEqual(copy.refused, copy.unreachable)
            XCTAssertFalse(copy.refused.isEmpty)
            XCTAssertFalse(copy.unreachable.isEmpty)
        }
        XCTAssertTrue(
            ReservationCancelCopy.rider.unreachable.contains("still booked"),
            "an unanswered cancel must not claim the ride is gone"
        )
        // No invented affordance: neither surface has a pull-to-refresh, and a
        // refusal that tells someone to perform a gesture that does not exist is a
        // second defect wearing an apology.
        for copy in [ReservationCancelCopy.rider, .owner] {
            XCTAssertFalse(copy.refused.lowercased().contains("refresh"))
            XCTAssertFalse(copy.refused.lowercased().contains("pull"))
        }
    }

    /// The store's whole path, over the SOURCE seam: a refusal whose re-read still
    /// lists the row keeps the row AND says why; a refusal whose re-read drops it is
    /// silent.
    @MainActor
    func testTheRiderStoreReportsOnlyARefusalThatLeftTheRideStanding() async {
        let stubborn = StubCancelSource(rides: [Self.row(id: "s1")], removesOnCancel: false)
        stubborn.cancelFailure = RestError.http(status: 409, code: .conflict, message: nil, subCode: nil)
        let store = RiderScheduledRidesStore(source: stubborn)
        await store.load()
        await store.cancel(id: "s1")
        XCTAssertEqual(store.rides.map(\.id), ["s1"], "never optimistically removed")
        XCTAssertEqual(store.failureNotice, ReservationCancelCopy.rider.refused)

        // The same refusal, but the ride is gone by the time the list is re-read —
        // the ride ended somewhere else, which is what the rider asked for.
        let raced = StubCancelSource(rides: [Self.row(id: "s2")], removesOnCancel: true)
        raced.cancelFailure = RestError.http(status: 409, code: .conflict, message: nil, subCode: nil)
        let racedStore = RiderScheduledRidesStore(source: raced)
        await racedStore.load()
        await racedStore.cancel(id: "s2")
        XCTAssertTrue(racedStore.rides.isEmpty)
        XCTAssertNil(racedStore.failureNotice, "the list agrees with the tap — there is nothing to report")
    }

    /// A read that did not ANSWER must never be read as "the ride is gone" — the one
    /// outcome with a person standing at a kerb at the end of it.
    @MainActor
    func testAnUnreadableListAfterARefusalStillReportsTheRefusal() async {
        let source = StubCancelSource(rides: [Self.row(id: "s3")], removesOnCancel: false)
        source.cancelFailure = RestError.http(status: 409, code: .conflict, message: nil, subCode: nil)
        let store = RiderScheduledRidesStore(source: source)
        await store.load()
        source.readFailure = RestError.http(status: 503, code: nil, message: nil, subCode: nil)

        await store.cancel(id: "s3")
        XCTAssertEqual(store.failureNotice, ReservationCancelCopy.rider.refused)
        XCTAssertEqual(store.rides.map(\.id), ["s3"], "the held list stands (MYR-326)")
    }

    @MainActor
    func testTheOwnerStateReportsOnlyARefusalThatLeftTheReservationStanding() async {
        let stubborn = StubDeclineSource(rows: [Self.reservation(id: "r1")], removesOnDecline: false)
        stubborn.declineFailure = RestError.http(status: 409, code: .conflict, message: nil, subCode: nil)
        let state = OwnerDrivesState(live: true, reservations: stubborn)
        await state.loadUpcoming(vehicleID: "veh-live")
        await state.cancelReservation(id: "r1", vehicleID: "veh-live")
        XCTAssertEqual(state.upcoming.map(\.id), ["r1"])
        XCTAssertEqual(state.cancelFailureNotice, ReservationCancelCopy.owner.refused)

        let raced = StubDeclineSource(rows: [Self.reservation(id: "r2")], removesOnDecline: true)
        raced.declineFailure = RestError.http(status: 409, code: .conflict, message: nil, subCode: nil)
        let racedState = OwnerDrivesState(live: true, reservations: raced)
        await racedState.loadUpcoming(vehicleID: "veh-live")
        await racedState.cancelReservation(id: "r2", vehicleID: "veh-live")
        XCTAssertTrue(racedState.upcoming.isEmpty)
        XCTAssertNil(racedState.cancelFailureNotice)
    }

    // MARK: - 2. A route dies with its ride

    func testOnlyALiveRideMayBearARoute() {
        XCTAssertTrue(RiderRouteLifetime.bearsRoute(status: .pending))
        XCTAssertTrue(RiderRouteLifetime.bearsRoute(status: .accepted))
        XCTAssertTrue(RiderRouteLifetime.bearsRoute(status: .arrived))
        XCTAssertTrue(RiderRouteLifetime.bearsRoute(status: .enroute))
        XCTAssertFalse(RiderRouteLifetime.bearsRoute(status: .declined), "the client's 1,000-mile etch")
        XCTAssertTrue(
            RiderRouteLifetime.bearsRoute(status: .completed),
            "the Ride Summary's hero IS that polyline — a completed route is released with the SLOT, not at the status"
        )
    }

    // MARK: - 3. A dismissed decline stays dismissed

    func testADismissedDeclineNeverRaisesTheNoticeAgain() {
        XCTAssertTrue(RiderDeclinedNotice.shouldRaise(status: .declined, rideID: "d1", acknowledgedID: nil))
        XCTAssertFalse(
            RiderDeclinedNotice.shouldRaise(status: .declined, rideID: "d1", acknowledgedID: "d1"),
            "however many times the record is re-folded"
        )
        XCTAssertTrue(
            RiderDeclinedNotice.shouldRaise(status: .declined, rideID: "d2", acknowledgedID: "d1"),
            "the NEXT declined ride is a different ride"
        )
        XCTAssertFalse(RiderDeclinedNotice.shouldRaise(status: .accepted, rideID: "d1", acknowledgedID: nil))
        XCTAssertFalse(RiderDeclinedNotice.shouldRaise(status: .declined, rideID: nil, acknowledgedID: nil))
    }

    /// The acknowledgement covers the PHASE too. Lowering only the card would leave
    /// every reconcile still pulling the rider out of the idle sheet onto `.search`
    /// for a ride they have finished with.
    func testAnAcknowledgedDeclineDoesNotMoveTheSheetEither() {
        XCTAssertEqual(
            SharedViewerScreen.reconciledPhase(
                status: .declined, isDormantReservation: false, current: .idle, isAcknowledgedDecline: false
            ),
            .search
        )
        XCTAssertNil(
            SharedViewerScreen.reconciledPhase(
                status: .declined, isDormantReservation: false, current: .idle, isAcknowledgedDecline: true
            )
        )
    }

    @MainActor
    func testAcknowledgingLowersTheCardAndRecordsTheRide() {
        let state = SharedViewerState()
        state.showDeclinedNotice = true
        state.acknowledgeDeclined(rideID: "d9")
        XCTAssertFalse(state.showDeclinedNotice)
        XCTAssertEqual(state.acknowledgedDeclinedRideID, "d9")

        // MYR-381 — `resetDraftToIdle` (what Dismiss also calls) must not forget it:
        // the whole point is that the acknowledgement outlives the draft AND the view.
        state.resetDraftToIdle()
        XCTAssertEqual(state.acknowledgedDeclinedRideID, "d9")
    }

    // MARK: - 4. The scheduled surfaces react to the socket

    /// A `ride_status_changed` frame for a SCHEDULED ride bumps the tick the
    /// reservation surfaces re-read on. Driven through the REAL socket path
    /// (frame → detail refetch → integrate), not by calling the counter.
    @MainActor
    func testAScheduledFrameTicksTheReservationSurfaces() async {
        let api = TickAPI(detail: Self.wire(id: "srv-s1", scheduled: true, status: .declined))
        let socket = TickSocket()
        let service = LiveRideRequestService(api: api, socket: socket, autoStart: true)
        await eventually { await socket.isListening }
        XCTAssertEqual(service.scheduledSurfaceTick, 0)

        await socket.push(.statusChanged(RideStatusChangedPayload(
            rideRequestId: "srv-s1", vehicleId: "veh-live", status: .declined, timestamp: "2026-07-31T13:11:00.000Z"
        )))
        await eventually { await MainActor.run { service.scheduledSurfaceTick > 0 } }
    }

    /// An INSTANT ride's frames must NOT spend a reservation refetch — they arrive
    /// several times per ride and no reservation list is about them.
    @MainActor
    func testAnInstantFrameDoesNotTickTheReservationSurfaces() async {
        let api = TickAPI(detail: Self.wire(id: "srv-i1", scheduled: false, status: .accepted))
        let socket = TickSocket()
        let service = LiveRideRequestService(api: api, socket: socket, autoStart: true)
        await eventually { await socket.isListening }

        await socket.push(.statusChanged(RideStatusChangedPayload(
            rideRequestId: "srv-i1", vehicleId: "veh-live", status: .accepted, timestamp: "2026-07-31T13:11:00.000Z"
        )))
        // Give the frame a real chance to be integrated before asserting a NEGATIVE:
        // the detail refetch is the step immediately before `integrate`.
        await eventually { await api.detailCount >= 1 }
        // …and one more turn of the main actor, so the integrate that follows it has
        // certainly run.
        await Task.yield()
        XCTAssertEqual(service.scheduledSurfaceTick, 0)
    }

    private func eventually(timeout: TimeInterval = 3, _ condition: @escaping () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("condition never became true")
    }

    /// The SIMULATED service can never tick, which is what keeps every DEBUG scene
    /// and drift-gate capture out of reach of this wiring.
    @MainActor
    func testTheSimulatedServiceNeverTicks() {
        XCTAssertEqual(SimulatedRideRequestService().scheduledSurfaceTick, 0)
    }

    // MARK: - 4b. The header counts what it renders

    /// `ForEach` draws ONE row per id, so a duplicate across a cursor page boundary
    /// would be counted by the header and never drawn — the client's
    /// "1 scheduled · 1 confirmed" over a list that does not add up.
    func testDuplicateWireRowsCollapseSoCountsMatchRenderedRows() {
        let duplicated = [
            Self.wire(id: "dupe", scheduled: true),
            Self.wire(id: "dupe", scheduled: true),
            Self.wire(id: "other", scheduled: true)
        ]
        let rows: [ScheduledRide] = RiderScheduledRideMapping.rides(from: duplicated, vehicles: [:], now: Date())
        XCTAssertEqual(rows.map(\.id).sorted(), ["dupe", "other"])
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count, "count == rendered rows, structurally")
    }

    // MARK: - Fixtures

    private static func row(id: String) -> ScheduledRide {
        RiderScheduledRideMapping.ride(from: wire(id: id, scheduled: true), vehicle: nil, now: Date())!
    }

    private static func reservation(id: String) -> UpcomingReservation {
        LiveUpcomingReservations.reservation(from: wire(id: id, scheduled: true))!
    }

    /// Tomorrow noon UTC, accepted, undispatched — dormant for the rider, upcoming
    /// for the owner.
    static func wire(
        id: String,
        scheduled: Bool,
        status: MyRobotaxiContracts.RideRequestStatus = .accepted
    ) -> MyRobotaxiContracts.RideRequest {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return MyRobotaxiContracts.RideRequest(
            id: id,
            riderId: "u-rider",
            ownerId: "u-owner",
            vehicleId: "veh-live",
            pickup: RidePlace(lat: 33.0198, lng: -96.6989, label: "Home"),
            dropoff: RidePlace(lat: 32.9346, lng: -96.8206, label: "Galleria Dallas"),
            status: status,
            scheduledFor: scheduled ? formatter.string(from: Date().addingTimeInterval(24 * 3600)) : nil,
            createdAt: "2026-07-31T05:00:00.000Z",
            updatedAt: "2026-07-31T05:04:00.000Z",
            acceptedAt: "2026-07-31T05:04:00.000Z"
        )
    }
}

// MARK: - Stubs

/// A `RiderScheduledRideSource` whose cancel FAILS while the list may or may not
/// still carry the row — the two arms the reconcile turns on.
private final class StubCancelSource: RiderScheduledRideSource, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ScheduledRide]
    private let removesOnCancel: Bool
    var cancelFailure: (any Error)?
    var readFailure: (any Error)?

    init(rides: [ScheduledRide], removesOnCancel: Bool) {
        stored = rides
        self.removesOnCancel = removesOnCancel
    }

    func scheduledRides(now: Date) async throws -> [ScheduledRide] {
        if let readFailure { throw readFailure }
        return lock.withLock { stored }
    }

    func cancel(rideID: String) async throws {
        if removesOnCancel { lock.withLock { stored.removeAll { $0.id == rideID } } }
        if let cancelFailure { throw cancelFailure }
        lock.withLock { stored.removeAll { $0.id == rideID } }
    }
}

/// The narrowest `RideRequestAPI` that can carry a WS frame all the way to
/// `integrate`: the frame's detail refetch is the only call the tick path makes.
private actor TickAPI: RideRequestAPI {
    private let detail: MyRobotaxiContracts.RideRequest
    private(set) var detailCount = 0

    init(detail: MyRobotaxiContracts.RideRequest) { self.detail = detail }

    func vehicles() async throws -> [VehicleSummary] { [] }
    func createRideRequest(_ body: RideRequestCreateRequest) async throws -> MyRobotaxiContracts.RideRequest { detail }
    func rideRequests(cursor: String?, limit: Int) async throws -> RideRequestsListResponse {
        RideRequestsListResponse(items: [], hasMore: false)
    }
    func rideRequest(id: String) async throws -> MyRobotaxiContracts.RideRequest {
        detailCount += 1
        return detail
    }
    func cancelRideRequest(id: String) async throws -> MyRobotaxiContracts.RideRequest { detail }
    func acceptRideRequest(id: String) async throws -> MyRobotaxiContracts.RideRequest { detail }
    func declineRideRequest(id: String) async throws -> MyRobotaxiContracts.RideRequest { detail }
    func pickedUp(rideID: String) async throws -> MyRobotaxiContracts.RideRequest { detail }
    func start(rideID: String) async throws -> MyRobotaxiContracts.RideRequest { detail }
    func droppedOff(rideID: String) async throws -> MyRobotaxiContracts.RideRequest { detail }
    func incomingRideRequests(cursor: String?, limit: Int) async throws -> RideRequestsListResponse {
        RideRequestsListResponse(items: [], hasMore: false)
    }
    func upcomingReservations(vehicleID: String, cursor: String?, limit: Int) async throws -> RideRequestsListResponse {
        RideRequestsListResponse(items: [], hasMore: false)
    }
}

private actor TickSocket: RideEventStreaming {
    private var continuation: AsyncStream<RideRequestEvent>.Continuation?
    var isListening: Bool { continuation != nil }

    func rideEvents() async -> AsyncStream<RideRequestEvent> {
        let (stream, continuation) = AsyncStream<RideRequestEvent>.makeStream()
        self.continuation = continuation
        return stream
    }
    func connect() async {}
    func disconnect() async {}
    func push(_ event: RideRequestEvent) { continuation?.yield(event) }
}

private final class StubDeclineSource: UpcomingReservationSource, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [UpcomingReservation]
    private let removesOnDecline: Bool
    var declineFailure: (any Error)?

    init(rows: [UpcomingReservation], removesOnDecline: Bool) {
        stored = rows
        self.removesOnDecline = removesOnDecline
    }

    func upcomingReservations(vehicleID: String) async throws -> [UpcomingReservation] {
        lock.withLock { stored }
    }

    func decline(reservationID: String) async throws {
        if removesOnDecline { lock.withLock { stored.removeAll { $0.id == reservationID } } }
        if let declineFailure { throw declineFailure }
        lock.withLock { stored.removeAll { $0.id == reservationID } }
    }
}
