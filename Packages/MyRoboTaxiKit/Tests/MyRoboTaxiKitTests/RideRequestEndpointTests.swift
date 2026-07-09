import XCTest
@testable import MyRoboTaxiKit
import MyRobotaxiContracts

/// Fixture round-trip tests for the P10 ride-request REST surface (rest-api.md
/// §7.8 — MYR-174 rider endpoints + MYR-175 owner endpoints): request-path +
/// method + query assembly, the create body serialization, the bare-object vs
/// envelope decode split, and the `409 conflict` illegal-transition mapping. No
/// network — the deterministic `RecordingHTTP` replays canonical fixtures.
final class RideRequestEndpointTests: XCTestCase {
    private let devEnvironment = BackendEnvironment(
        restBaseURL: URL(string: "https://api.myrobotaxi.com/api")!,
        webSocketURL: URL(string: "wss://api.myrobotaxi.com/api/ws")!,
        allowsInsecureLoopback: false
    )

    private func client(_ stubs: [RecordingHTTP.Stub]) -> (RestClient, RecordingHTTP) {
        let http = RecordingHTTP(stubs)
        return (RestClient(environment: devEnvironment, tokenProvider: StaticTokenProvider("t"), http: http), http)
    }

    // MARK: - Create (POST, 201, body serialization)

    func testCreateTargetsPostPathWithJSONBodyAndDecodes201() async throws {
        let (client, http) = client([.init(status: 201, body: try Fixture.data("rest/ride_request.created.json"))])

        let body = RideRequestCreateRequest(
            vehicleId: "clxyz1234567890abcdef",
            pickup: RidePlace(lat: 37.7793, lng: -122.3937, label: "Current location"),
            dropoff: RidePlace(lat: 37.6156, lng: -122.3900, label: "SFO · Terminal 2", address: "San Francisco International")
        )
        let created = try await client.createRideRequest(body)

        XCTAssertEqual(created.id, "clride0000000000000001")
        XCTAssertEqual(created.status, .requested)
        XCTAssertEqual(created.ownerId, created.riderId, "v1 owner-only access => ownerId == riderId")
        XCTAssertEqual(created.dropoff.label, "SFO · Terminal 2")
        XCTAssertNil(created.scheduledFor, "on-demand request omits scheduledFor")

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[0].url?.path, "/api/ride-requests")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Content-Type"), "application/json; charset=utf-8")

        // The create body round-trips through the wire back into the contract type.
        let sentBody = try XCTUnwrap(requests[0].httpBody)
        let decodedBody = try JSONDecoder().decode(RideRequestCreateRequest.self, from: sentBody)
        XCTAssertEqual(decodedBody.vehicleId, "clxyz1234567890abcdef")
        XCTAssertEqual(decodedBody.pickup.label, "Current location")
    }

    // MARK: - Detail (bare object) + optional-field decode

    func testDetailDecodesBareObjectWithOptionalFields() async throws {
        let (client, http) = client([.init(status: 200, body: try Fixture.data("rest/ride_request.accepted.json"))])

        let ride = try await client.rideRequest(id: "clride0000000000000002")

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertEqual(requests[0].url?.path, "/api/ride-requests/clride0000000000000002")
        XCTAssertEqual(ride.status, .accepted)
        XCTAssertEqual(ride.passengerName, "Maya Chen")
        XCTAssertEqual(ride.scheduledFor, "2026-07-10T13:30:00.000Z")
        XCTAssertNotNil(ride.acceptedAt)
        XCTAssertNil(ride.completedAt, "omitted until completed")
    }

    // MARK: - Rider list (envelope, cursor + limit clamp)

    func testRideRequestsDecodesEnvelopeAndForwardsCursorClampingLimit() async throws {
        let (client, http) = client([.init(status: 200, body: try Fixture.data("rest/ride_requests_list.json"))])

        let page = try await client.rideRequests(cursor: "PAGE2", limit: 500)

        XCTAssertEqual(page.items.count, 2)
        XCTAssertTrue(page.hasMore)
        XCTAssertNotNil(page.nextCursor, "non-null cursor => not the final page")
        XCTAssertEqual(page.items[0].status, .declined)
        XCTAssertEqual(page.items[1].scheduledFor, "2026-07-11T06:30:00.000Z")

        let requests = await http.capturedRequests()
        let components = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(components.path, "/api/ride-requests")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "cursor" })?.value, "PAGE2")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "limit" })?.value, "100", "limit clamps to 1…100")
    }

    // MARK: - Owner incoming feed (literal /incoming segment, final page)

    func testIncomingTargetsLiteralSegmentAndDecodesFinalPage() async throws {
        let (client, http) = client([.init(status: 200, body: try Fixture.data("rest/ride_requests_incoming.json"))])

        let page = try await client.incomingRideRequests()

        XCTAssertEqual(page.items.count, 2)
        XCTAssertFalse(page.hasMore)
        XCTAssertNil(page.nextCursor, "null nextCursor => the final page")
        XCTAssertTrue(page.items.allSatisfy { $0.status == .requested }, "incoming feed is requested-only")

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests[0].url?.path, "/api/ride-requests/incoming")
    }

    // MARK: - Owner accept (POST, no body, acceptedAt stamped)

    func testAcceptTargetsPostAcceptPathAndDecodesAcceptedAt() async throws {
        let (client, http) = client([.init(status: 200, body: try Fixture.data("rest/ride_request.accepted.json"))])

        let ride = try await client.acceptRideRequest(id: "clride0000000000000002")

        XCTAssertEqual(ride.status, .accepted)
        XCTAssertNotNil(ride.acceptedAt)

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[0].url?.path, "/api/ride-requests/clride0000000000000002/accept")
    }

    func testCancelAndDeclineTargetCorrectActionPaths() async throws {
        let (cancelClient, cancelHTTP) = client([.init(status: 200, body: try Fixture.data("rest/ride_request.accepted.json"))])
        _ = try await cancelClient.cancelRideRequest(id: "r9")
        let cancelReqs = await cancelHTTP.capturedRequests()
        XCTAssertEqual(cancelReqs[0].httpMethod, "POST")
        XCTAssertEqual(cancelReqs[0].url?.path, "/api/ride-requests/r9/cancel")

        let (declineClient, declineHTTP) = client([.init(status: 200, body: try Fixture.data("rest/ride_request.accepted.json"))])
        _ = try await declineClient.declineRideRequest(id: "r9")
        let declineReqs = await declineHTTP.capturedRequests()
        XCTAssertEqual(declineReqs[0].url?.path, "/api/ride-requests/r9/decline")
    }

    // MARK: - 409 conflict (illegal lifecycle transition)

    func testIllegalTransitionMapsToTypedConflict() async throws {
        let (client, _) = client([.init(status: 409, body: try Fixture.data("rest/error.conflict.json"))])

        do {
            _ = try await client.acceptRideRequest(id: "clride0000000000000002")
            XCTFail("expected RestError.http 409 conflict")
        } catch let error as RestError {
            guard case .http(let status, let code, _, _) = error else { return XCTFail("wrong case") }
            XCTAssertEqual(status, 409)
            XCTAssertEqual(code, .conflict, "branch on the typed code, never the message")
        }
    }
}
