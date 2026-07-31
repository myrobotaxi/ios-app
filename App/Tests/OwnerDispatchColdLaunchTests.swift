import CoreLocation
@testable import MyRoboTaxi
import MyRoboTaxiKit
import MyRobotaxiContracts
import XCTest

// MARK: - MYR-396 — the owner's live dispatch survives a force-quit
//
// THE DEFECT, from TestFlight r16 (build 202607311641): *"When I close out the app
// the owner loses the UI of the current ride in progress."* Force-quit during an
// accepted/arrived/enroute ride, relaunch, and owner Home renders as if no ride
// exists — no dispatch card, no status line, no "Picked up" / "Dropped off".
//
// THE CAUSE IS AN ABSENCE, and it is spelled out in two sentences of §7.8.
// `LiveRideRequestService.start()` performs exactly two cold-launch reads:
//
//   • `adoptOpenRiderRide()` → `GET /api/ride-requests`, "the authenticated
//     RIDER's own requests" (`ListByRiderPage`, `rider_id = :sub`). A ride
//     somebody else booked on this owner's car is not on it at all.
//   • `refreshIncoming()`    → `GET /api/ride-requests/incoming`, status
//     `requested` ONLY — "decided rows leave the feed by construction". The
//     instant the owner taps Accept the ride leaves the one owner-scoped feed
//     there is.
//
// So NOTHING on the owner side reads an accepted ride back, and `ownerDispatch`
// is a projection of a pipeline that starts every process empty. The rider side
// has had cold-launch adoption since MYR-230 and gained the gone-live reservation
// arm in MYR-377; the owner side never had the equivalent.
//
// These tests drive the SHIPPING service against stubbed §7.8 endpoints with the
// real semantics of both (the rider list holds rider rows; the incoming feed
// filters to `requested`) — the pair whose blind spot IS the defect.
@MainActor
final class OwnerDispatchColdLaunchTests: XCTestCase {

    // MARK: The gap

    /// THE REPRO. The server holds an `accepted` ride on this owner's car; the
    /// rider list is empty (a different rider booked it) and the incoming feed is
    /// empty (it is `requested`-only). A cold launch must still put the card up.
    func testColdLaunchAdoptsAnOpenAcceptedRideIntoTheOwnerDispatch() async {
        let api = StubOwnerRideAPI(detail: Self.wire(id: "srv-live", status: .accepted))
        let service = Self.service(api: api, pointing: "srv-live")

        await service.refreshOwnerDispatch()

        XCTAssertEqual(service.ownerDispatch?.id, "srv-live", "the card is back after a relaunch")
        XCTAssertEqual(service.ownerDispatch?.status, .accepted)
        XCTAssertNil(service.incomingRequest, "an accepted ride is a dispatch, never an incoming card")
    }

    /// …and `start()` — the cold-launch sequence itself — is what runs it. A pure
    /// test of the adoption proves the RULE; only the real entry point proves the
    /// rule is on the path a launch takes (`OwnerColdReadFailureUITests`' lesson,
    /// one layer down).
    func testTheColdLaunchSEQUENCEPerformsTheAdoption() async {
        let api = StubOwnerRideAPI(detail: Self.wire(id: "srv-live", status: .enroute))
        let service = Self.service(api: api, pointing: "srv-live")

        service.start()

        await eventually { service.ownerDispatch?.id == "srv-live" }
    }

    /// Every LIVE phase, not just the first: the owner may force-quit at any point
    /// in the handshake, and the phases carry different controls ("Dropped off" is
    /// reachable only from `enroute`).
    func testColdLaunchAdoptsEveryLivePhase() async {
        for status in [MyRobotaxiContracts.RideRequestStatus.accepted, .arrived, .enroute] {
            let id = "srv-\(status.rawValue)"
            let api = StubOwnerRideAPI(detail: Self.wire(id: id, status: status))
            let service = Self.service(api: api, pointing: id)

            await service.refreshOwnerDispatch()

            XCTAssertEqual(
                service.ownerDispatch?.status,
                RideRequestContractMapping.status(status),
                "the owner relaunched mid-\(status.rawValue) and the card must hold that phase")
        }
    }

    /// The adopted record is the one a WS frame would have produced, because it is
    /// built by the same `RideRequestContractMapping.record(from:)` fold — so the
    /// rider name, the pickup/drop-off labels and the leg-1 pickup the owner map
    /// draws to are all there, not a shell with an id in it.
    func testTheAdoptedRecordCarriesWhatTheCardRenders() async {
        let api = StubOwnerRideAPI(detail: Self.wire(id: "srv-full", status: .enroute))
        let service = Self.service(api: api, pointing: "srv-full")

        await service.refreshOwnerDispatch()

        let dispatch = service.ownerDispatch
        XCTAssertEqual(dispatch?.input.requesterName, "Mira")
        XCTAssertEqual(dispatch?.input.pickup.label, "Home")
        XCTAssertEqual(dispatch?.input.destination.label, "SFO \u{00B7} Terminal 2")
        XCTAssertEqual(dispatch?.input.pickup.coordinate.latitude ?? 0, 37.7749, accuracy: 0.0001)
        XCTAssertNotNil(dispatch?.acceptedAt, "the accept instant travels with the record")
        XCTAssertEqual(service.incomingServerRideID, "srv-full", "owner mutations target the server id")
    }

    // MARK: What must NOT be adopted

    /// MYR-376's whole model, on the new path. A reservation the owner accepted for
    /// TOMORROW is `accepted` today, and adopting it as a live dispatch would put
    /// "En route to pickup" and a live "Picked up" button over a parked car — the
    /// exact defect MYR-376 closed, re-opened through a new door. The gate is the
    /// SHARED `RideReservation.isAdoptableLiveRide`, not a second copy of the rule.
    func testADormantReservationIsNotAdoptedAsALiveDispatch() async {
        let tomorrow = Date().addingTimeInterval(24 * 60 * 60)
        let api = StubOwnerRideAPI(detail: Self.wire(
            id: "srv-dormant", status: .accepted, scheduledFor: tomorrow))
        let service = Self.service(api: api, pointing: "srv-dormant")

        await service.refreshOwnerDispatch()

        XCTAssertNil(service.ownerDispatch, "no card, no 'En route to pickup', no 'Picked up'")
        XCTAssertNil(service.ownerRequest, "and it does not take the owner's slot either")
    }

    /// …and the pointer SURVIVES that, because dormancy is TIME-BOUNDED (MYR-376):
    /// the same reservation is a live ride once its moment arrives, and the next
    /// foreground is what has to notice. Clearing here would make the ride
    /// unreachable for the rest of its life.
    func testADormantReservationKeepsThePointerForItsOwnDueMoment() async {
        let pointer = InMemoryOwnerDispatchPointer(rideID: "srv-dormant")
        let api = StubOwnerRideAPI(detail: Self.wire(
            id: "srv-dormant", status: .accepted, scheduledFor: Date().addingTimeInterval(60)))
        let service = LiveRideRequestService(
            api: api, socket: StubOwnerRideSocket(), autoStart: false, dispatchPointer: pointer)

        await service.refreshOwnerDispatch()
        XCTAssertNil(service.ownerDispatch)
        XCTAssertEqual(pointer.read(), "srv-dormant", "still the ride this owner is on the hook for")

        // The moment passes and the SAME reservation is now a live ride.
        await api.setDetail(Self.wire(
            id: "srv-dormant", status: .accepted, scheduledFor: Date().addingTimeInterval(-60)))
        await service.refreshOwnerDispatch()

        XCTAssertEqual(service.ownerDispatch?.id, "srv-dormant", "past due, it is the ride in progress")
    }

    /// …and the WAITING is restored too, not just the pointer. A reservation the
    /// owner accepted before the force-quit is in no pipeline after it, so MYR-376's
    /// one due-timer had nothing to arm from and the card would have appeared only
    /// if the owner happened to foreground the app after the moment passed. The
    /// dormant read now feeds the SAME timer the rider's dormant reservation does,
    /// and the wake goes through this adoption rather than through `applyRemote` —
    /// `integrateOwner` has no arm for a ride the pipeline does not hold.
    ///
    /// Real time, deliberately: the due instant is 2s out and the service pays its
    /// own `dueRefetchGrace` (5s) on top, so what this measures is the shipping
    /// schedule rather than an injected one. Two seconds and not less because the
    /// wire's RFC 3339 stamp carries no fractional part — a sub-second lead
    /// truncates into the past and the ride is past due before the first read.
    func testAColdLaunchedDormantReservationWakesItselfAtItsDueMoment() async {
        let due = Date().addingTimeInterval(2)
        let api = StubOwnerRideAPI(detail: Self.wire(
            id: "srv-soon", status: .accepted, scheduledFor: due))
        let service = Self.service(api: api, pointing: "srv-soon")

        await service.refreshOwnerDispatch()
        XCTAssertNil(service.ownerDispatch, "still dormant at the moment of the read")

        await eventually(timeout: 25) { service.ownerDispatch?.id == "srv-soon" }
    }

    /// A ride that is OVER is not a dispatch — and must not resurrect the MYR-292
    /// "Dropped off ✓" banner on every launch for the rest of the install's life.
    /// That acknowledgement is session state by design (`OwnerHomeState`), so a
    /// re-adopted `completed` ride would raise the banner again, and again.
    func testATerminalRideIsNeitherAdoptedNorRemembered() async {
        for status in [MyRobotaxiContracts.RideRequestStatus.completed, .declined, .cancelled] {
            let pointer = InMemoryOwnerDispatchPointer(rideID: "srv-done")
            let api = StubOwnerRideAPI(detail: Self.wire(id: "srv-done", status: status))
            let service = LiveRideRequestService(
                api: api, socket: StubOwnerRideSocket(), autoStart: false, dispatchPointer: pointer)

            await service.refreshOwnerDispatch()

            XCTAssertNil(service.ownerDispatch, "\(status.rawValue) is not a ride in progress")
            XCTAssertNil(service.ownerRequest, "\(status.rawValue) never reaches the slot")
            XCTAssertNil(pointer.read(), "and the pointer is spent (\(status.rawValue))")
        }
    }

    /// A ride still awaiting the owner's decision belongs to the INCOMING feed,
    /// which fetches it authoritatively on the very next line of `start()`.
    /// Adopting it here would put a `pending` record in the slot from a second
    /// source and race `adoptNextIncoming` for it.
    func testAPendingRideIsLeftToTheIncomingFeed() async {
        let api = StubOwnerRideAPI(detail: Self.wire(id: "srv-pending", status: .requested))
        let service = Self.service(api: api, pointing: "srv-pending")

        await service.refreshOwnerDispatch()

        XCTAssertNil(service.ownerRequest, "the feed's job, not this one's")
    }

    /// A read that does not answer changes NOTHING — no adoption, and no
    /// forgetting either. A network failure is not evidence that a ride ended
    /// (MYR-326's "loading ≠ unavailable", pointed at a pointer).
    func testAFailedReadNeitherAdoptsNorForgets() async {
        let pointer = InMemoryOwnerDispatchPointer(rideID: "srv-live")
        let api = StubOwnerRideAPI(detail: Self.wire(id: "srv-live", status: .accepted))
        await api.setUnreachable(true)
        let service = LiveRideRequestService(
            api: api, socket: StubOwnerRideSocket(), autoStart: false, dispatchPointer: pointer)

        await service.refreshOwnerDispatch()
        XCTAssertNil(service.ownerDispatch)
        XCTAssertEqual(pointer.read(), "srv-live", "the ride is still out there")

        // The next foreground finds the network back.
        await api.setUnreachable(false)
        await service.refreshOwnerDispatch()
        XCTAssertEqual(service.ownerDispatch?.id, "srv-live")
    }

    // MARK: Non-destructive

    /// A redundant adopt — the foreground one, arriving over a pipeline that
    /// already holds this very ride — must not flash, reset or re-fold the
    /// surface. It makes NO request at all: holding the ride is the answer.
    func testARedundantAdoptDoesNotDisturbAPopulatedPipelineOrAskTheServer() async {
        let api = StubOwnerRideAPI(detail: Self.wire(id: "srv-live", status: .arrived))
        let service = Self.service(api: api, pointing: "srv-live")
        await service.refreshOwnerDispatch()
        let adopted = service.ownerDispatch
        let readsAfterAdoption = await api.detailCount

        await service.refreshOwnerDispatch()

        XCTAssertEqual(service.ownerDispatch, adopted, "the same record, unmoved")
        let readsAfterRedundantAdopt = await api.detailCount
        XCTAssertEqual(readsAfterRedundantAdopt, readsAfterAdoption, "and no second read")
    }

    /// A LIVE DISPATCH IS NEVER DISPLACED — the same rule `adoptNextIncoming`
    /// obeys, through the same `canAdoptIncoming` guard, so this cannot become a
    /// back door around the owner pipeline's own invariant. A stale pointer must
    /// not take the slot out from under the ride the owner is driving.
    func testAnAdoptNeverDisplacesARideAlreadyOnTheCard() async {
        let api = StubOwnerRideAPI(detail: Self.wire(id: "srv-stale", status: .enroute))
        await api.setIncoming([Self.wire(id: "srv-current", status: .requested)])
        let service = Self.service(api: api, pointing: "srv-stale")
        await service.refreshIncoming()
        service.accept()
        XCTAssertEqual(service.ownerDispatch?.id, "srv-current")

        await service.refreshOwnerDispatch()

        XCTAssertEqual(service.ownerDispatch?.id, "srv-current", "the ride being driven keeps the card")
    }

    /// The cold-launch ORDER is load-bearing: the dispatch is adopted BEFORE the
    /// incoming feed is read, so a live ride owns the slot and the pending
    /// requests queue behind it — exactly what happens when they arrive live.
    func testAColdLaunchWithBothPutsTheLiveDispatchOnTheCardAndQueuesTheRest() async {
        let api = StubOwnerRideAPI(detail: Self.wire(id: "srv-live", status: .accepted))
        await api.setIncoming([Self.wire(id: "srv-waiting", status: .requested)])
        let service = Self.service(api: api, pointing: "srv-live")

        service.start()

        await eventually { service.ownerDispatch?.id == "srv-live" }
        await eventually { service.waitingIncomingCount == 1 }
        XCTAssertNil(service.incomingRequest, "a live dispatch is never displaced by the feed")
    }

    // MARK: The pointer

    /// The pointer is written by the OWNER pipeline itself, at every point the
    /// owner is on the hook for a ride, and cleared the moment they are not. This
    /// sweeps the whole handshake rather than trusting a call-site list — an exit
    /// nobody remembered is exactly how MYR-389 shipped.
    func testThePointerFollowsTheOwnerPipelineThroughTheWholeHandshake() async {
        let pointer = InMemoryOwnerDispatchPointer()
        let api = StubOwnerRideAPI(detail: Self.wire(id: "srv-1", status: .requested))
        await api.setIncoming([Self.wire(id: "srv-1", status: .requested)])
        let socket = StubOwnerRideSocket()
        let service = LiveRideRequestService(
            api: api, socket: socket, autoStart: false, dispatchPointer: pointer)
        service.start()
        await eventually { service.incomingRequest?.id == "srv-1" }
        XCTAssertNil(pointer.read(), "a pending card is the feed's to restore")

        await api.setDetail(Self.wire(id: "srv-1", status: .accepted))
        service.accept()
        XCTAssertEqual(pointer.read(), "srv-1", "the accept is what puts the owner on the hook")

        await api.setDetail(Self.wire(id: "srv-1", status: .arrived))
        service.pickedUp()
        await eventually { service.ownerDispatch?.status == .arrived }
        XCTAssertEqual(pointer.read(), "srv-1")

        // `arrived → enroute` is the RIDER's transition, and reaches this device
        // as a `ride_status_changed` frame.
        await api.setDetail(Self.wire(id: "srv-1", status: .enroute))
        await eventually { await socket.isListening }
        await socket.push(.statusChanged(RideStatusChangedPayload(
            rideRequestId: "srv-1", vehicleId: "veh-live", status: .enroute, timestamp: Self.isoNow())))
        await eventually { service.ownerDispatch?.status == .enroute }
        XCTAssertEqual(pointer.read(), "srv-1")

        await api.setDetail(Self.wire(id: "srv-1", status: .completed))
        service.droppedOff()
        await eventually { pointer.read() == nil }
    }

    /// A ride that ENDED anywhere but on this device still clears the pointer: the
    /// authoritative record arrives on a frame, the fold sees a terminal status,
    /// and there is nothing left to restore. (A `cancelled` frame is the sharpest
    /// version — MYR-325 retires it from the owner pipeline outright.)
    func testARideThatEndsRemotelyIsForgotten() async {
        let pointer = InMemoryOwnerDispatchPointer()
        let api = StubOwnerRideAPI(detail: Self.wire(id: "srv-2", status: .requested))
        await api.setIncoming([Self.wire(id: "srv-2", status: .requested)])
        let socket = StubOwnerRideSocket()
        let service = LiveRideRequestService(
            api: api, socket: socket, autoStart: false, dispatchPointer: pointer)
        service.start()
        await eventually { service.incomingRequest?.id == "srv-2" }
        await api.setDetail(Self.wire(id: "srv-2", status: .accepted))
        service.accept()
        XCTAssertEqual(pointer.read(), "srv-2")

        await api.setDetail(Self.wire(id: "srv-2", status: .cancelled))
        await eventually { await socket.isListening }
        await socket.push(.statusChanged(RideStatusChangedPayload(
            rideRequestId: "srv-2", vehicleId: "veh-live", status: .cancelled, timestamp: Self.isoNow())))

        await eventually { service.ownerRequest == nil }
        XCTAssertNil(pointer.read())
    }

    /// SIGN-OUT forgets it. The pointer is a SINGLE record for a device that holds
    /// exactly one session (`UserDefaultsProfileStore`'s own reasoning), so the
    /// next account must never inherit the previous one's ride.
    func testSignOutForgetsThePointer() async {
        let pointer = InMemoryOwnerDispatchPointer(rideID: "srv-live")
        let api = StubOwnerRideAPI(detail: Self.wire(id: "srv-live", status: .accepted))
        let service = LiveRideRequestService(
            api: api, socket: StubOwnerRideSocket(), autoStart: false, dispatchPointer: pointer)

        service.forgetOwnerDispatch()

        XCTAssertNil(pointer.read())
        await service.refreshOwnerDispatch()
        XCTAssertNil(service.ownerDispatch, "nothing points at it any more")
        let reads = await api.detailCount
        XCTAssertEqual(reads, 0, "and nothing is asked of the server")
    }

    // MARK: Self-rides (MYR-325)

    /// The client's own workflow: one account, both roles. A ride he booked as a
    /// rider and answered as an owner must come back on BOTH pipelines after a
    /// force-quit — the rider's through MYR-230's list adoption, the owner's
    /// through this one — and they legitimately hold the same id (MYR-325's
    /// same-account duality).
    func testASelfRideIsRestoredOnBothPipelines() async {
        let ride = Self.wire(id: "srv-self", status: .arrived)
        let api = StubOwnerRideAPI(detail: ride)
        await api.setRideList([ride]) // the rider's own §7.8 list carries it too
        let service = Self.service(api: api, pointing: "srv-self")

        service.start()

        await eventually { service.activeRequest?.id == "srv-self" }   // the rider half tracks
        await eventually { service.ownerDispatch?.id == "srv-self" }   // the owner half has the card
    }

    // MARK: Storage

    /// The persisted store round-trips and EXPIRES. Nothing in this app holds a
    /// ride open for a month; a pointer that old is a fossil, and re-asking the
    /// server about it on every launch forever is the cost of not saying so.
    func testTheUserDefaultsPointerRoundTripsAndExpires() {
        let suite = "myr396.pointer.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsOwnerDispatchPointer(defaults: defaults)
        XCTAssertNil(store.read())

        let now = Date()
        store.write(rideID: "srv-live", now: now)
        XCTAssertEqual(store.read(now: now), "srv-live")
        XCTAssertEqual(
            store.read(now: now.addingTimeInterval(UserDefaultsOwnerDispatchPointer.maxAge - 60)),
            "srv-live")
        XCTAssertNil(
            store.read(now: now.addingTimeInterval(UserDefaultsOwnerDispatchPointer.maxAge + 60)),
            "an expired pointer is not a ride")

        store.clear()
        XCTAssertNil(store.read(now: now))
    }

    /// The SIMULATED service is untouched by all of this: it has no server to read
    /// and no second party, so both new seam methods are no-ops and every DEBUG
    /// capture is byte-identical.
    func testTheSimulatedServiceIsInert() async {
        let service = SimulatedRideRequestService()
        await service.refreshOwnerDispatch()
        service.forgetOwnerDispatch()
        XCTAssertNil(service.ownerDispatch)
    }

    // MARK: Fixtures

    private static func service(api: StubOwnerRideAPI, pointing rideID: String) -> LiveRideRequestService {
        LiveRideRequestService(
            api: api,
            socket: StubOwnerRideSocket(),
            autoStart: false,
            dispatchPointer: InMemoryOwnerDispatchPointer(rideID: rideID)
        )
    }

    private static func isoNow() -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.string(from: Date())
    }

    private static func wire(
        id: String,
        status: MyRobotaxiContracts.RideRequestStatus,
        scheduledFor: Date? = nil
    ) -> MyRobotaxiContracts.RideRequest {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = TimeZone(secondsFromGMT: 0)
        let stamp = iso.string(from: Date())
        return MyRobotaxiContracts.RideRequest(
            id: id,
            riderId: "cluser0000000000rider0",
            ownerId: "cluser0000000000owner0",
            vehicleId: "veh-live",
            pickup: MyRobotaxiContracts.RidePlace(lat: 37.7749, lng: -122.4194, label: "Home"),
            dropoff: MyRobotaxiContracts.RidePlace(
                lat: 37.6156, lng: -122.3900,
                label: "SFO \u{00B7} Terminal 2", address: "San Francisco International"),
            status: status,
            scheduledFor: scheduledFor.map { iso.string(from: $0) },
            createdAt: stamp,
            updatedAt: stamp,
            acceptedAt: status == .requested ? nil : stamp,
            requesterName: "Mira"
        )
    }

    private func eventually(
        timeout: TimeInterval = 2,
        _ condition: @escaping () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("condition never became true", file: file, line: line)
    }
}

// MARK: - Stubs

/// The §7.8 surface this issue reads, with both endpoints' REAL semantics:
/// `rideRequests` is the RIDER's own list, and `incomingRideRequests` carries
/// `requested` rows only. That pair's blind spot is the whole defect, so a stub
/// that served an accepted ride from either of them would test a server that does
/// not exist (MYR-362's lesson about fixtures agreeing with a fiction).
private actor StubOwnerRideAPI: RideRequestAPI {
    private var detail: MyRobotaxiContracts.RideRequest
    private var rideList: [MyRobotaxiContracts.RideRequest] = []
    private var incoming: [MyRobotaxiContracts.RideRequest] = []
    private var unreachable = false
    private(set) var detailCount = 0

    init(detail: MyRobotaxiContracts.RideRequest) { self.detail = detail }

    func setDetail(_ ride: MyRobotaxiContracts.RideRequest) { detail = ride }
    func setRideList(_ rides: [MyRobotaxiContracts.RideRequest]) { rideList = rides }
    func setIncoming(_ rides: [MyRobotaxiContracts.RideRequest]) { incoming = rides }
    func setUnreachable(_ value: Bool) { unreachable = value }

    func rideRequest(id: String) async throws -> MyRobotaxiContracts.RideRequest {
        detailCount += 1
        if unreachable { throw RestError.http(status: 503, code: nil, message: nil, subCode: nil) }
        guard detail.id == id else { throw RestError.http(status: 404, code: nil, message: nil, subCode: nil) }
        return detail
    }

    func rideRequests(cursor: String?, limit: Int) async throws -> RideRequestsListResponse {
        RideRequestsListResponse(items: rideList, hasMore: false)
    }

    func incomingRideRequests(cursor: String?, limit: Int) async throws -> RideRequestsListResponse {
        RideRequestsListResponse(items: incoming.filter { $0.status == .requested }, hasMore: false)
    }

    func acceptRideRequest(id: String) async throws -> MyRobotaxiContracts.RideRequest {
        try await rideRequest(id: id)
    }

    func vehicles() async throws -> [VehicleSummary] { [] }
    func createRideRequest(_ body: RideRequestCreateRequest) async throws -> MyRobotaxiContracts.RideRequest {
        throw RestError.http(status: 501, code: nil, message: nil, subCode: nil)
    }
    func cancelRideRequest(id: String) async throws -> MyRobotaxiContracts.RideRequest { try await rideRequest(id: id) }
    func declineRideRequest(id: String) async throws -> MyRobotaxiContracts.RideRequest { try await rideRequest(id: id) }
    func pickedUp(rideID: String) async throws -> MyRobotaxiContracts.RideRequest { try await rideRequest(id: rideID) }
    func start(rideID: String) async throws -> MyRobotaxiContracts.RideRequest { try await rideRequest(id: rideID) }
    func droppedOff(rideID: String) async throws -> MyRobotaxiContracts.RideRequest { try await rideRequest(id: rideID) }
    func upcomingReservations(vehicleID: String, cursor: String?, limit: Int) async throws -> RideRequestsListResponse {
        RideRequestsListResponse(items: [], hasMore: false)
    }
}

/// A controllable ride-event source — the same shape `LiveRideRequestServiceTests`
/// uses, so a frame here travels the production `applyRemote` → `integrate` path.
private actor StubOwnerRideSocket: RideEventStreaming {
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
