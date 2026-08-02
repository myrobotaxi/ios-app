import CoreLocation
@testable import MyRoboTaxi
import MyRoboTaxiKit
import MyRobotaxiContracts
import UserNotifications
import XCTest

// MARK: - MYR-424 — an owner's decline must reach a FOREGROUNDED rider
//
// The r20 report, in one screenshot: the rider is foregrounded on the Live Map,
// the decline push banner "Lunar can't take this ride — Try booking another car"
// is ON SCREEN, and the pill beneath it still reads "Request sent · Waiting for
// Lunar · Galleria Dallas". The server's own record settles the question of who
// was wrong — `go_ride_requests` row `c81733c735e56bcf8d0220c5c329dd530`,
// `status = declined`, `updated_at = 2026-08-02 16:18:19.070Z`, `accepted_at`
// null, dropoff "Galleria Dallas". The decline happened, at the screenshot's own
// minute. The client simply never applied it.
//
// The pill is `activeRequest?.status == .pending` and nothing else
// (`SharedViewerScreen.idleSheet`), so "the pill is stuck" is exactly "the held
// record never left `.pending`". These tests pin the three roads by which it now
// must leave, in the order of how much they are trusted:
//
//  1. THE FRAME + ITS REFETCH — the primary channel, and the one that was already
//     correct. Pinned here anyway, because "declined is missing from the integrate
//     path" was the first hypothesis and a test is how it stops being re-asked.
//  2. THE FRAME ALONE — new. A frame that arrived and whose refetch failed used to
//     be discarded whole; a ride could therefore fail to END on a single bad GET.
//  3. THE PUSH — new, and the actual safety net. The banner in the screenshot is
//     proof the app was told; until now being told produced no state change at all.
//
// The three are deliberately independent: 1 needs a live socket AND a live REST
// read, 2 needs only the socket, 3 needs neither.
@MainActor
final class RiderDeclineConvergenceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // MYR-396's rule, for the same reason `LiveRideRequestServiceTests` states:
        // the real pointer is the RUNNER's defaults in a test host, so a ride left
        // behind here would cold-adopt into a neighbouring test.
        UserDefaultsOwnerDispatchPointer().clear()
        Self.clearBridge()
    }

    override func tearDown() {
        Self.clearBridge()
        super.tearDown()
    }

    // MARK: 1 — the declined status through the integrate path

    /// The mapping hypothesis, closed. `declined` is not the erasure case: it maps
    /// 1:1 to a real app status and therefore takes the ordinary
    /// `integrateRider` → `fold` route, which assigns `current.status`.
    ///
    /// The contrast with `cancelled` is the whole point of the assertion pair —
    /// `cancelled` is the status that returns `nil` and empties the slot, and
    /// confusing the two is how a decline could plausibly have gone missing.
    func testDeclinedMapsToARealStatusAndIsNotTheErasureCase() {
        XCTAssertEqual(
            RideRequestContractMapping.status(.declined), .declined,
            "a decline must survive the wire→app mapping as a status the surfaces can read"
        )
        XCTAssertNil(
            RideRequestContractMapping.status(.cancelled),
            "cancelled is the one status that erases the slot — declined must not join it"
        )
    }

    /// The end-to-end primary path, driven exactly as the foregrounded rider's
    /// session would be: a live socket, a live detail read, no app lifecycle event
    /// of any kind. The pill's own gate is asserted rather than paraphrased.
    func testADeclineFrameClearsThePendingPillWithNoForegroundEvent() async {
        let api = StubDeclineAPI(created: Self.wireRide(id: "srv-decline", status: .requested))
        let socket = StubDeclineSocket()
        let service = LiveRideRequestService(api: api, socket: socket, autoStart: true)

        service.submit(Self.sampleInput())
        service.confirmSend()
        await eventually { await api.createCount == 1 }
        await eventually { await socket.isListening }
        XCTAssertEqual(service.activeRequest?.status, .pending, "the pill is up")

        await api.setDetail(Self.wireRide(id: "srv-decline", status: .declined))
        await socket.push(.statusChanged(RideStatusChangedPayload(
            rideRequestId: "srv-decline", vehicleId: "veh-live",
            status: .declined, timestamp: "2026-08-02T16:18:19.070Z"
        )))

        await eventually { service.activeRequest?.status == .declined }
        XCTAssertNotEqual(
            service.activeRequest?.status, .pending,
            "the pill's ONLY gate is `status == .pending` — this is the stuck pill, cleared"
        )
        XCTAssertNotNil(
            service.activeRequest,
            "the record is KEPT: the DeclinedNotice is built from it (MYR-172's retention rule)"
        )
    }

    /// The record the fold leaves behind must be one the declined surface will
    /// actually raise — the pill clearing is only half of the acceptance criterion.
    func testTheFoldedDeclinedRecordRaisesTheDeclinedNotice() {
        XCTAssertTrue(
            RiderDeclinedNotice.shouldRaise(status: .declined, rideID: "srv-decline", acknowledgedID: nil),
            "a freshly declined ride raises the notice the client's screenshot never got"
        )
        XCTAssertFalse(
            RiderRouteLifetime.bearsRoute(status: .declined),
            "and its route stops being drawn"
        )
    }

    // MARK: 2 — the frame alone, when the refetch does not answer

    /// `RideFrameTerminalStatus` is asymmetric on purpose, so the matrix is the
    /// test. Only the two statuses that END a ride may be applied from a summary
    /// frame; everything else — including `cancelled`, whose application is an
    /// ERASURE — must wait for a record.
    func testOnlyEndingStatusesMayBeAppliedFromTheFrameAlone() {
        XCTAssertEqual(RideFrameTerminalStatus.applicable(wire: "declined"), .declined)
        XCTAssertEqual(RideFrameTerminalStatus.applicable(wire: "completed"), .completed)

        for wire in ["requested", "accepted", "arrived", "enroute"] {
            XCTAssertNil(
                RideFrameTerminalStatus.applicable(wire: wire),
                "\(wire) drives surfaces that need the refetched record to be honest"
            )
        }
        XCTAssertNil(
            RideFrameTerminalStatus.applicable(wire: "cancelled"),
            "erasing a rider's held ride on the strength of a FAILED read is the worse mistake"
        )
        XCTAssertNil(
            RideFrameTerminalStatus.applicable(wire: "something_newer"),
            "this build cannot know whether an unrecognized status ends anything"
        )
        XCTAssertNil(RideFrameTerminalStatus.applicable(wire: nil), "a frame with no status says nothing")
    }

    /// The hardening, end to end: the socket delivered the decline and the REST
    /// read behind it failed. Before MYR-424 the frame was dropped by
    /// `applyRemote`'s `try?` and the pill stayed up for the rest of the session,
    /// because the rider pipeline's only other re-read fires on a scenePhase
    /// `.active` EDGE that a foregrounded app never crosses.
    func testADeclineFrameEndsTheRideEvenWhenItsRefetchFails() async {
        let api = StubDeclineAPI(created: Self.wireRide(id: "srv-nogets", status: .requested))
        let socket = StubDeclineSocket()
        let service = LiveRideRequestService(api: api, socket: socket, autoStart: true)

        service.submit(Self.sampleInput())
        service.confirmSend()
        await eventually { await api.createCount == 1 }
        await eventually { await socket.isListening }
        XCTAssertEqual(service.activeRequest?.status, .pending)

        await api.setDetailError(URLError(.notConnectedToInternet))
        await socket.push(.statusChanged(RideStatusChangedPayload(
            rideRequestId: "srv-nogets", vehicleId: "veh-live",
            status: .declined, timestamp: "2026-08-02T16:18:19.070Z"
        )))

        await eventually { service.activeRequest?.status == .declined }
        XCTAssertEqual(
            service.activeRequest?.input.destination.label, Self.destinationLabel,
            "nothing but the status is written — the summary frame is no evidence about the places"
        )
    }

    /// The other half of the asymmetry, on the same rig: an INTERMEDIATE frame
    /// whose refetch fails must change nothing at all. Half an accepted ride —
    /// a status with no leg, no pickup and no dispatch latch behind it — is worse
    /// than a pending one, and the next frame carries it anyway.
    func testAnAcceptedFrameWhoseRefetchFailsLeavesTheRecordAlone() async {
        let api = StubDeclineAPI(created: Self.wireRide(id: "srv-inter", status: .requested))
        let socket = StubDeclineSocket()
        let service = LiveRideRequestService(api: api, socket: socket, autoStart: true)

        service.submit(Self.sampleInput())
        service.confirmSend()
        await eventually { await api.createCount == 1 }
        await eventually { await socket.isListening }

        await api.setDetailError(URLError(.notConnectedToInternet))
        await socket.push(.statusChanged(RideStatusChangedPayload(
            rideRequestId: "srv-inter", vehicleId: "veh-live",
            status: .accepted, timestamp: "2026-08-02T16:10:00.000Z"
        )))
        try? await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertEqual(service.activeRequest?.status, .pending, "an unconfirmed advance is not an advance")
    }

    /// And the erasure case, which is the one that could lose a rider's ride: a
    /// `cancelled` frame whose refetch fails must NOT empty the slot.
    func testACancelledFrameWhoseRefetchFailsDoesNotEraseTheSlot() async {
        let api = StubDeclineAPI(created: Self.wireRide(id: "srv-cxl", status: .requested))
        let socket = StubDeclineSocket()
        let service = LiveRideRequestService(api: api, socket: socket, autoStart: true)

        service.submit(Self.sampleInput())
        service.confirmSend()
        await eventually { await api.createCount == 1 }
        await eventually { await socket.isListening }

        await api.setDetailError(URLError(.notConnectedToInternet))
        await socket.push(.statusChanged(RideStatusChangedPayload(
            rideRequestId: "srv-cxl", vehicleId: "veh-live",
            status: .cancelled, timestamp: "2026-08-02T16:11:00.000Z"
        )))
        try? await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertEqual(service.activeRequest?.status, .pending, "a failed read is not evidence a ride ended")
    }

    // MARK: 3 — the push funnel (the safety net)

    /// A ride-lifecycle push RECEIVED in-app is a refresh trigger. Before MYR-424
    /// `willPresent` only ever decided whether to draw a banner, so the strongest
    /// out-of-band evidence the client had that the server's record had moved on
    /// produced no state change whatsoever.
    func testAPushNamingARideTriggersARefresh() {
        XCTAssertEqual(
            PushNotificationRouting.foregroundRefresh(
                notification: PushRideNotification(rideID: "srv-decline")),
            .refresh
        )
    }

    /// A notification the app has no ride opinion about must not fire a refetch —
    /// there is nothing to converge on, and the funnel resolves rides by id.
    func testAPushWithNoRideIDTriggersNoRefresh() {
        XCTAssertEqual(PushNotificationRouting.foregroundRefresh(notification: nil), .skip)
    }

    /// **The load-bearing independence.** The two foreground decisions are made
    /// from different inputs, so a SUPPRESSED banner still refreshes — and that is
    /// the case that needs it most, because the surface being suppressed in favour
    /// of is precisely the one that may be stale. A refresh rule that consulted
    /// `PushSurfaceContext` could regress this by accident; `foregroundRefresh`
    /// cannot even see it.
    func testASuppressedBannerStillRefreshes() {
        let notification = PushRideNotification(rideID: "srv-decline")
        let context = PushSurfaceContext(role: .shared, riderTrackingRideID: "srv-decline")

        XCTAssertEqual(
            PushNotificationRouting.foregroundPresentation(notification: notification, context: context),
            .suppress,
            "unchanged: the rider is already watching this ride"
        )
        XCTAssertEqual(
            PushNotificationRouting.foregroundRefresh(notification: notification),
            .refresh,
            "the surface it is suppressed in favour of is exactly the one that may be lying"
        )
    }

    /// The rider arm of the funnel is what a decline push pokes, so pin what it
    /// resolves to. `RootView.refreshForPushRoute` switches on this and the
    /// arrival door reuses the tap door's rule so there is one definition.
    func testARiderPushResolvesToTheRiderRefreshArm() {
        XCTAssertEqual(
            PushNotificationRouting.tapRoute(
                notification: PushRideNotification(rideID: "srv-decline"), role: .shared),
            .riderActiveFlow
        )
    }

    /// The funnel's far end, with **the socket dead**: no frame is ever pushed, and
    /// the decline reaches the rider purely through the re-read that
    /// `refreshForPushRoute(.riderActiveFlow)` performs. This is the acceptance
    /// criterion's second half — "with the WS dead" — at the service seam.
    func testTheRefreshFunnelAloneConvergesADeclinedRideWithNoFrameEverArriving() async {
        let api = StubDeclineAPI(created: Self.wireRide(id: "srv-push", status: .requested))
        let socket = StubDeclineSocket()
        let service = LiveRideRequestService(api: api, socket: socket, autoStart: true)

        service.submit(Self.sampleInput())
        service.confirmSend()
        await eventually { await api.createCount == 1 }
        XCTAssertEqual(service.activeRequest?.status, .pending)

        // The owner declines. The socket never says a word about it.
        await api.setDetail(Self.wireRide(id: "srv-push", status: .declined))
        await service.refreshActiveRide()

        XCTAssertEqual(
            service.activeRequest?.status, .declined,
            "MYR-402's re-read carries the decline on its own — no frame, no foreground"
        )
    }

    // MARK: 3b — the DELEGATE actually consults the rule

    /// The client's own frame, driven through the real seam: the decline push's
    /// `userInfo` goes into the delegate's decision, and the ride-refresh funnel
    /// must be poked with that ride's id — while the banner still presents,
    /// because that banner is what the screenshot shows.
    ///
    /// This is the test that would have failed on the shipped build. The pure
    /// rules above would all have passed on it.
    func testTheDeclinePushDrivesTheRefreshFunnelThroughTheDelegate() {
        var refreshed: [String] = []
        PushDelegateBridge.shared.applyRideRefresh = { refreshed.append($0.rideID) }
        PushDelegateBridge.shared.surfaceContext = { PushSurfaceContext(role: .shared) }
        defer { Self.clearBridge() }

        let options = PushAppDelegate.handleForegroundNotification(userInfo: [
            "rideId": "c81733c735e56bcf8d0220c5c329dd530",
            "aps": ["alert": ["title": "Lunar can't take this ride",
                              "body": "Try booking another car"]]
        ])

        XCTAssertEqual(
            refreshed, ["c81733c735e56bcf8d0220c5c329dd530"],
            "the push that proved the server knew must be what makes the client ask"
        )
        XCTAssertEqual(options, [.banner, .sound], "and the banner is unchanged")
    }

    /// The independence, driven through the delegate rather than argued about:
    /// the rider IS on this ride's tracking sheet, so the banner is suppressed —
    /// and the refresh still fires.
    func testASuppressedBannerStillDrivesTheFunnelThroughTheDelegate() {
        var refreshed: [String] = []
        PushDelegateBridge.shared.applyRideRefresh = { refreshed.append($0.rideID) }
        PushDelegateBridge.shared.surfaceContext = {
            PushSurfaceContext(role: .shared, riderTrackingRideID: "srv-tracked")
        }
        defer { Self.clearBridge() }

        let options = PushAppDelegate.handleForegroundNotification(
            userInfo: ["rideId": "srv-tracked"])

        XCTAssertEqual(options, [], "unchanged: no banner over the ride's own sheet")
        XCTAssertEqual(refreshed, ["srv-tracked"], "the silent surface is the one that must converge")
    }

    /// The bridge is filled by `RootView.onAppear`, so a push landing in the
    /// window before that must not trap — and must still present.
    func testAPushArrivingBeforeTheBridgeIsInstalledStillPresents() {
        Self.clearBridge()

        let options = PushAppDelegate.handleForegroundNotification(userInfo: ["rideId": "srv-early"])

        XCTAssertEqual(options, [.banner, .sound], "no app state yet — present rather than swallow")
    }

    /// A notification with no ride id must not poke the funnel.
    func testANotificationWithNoRideIDDrivesNoRefresh() {
        var refreshCount = 0
        PushDelegateBridge.shared.applyRideRefresh = { _ in refreshCount += 1 }
        PushDelegateBridge.shared.surfaceContext = { PushSurfaceContext(role: .shared) }
        defer { Self.clearBridge() }

        _ = PushAppDelegate.handleForegroundNotification(userInfo: ["aps": ["alert": "hello"]])

        XCTAssertEqual(refreshCount, 0)
    }

    // MARK: Leg 1 — the channel itself

    /// The ride socket was the one socket in the app with no scene-phase wire, so a
    /// supervisor that settled terminally (`auth_failed`) stayed settled for the
    /// whole process and the rider went deaf to every ride frame. The refetches
    /// beside this call recover the DATA once; this recovers the CHANNEL.
    func testForegroundNudgesTheRideSocket() async {
        let api = StubDeclineAPI(created: Self.wireRide(id: "srv-fg", status: .requested))
        let socket = StubDeclineSocket()
        let service = LiveRideRequestService(api: api, socket: socket, autoStart: false)

        var nudges = await socket.foregroundCount
        XCTAssertEqual(nudges, 0)

        await service.handleForeground()

        nudges = await socket.foregroundCount
        XCTAssertEqual(nudges, 1, "the ride socket now gets what every other socket already had")
    }

    // MARK: - Fixtures

    /// `PushDelegateBridge` is a process-wide singleton, so a closure left behind
    /// would be filled by one test and fired by the next — the same leak
    /// `UserDefaultsOwnerDispatchPointer().clear()` guards against above.
    private static func clearBridge() {
        PushDelegateBridge.shared.applyRideRefresh = nil
        PushDelegateBridge.shared.surfaceContext = nil
        PushDelegateBridge.shared.applyTapRoute = nil
    }

    private static let destinationLabel = "Galleria Dallas"

    /// The client's own itinerary from the r20 report, so the record under test is
    /// shaped like the one in the screenshot.
    private static func sampleInput() -> RideRequestInput {
        RideRequestInput(
            pickup: RidePlace(id: "pin", label: "Bell Southstone Yards", subtitle: nil, miles: 0, minutes: 0, icon: "mappin",
                              coordinate: CLLocationCoordinate2D(latitude: 32.7767, longitude: -96.7970)),
            destination: RidePlace(id: "live|galleria", label: destinationLabel, subtitle: nil, miles: 12.4, minutes: 21, icon: "mappin",
                                   coordinate: CLLocationCoordinate2D(latitude: 32.9299, longitude: -96.8197)),
            fleetMemberID: RideRequestFixtures.fleet[0].id
        )
    }

    private static func wireRide(id: String, status: MyRobotaxiContracts.RideRequestStatus) -> RideRequest {
        RideRequest(
            id: id,
            riderId: "u-rider",
            ownerId: "u-rider",
            vehicleId: "veh-live",
            pickup: MyRobotaxiContracts.RidePlace(lat: 32.7767, lng: -96.7970, label: "Bell Southstone Yards"),
            dropoff: MyRobotaxiContracts.RidePlace(lat: 32.9299, lng: -96.8197, label: destinationLabel),
            status: status,
            scheduledFor: nil,
            createdAt: Self.isoNow(),
            updatedAt: Self.isoNow(),
            acceptedAt: nil,
            completedAt: nil,
            requesterName: nil
        )
    }

    private static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    private func eventually(timeout: TimeInterval = 2, _ condition: @escaping () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("condition never became true")
    }
}

// MARK: - Test doubles

/// In-memory `RideRequestAPI`. Narrower than `LiveRideRequestServiceTests`'s own
/// stub — this file only ever drives the RIDER pipeline — but the same shape, and
/// the detail read is scriptable to FAIL, which is what leg 2 turns on.
private actor StubDeclineAPI: RideRequestAPI {
    private let createReturn: RideRequest
    private var detailReturn: RideRequest?
    private var detailError: Error?
    private var rideList: [RideRequest] = []

    private(set) var createCount = 0
    private(set) var detailCount = 0

    init(created: RideRequest) { self.createReturn = created }

    func setDetail(_ ride: RideRequest) { detailReturn = ride; detailError = nil }
    func setDetailError(_ error: Error?) { detailError = error }
    func setRideList(_ rides: [RideRequest]) { rideList = rides }

    func vehicles() async throws -> [VehicleSummary] {
        [VehicleSummary(vehicleId: "veh-live", name: "Lunar", model: "Model Y", year: 2025, color: "Quicksilver",
                        vinLast4: "2046", status: .parked, chargeLevel: 68, estimatedRange: 210,
                        lastUpdated: "2026-08-02T16:00:00Z", role: .owner)]
    }

    func createRideRequest(_ body: RideRequestCreateRequest) async throws -> RideRequest {
        createCount += 1
        return createReturn
    }

    func rideRequests(cursor: String?, limit: Int) async throws -> RideRequestsListResponse {
        RideRequestsListResponse(items: rideList, hasMore: false)
    }

    func rideRequest(id: String) async throws -> RideRequest {
        detailCount += 1
        if let detailError { throw detailError }
        return detailReturn ?? createReturn
    }

    func cancelRideRequest(id: String) async throws -> RideRequest { createReturn }
    func acceptRideRequest(id: String) async throws -> RideRequest { detailReturn ?? createReturn }
    func declineRideRequest(id: String) async throws -> RideRequest { detailReturn ?? createReturn }
    func pickedUp(rideID: String) async throws -> RideRequest { detailReturn ?? createReturn }
    func start(rideID: String) async throws -> RideRequest { detailReturn ?? createReturn }
    func droppedOff(rideID: String) async throws -> RideRequest { detailReturn ?? createReturn }
    func incomingRideRequests(cursor: String?, limit: Int) async throws -> RideRequestsListResponse {
        RideRequestsListResponse(items: [], hasMore: false)
    }
    func upcomingReservations(vehicleID: String, cursor: String?, limit: Int) async throws -> RideRequestsListResponse {
        RideRequestsListResponse(items: [], hasMore: false)
    }
}

/// In-memory `RideEventStreaming` that also COUNTS foreground nudges — the wire
/// MYR-424 added, and the only way to observe it without a real socket.
private actor StubDeclineSocket: RideEventStreaming {
    private var continuation: AsyncStream<RideRequestEvent>.Continuation?
    private(set) var foregroundCount = 0

    var isListening: Bool { continuation != nil }

    func rideEvents() async -> AsyncStream<RideRequestEvent> {
        let (stream, continuation) = AsyncStream<RideRequestEvent>.makeStream()
        self.continuation = continuation
        return stream
    }

    func connect() async {}
    func disconnect() async {}
    func handleForeground() async { foregroundCount += 1 }
    func push(_ event: RideRequestEvent) { continuation?.yield(event) }
}
