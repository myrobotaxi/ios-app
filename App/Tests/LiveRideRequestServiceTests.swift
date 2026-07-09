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

    private static func wireRide(id: String, status: MyRobotaxiContracts.RideRequestStatus, accepted: Bool = false) -> RideRequest {
        RideRequest(
            id: id,
            riderId: "u-rider",
            ownerId: "u-rider",
            vehicleId: "veh-live",
            pickup: MyRobotaxiContracts.RidePlace(lat: 37.7793, lng: -122.3937, label: "Current location"),
            dropoff: MyRobotaxiContracts.RidePlace(lat: 37.6156, lng: -122.3900, label: "SFO · Terminal 2"),
            status: status,
            createdAt: "2026-07-09T18:00:00.000Z",
            updatedAt: "2026-07-09T18:00:00.000Z",
            acceptedAt: accepted ? "2026-07-09T18:05:22.114Z" : nil
        )
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
    private var detailReturn: RideRequest?

    private(set) var createCount = 0
    private(set) var acceptCount = 0
    private(set) var declineCount = 0
    private(set) var cancelCount = 0
    private(set) var lastCreateVehicleID: String?
    private(set) var lastAcceptID: String?
    private(set) var lastDeclineID: String?
    private(set) var lastCancelID: String?

    init(created: RideRequest) { self.createReturn = created }

    func setDetail(_ ride: RideRequest) { detailReturn = ride }

    func vehicles() async throws -> [VehicleSummary] {
        [VehicleSummary(vehicleId: "veh-live", name: "Lunar", model: "Model Y", year: 2025, color: "Quicksilver",
                        vinLast4: "2046", status: .parked, chargeLevel: 68, estimatedRange: 210,
                        lastUpdated: "2026-07-09T18:00:00Z", role: .owner)]
    }

    func createRideRequest(_ body: RideRequestCreateRequest) async throws -> RideRequest {
        createCount += 1
        lastCreateVehicleID = body.vehicleId
        return createReturn
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
