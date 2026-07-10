import CoreLocation
@testable import MyRoboTaxi
import MyRoboTaxiKit
import MyRobotaxiContracts
import XCTest

// MARK: - MYR-209 — LiveRideRequestService against a stubbed Kit layer (no network)
//
// Drives the live ride-request service through the `RideRequestAPI` +
// `RideEventStreaming` seams with in-memory stubs. Verifies the seam the rider's
// SharedViewerScreen + the owner's IncomingRequestSheet consume:
//  • submit → optimistic pending + POST create (targets the resolved vehicle),
//  • pending → accepted / declined via the owner methods + the matching POST,
//  • cancel → clears the request + POST cancel on the server id,
//  • a `ride_status_changed` WS frame refetches the detail and reconciles state.
@MainActor
final class LiveRideRequestServiceTests: XCTestCase {

    // MARK: pending → accepted

    func testSubmitThenAcceptTransitionsPendingToAcceptedAndPosts() async {
        let api = StubRideAPI(created: Self.wireRide(id: "srv-1", status: .requested))
        let socket = StubRideSocket()
        let service = LiveRideRequestService(api: api, socket: socket, autoStart: false)

        service.submit(Self.sampleInput())
        XCTAssertEqual(service.activeRequest?.status, .pending, "optimistic pending is visible synchronously")
        await eventually { await api.createCount == 1 }
        await eventually { await api.lastCreateVehicleID == "veh-live" } // resolved from vehicles()

        service.accept()
        XCTAssertEqual(service.activeRequest?.status, .accepted)
        XCTAssertNotNil(service.activeRequest?.trackProgress, "an accepted now-ride seeds the static tracking progress")
        await eventually { await api.acceptCount == 1 }
        let acceptID = await api.lastAcceptID
        XCTAssertEqual(acceptID, "srv-1", "accept targets the server-assigned id, not the local UUID")
    }

    // MARK: pending → declined

    func testSubmitThenDeclineTransitionsPendingToDeclinedAndPosts() async {
        let api = StubRideAPI(created: Self.wireRide(id: "srv-2", status: .requested))
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false)

        service.submit(Self.sampleInput())
        await eventually { await api.createCount == 1 }

        service.decline()
        XCTAssertEqual(service.activeRequest?.status, .declined)
        await eventually { await api.declineCount == 1 }
        let declineID = await api.lastDeclineID
        XCTAssertEqual(declineID, "srv-2")
    }

    // MARK: cancel

    func testCancelClearsActiveRequestAndPostsCancelOnServerID() async {
        let api = StubRideAPI(created: Self.wireRide(id: "srv-3", status: .requested))
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false)

        service.submit(Self.sampleInput())
        await eventually { await api.createCount == 1 } // serverRideID now set

        service.cancel()
        XCTAssertNil(service.activeRequest, "cancel drops the active request")
        await eventually { await api.cancelCount == 1 }
        let cancelID = await api.lastCancelID
        XCTAssertEqual(cancelID, "srv-3")
    }

    // MARK: MYR-212 defect 3 (round 2) — classify create failures

    /// DEFINITIVE (typed HTTP 4xx): the server refused the create, so no ride
    /// exists — the optimistic pending must NOT linger as a stuck "Waiting…"
    /// card. It transitions to `.declined`, which is exactly what drives the
    /// SharedViewerScreen's existing declined affordance (owner-decline reuse).
    func testDefinitiveCreateFailureDropsOptimisticPendingIntoDeclined() async {
        let api = StubRideAPI(
            created: Self.wireRide(id: "srv-x", status: .requested),
            createError: RestError.http(status: 403, code: .permissionDenied, message: "forbidden", subCode: nil)
        )
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false)

        service.submit(Self.liveInput())
        XCTAssertEqual(service.activeRequest?.status, .pending, "optimistic pending is visible synchronously")
        await eventually { await api.createCount == 1 } // the refused POST fired

        // Declined affordance state set; the stuck pending is gone; no re-POST /
        // reconcile GET was attempted (a 4xx is not indeterminate).
        await eventually { service.activeRequest?.status == .declined }
        let listCount = await api.rideListCount
        XCTAssertEqual(listCount, 0, "a definitive 4xx never reconciles via GET")
    }

    /// INDETERMINATE (transport blip): the create MAY have landed on the server.
    /// The optimistic pending survives (round-1 fix, carrying the real draft
    /// labels) and a background reconcile GET discovers the real ride and adopts
    /// its server id — proven by a subsequent mutation targeting that id.
    func testIndeterminateCreateFailureSurvivesAndReconcileAdoptsFoundRide() async {
        let input = Self.liveInput()
        // The server DID create it (visible in the rider's own ride list) even
        // though the POST's response never reached the client.
        let landed = Self.wireRide(
            id: "srv-found", status: .requested,
            pickup: MyRobotaxiContracts.RidePlace(lat: input.pickup.coordinate.latitude, lng: input.pickup.coordinate.longitude, label: "1200 Grandscape Blvd"),
            dropoff: MyRobotaxiContracts.RidePlace(lat: input.destination.coordinate.latitude, lng: input.destination.coordinate.longitude, label: "Bell Southstone Yards")
        )
        let api = StubRideAPI(created: landed, createError: URLError(.timedOut))
        await api.setRideList([landed])
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false, reconcilePolicy: Self.fastReconcile)

        service.submit(input)
        await eventually { await api.createCount == 1 } // the failing POST fired
        await eventually { await api.rideListCount >= 1 } // reconcile polled the rider's list

        // Record survives with the REAL draft labels (not placeholders).
        XCTAssertEqual(service.activeRequest?.status, .pending, "an indeterminate failure keeps the optimistic pending")
        XCTAssertEqual(service.activeRequest?.input.destination.label, "Bell Southstone Yards")
        XCTAssertEqual(service.activeRequest?.input.pickup.label, "1200 Grandscape Blvd")

        // Adoption: mutations now target the DISCOVERED server id, not the local UUID.
        service.accept()
        await eventually { await api.acceptCount == 1 }
        let acceptID = await api.lastAcceptID
        XCTAssertEqual(acceptID, "srv-found", "reconcile adopted the found ride's server id")
    }

    /// INDETERMINATE but the reconcile GET finds NOTHING within the window: the
    /// create truly never landed → fall through to the definitive path (declined).
    func testIndeterminateCreateFailureWithNoMatchFallsThroughToDefinitive() async {
        let api = StubRideAPI(created: Self.wireRide(id: "srv-x", status: .requested), createError: URLError(.timedOut))
        // rideList stays empty — the server never created the ride.
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false, reconcilePolicy: Self.fastReconcile)

        service.submit(Self.liveInput())
        await eventually { await api.createCount == 1 }
        await eventually { await api.rideListCount >= 1 } // reconcile tried

        // Nothing matched across the window → definitive → declined affordance.
        await eventually { service.activeRequest?.status == .declined }
    }

    // MARK: WS ride_status_changed round-trips into the UI state

    func testStatusChangedFrameRefetchesAndReconcilesToAccepted() async {
        let api = StubRideAPI(created: Self.wireRide(id: "srv-4", status: .requested))
        // The detail refetch on the frame returns the accepted record.
        await api.setDetail(Self.wireRide(id: "srv-4", status: .accepted, accepted: true))
        let socket = StubRideSocket()
        let service = LiveRideRequestService(api: api, socket: socket, autoStart: true)

        // Seed a pending request (server id srv-4), then deliver the owner-accept frame.
        service.submit(Self.sampleInput())
        await eventually { await api.createCount == 1 }
        await eventually { await socket.isListening } // event pump attached

        await socket.push(.statusChanged(RideStatusChangedPayload(
            rideRequestId: "srv-4", vehicleId: "veh-live", status: .accepted, timestamp: "2026-07-09T18:05:22.114Z"
        )))

        await eventually { service.activeRequest?.status == .accepted }
        XCTAssertNotNil(service.activeRequest?.trackProgress)
    }

    // MARK: - Builders

    private static func sampleInput() -> RideRequestInput {
        RideRequestInput(
            pickup: RideRequestFixtures.savedPlaces[0],
            destination: RideRequestFixtures.recentPlaces[1],
            fleetMemberID: RideRequestFixtures.fleet[0].id
        )
    }

    /// A draft carrying real street labels + concrete coordinates — the
    /// reconcile matches wire rides by these pickup/dropoff coordinates.
    private static func liveInput() -> RideRequestInput {
        RideRequestInput(
            pickup: RidePlace(id: "pin", label: "1200 Grandscape Blvd", subtitle: nil, miles: 0, minutes: 0, icon: "mappin",
                              coordinate: CLLocationCoordinate2D(latitude: 33.09, longitude: -96.85)),
            destination: RidePlace(id: "live|bell", label: "Bell Southstone Yards", subtitle: nil, miles: 5.4, minutes: 16, icon: "mappin",
                                   coordinate: CLLocationCoordinate2D(latitude: 33.15, longitude: -96.82)),
            fleetMemberID: "veh-live"
        )
    }

    /// Drives the reconcile window in ~milliseconds so the "finds nothing"
    /// fall-through resolves inside a unit test.
    private static let fastReconcile = LiveRideRequestService.ReconcilePolicy(attempts: 3, delay: .milliseconds(10))

    private static func wireRide(
        id: String,
        status: MyRobotaxiContracts.RideRequestStatus,
        accepted: Bool = false,
        pickup: MyRobotaxiContracts.RidePlace = MyRobotaxiContracts.RidePlace(lat: 37.7793, lng: -122.3937, label: "Current location"),
        dropoff: MyRobotaxiContracts.RidePlace = MyRobotaxiContracts.RidePlace(lat: 37.6156, lng: -122.3900, label: "SFO · Terminal 2")
    ) -> RideRequest {
        RideRequest(
            id: id,
            riderId: "u-rider",
            ownerId: "u-rider",
            vehicleId: "veh-live",
            pickup: pickup,
            dropoff: dropoff,
            status: status,
            createdAt: Self.isoNow(),
            updatedAt: Self.isoNow(),
            acceptedAt: accepted ? "2026-07-09T18:05:22.114Z" : nil
        )
    }

    /// `createdAt` for a reconcile-discoverable ride must be no earlier than the
    /// optimistic `requestedAt` (≈ now) — use the current time so the match's
    /// recency guard passes regardless of when the suite runs.
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

// MARK: - Stubs

/// In-memory `RideRequestAPI` — records calls + arguments, returns canned records.
private actor StubRideAPI: RideRequestAPI {
    private let createReturn: RideRequest
    private let createError: Error?
    private var detailReturn: RideRequest?
    private var rideList: [RideRequest] = []

    private(set) var createCount = 0
    private(set) var acceptCount = 0
    private(set) var declineCount = 0
    private(set) var cancelCount = 0
    private(set) var rideListCount = 0
    private(set) var lastCreateVehicleID: String?
    private(set) var lastAcceptID: String?
    private(set) var lastDeclineID: String?
    private(set) var lastCancelID: String?

    init(created: RideRequest, createError: Error? = nil) {
        self.createReturn = created
        self.createError = createError
    }

    func setDetail(_ ride: RideRequest) { detailReturn = ride }
    func setRideList(_ rides: [RideRequest]) { rideList = rides }

    func vehicles() async throws -> [VehicleSummary] {
        [VehicleSummary(vehicleId: "veh-live", name: "Lunar", model: "Model Y", year: 2025, color: "Quicksilver",
                        vinLast4: "2046", status: .parked, chargeLevel: 68, estimatedRange: 210,
                        lastUpdated: "2026-07-09T18:00:00Z", role: .owner)]
    }

    func createRideRequest(_ body: RideRequestCreateRequest) async throws -> RideRequest {
        createCount += 1
        lastCreateVehicleID = body.vehicleId
        if let createError { throw createError }
        return createReturn
    }

    func rideRequests(cursor: String?, limit: Int) async throws -> RideRequestsListResponse {
        rideListCount += 1
        return RideRequestsListResponse(items: rideList, hasMore: false)
    }
    func rideRequest(id: String) async throws -> RideRequest { detailReturn ?? createReturn }
    func cancelRideRequest(id: String) async throws -> RideRequest { cancelCount += 1; lastCancelID = id; return createReturn }
    func acceptRideRequest(id: String) async throws -> RideRequest { acceptCount += 1; lastAcceptID = id; return detailReturn ?? createReturn }
    func declineRideRequest(id: String) async throws -> RideRequest { declineCount += 1; lastDeclineID = id; return createReturn }
    func incomingRideRequests(cursor: String?, limit: Int) async throws -> RideRequestsListResponse {
        RideRequestsListResponse(items: [], hasMore: false)
    }
}

/// In-memory `RideEventStreaming` — a controllable ride-event source.
private actor StubRideSocket: RideEventStreaming {
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
