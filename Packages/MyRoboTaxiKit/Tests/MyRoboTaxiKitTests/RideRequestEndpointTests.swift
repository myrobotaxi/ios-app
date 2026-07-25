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

    // MARK: - Dispatch v2 actions (MYR-270 — owner-driven picked-up / start /
    // dropped-off). Each asserts path + method + no query, an idempotent-200
    // no-op decode, and the typed 409 on an illegal transition.

    private func rideBody(id: String, status: String) -> Data {
        Data("""
        {
          "id": "\(id)",
          "riderId": "u-rider", "ownerId": "u-owner", "vehicleId": "clxyz1234567890abcdef",
          "pickup": { "lat": 37.7793, "lng": -122.3937, "label": "Current location" },
          "dropoff": { "lat": 37.6156, "lng": -122.3900, "label": "SFO · Terminal 2" },
          "status": "\(status)",
          "createdAt": "2026-07-10T18:00:00.000Z",
          "updatedAt": "2026-07-10T18:06:00.000Z",
          "acceptedAt": "2026-07-10T18:04:00.000Z"
        }
        """.utf8)
    }

    /// `POST …/picked-up` (owner) targets the action path, no body/query, and
    /// decodes the returned `arrived` record (accepted → arrived).
    func testPickedUpTargetsPostPickedUpPathAndDecodesArrived() async throws {
        let (client, http) = client([.init(status: 200, body: rideBody(id: "clride0000000000000002", status: "arrived"))])

        let ride = try await client.pickedUp(rideID: "clride0000000000000002")
        XCTAssertEqual(ride.status, .arrived, "picked-up advances the ride to arrived (awaiting rider start)")

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[0].url?.path, "/api/ride-requests/clride0000000000000002/picked-up")
        XCTAssertNil(requests[0].url?.query, "action POST carries no query")
    }

    /// `…/picked-up` idempotent 200: an already-`arrived` ride returns the current
    /// record (a re-tap / retry is safe), decoding exactly like the advance.
    func testPickedUpIsIdempotent200OnAlreadyArrived() async throws {
        let (client, _) = client([.init(status: 200, body: rideBody(id: "r-pu", status: "arrived"))])
        let ride = try await client.pickedUp(rideID: "r-pu")
        XCTAssertEqual(ride.status, .arrived, "idempotent 200 returns the current arrived record")
    }

    /// `POST …/start` (rider) targets the action path and decodes the returned
    /// `enroute` record — starting is what pushes the dropoff nav server-side.
    func testStartTargetsPostStartPathAndDecodesEnroute() async throws {
        let (client, http) = client([.init(status: 200, body: rideBody(id: "clride0000000000000002", status: "enroute"))])

        let ride = try await client.start(rideID: "clride0000000000000002")
        XCTAssertEqual(ride.status, .enroute, "start advances arrived → enroute (leg 2)")

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[0].url?.path, "/api/ride-requests/clride0000000000000002/start")
        XCTAssertNil(requests[0].url?.query, "action POST carries no query")
    }

    /// `…/start` idempotent 200: an already-`enroute` ride returns the current
    /// record so a re-tap is safe.
    func testStartIsIdempotent200OnAlreadyEnroute() async throws {
        let (client, _) = client([.init(status: 200, body: rideBody(id: "r-start", status: "enroute"))])
        let ride = try await client.start(rideID: "r-start")
        XCTAssertEqual(ride.status, .enroute)
    }

    /// `…/start` from `accepted` (owner has NOT confirmed pickup yet) is the guarded
    /// `409 conflict` — the rider cannot start before pickup is confirmed.
    func testStartBeforePickupMapsToTypedConflict() async throws {
        let (client, _) = client([.init(status: 409, body: try Fixture.data("rest/error.conflict.json"))])
        do {
            _ = try await client.start(rideID: "r-start")
            XCTFail("expected RestError.http 409 conflict")
        } catch let error as RestError {
            guard case .http(let status, let code, _, _) = error else { return XCTFail("wrong case") }
            XCTAssertEqual(status, 409)
            XCTAssertEqual(code, .conflict, "branch on the typed code, never the message")
        }
    }

    /// `POST …/dropped-off` (owner) targets the action path and decodes the returned
    /// `completed` record (enroute → completed).
    func testDroppedOffTargetsPostDroppedOffPathAndDecodesCompleted() async throws {
        let (client, http) = client([.init(status: 200, body: rideBody(id: "clride0000000000000002", status: "completed"))])

        let ride = try await client.droppedOff(rideID: "clride0000000000000002")
        XCTAssertEqual(ride.status, .completed, "dropped-off completes the ride")

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[0].url?.path, "/api/ride-requests/clride0000000000000002/dropped-off")
        XCTAssertNil(requests[0].url?.query, "action POST carries no query")
    }

    /// `…/dropped-off` idempotent 200 on an already-`completed` ride.
    func testDroppedOffIsIdempotent200OnAlreadyCompleted() async throws {
        let (client, _) = client([.init(status: 200, body: rideBody(id: "r-do", status: "completed"))])
        let ride = try await client.droppedOff(rideID: "r-do")
        XCTAssertEqual(ride.status, .completed)
    }

    /// Any illegal source state for an action POST is a typed `409 conflict` the
    /// caller reconciles against — never an auto-retry of the same POST.
    func testDroppedOffIllegalTransitionMapsToTypedConflict() async throws {
        let (client, _) = client([.init(status: 409, body: try Fixture.data("rest/error.conflict.json"))])
        do {
            _ = try await client.droppedOff(rideID: "r-do")
            XCTFail("expected RestError.http 409 conflict")
        } catch let error as RestError {
            guard case .http(let status, let code, _, _) = error else { return XCTFail("wrong case") }
            XCTAssertEqual(status, 409)
            XCTAssertEqual(code, .conflict)
        }
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

    // MARK: - 409 ride_active (MYR-230, §7.8) — sibling activeRideRequest adoption

    /// A create refused `409 ride_active` carries a sibling `activeRideRequest`
    /// (byte-for-byte the `RideRequest` GET shape) alongside the standard error
    /// envelope, so the client ADOPTS the rider's existing open ride rather than
    /// surfacing a decline. It maps to the dedicated `.rideActive(active:)` case
    /// with the ride decoded — NOT the generic `.http` path a `conflict` takes.
    /// The contracts `ErrorPayload.Code` enum has no `ride_active` member yet, so
    /// this also proves the tolerant raw-string match (`.unrecognized`) works.
    func testRideActive409DecodesSiblingActiveRideRequestForAdoption() async throws {
        let body = Data("""
        {
          "error": { "code": "ride_active", "message": "you already have an active ride request", "subCode": null },
          "activeRideRequest": {
            "id": "clride0000000000000007",
            "riderId": "u-rider",
            "ownerId": "u-rider",
            "vehicleId": "clxyz1234567890abcdef",
            "pickup": { "lat": 37.7793, "lng": -122.3937, "label": "Current location" },
            "dropoff": { "lat": 37.6156, "lng": -122.3900, "label": "SFO · Terminal 2", "address": "San Francisco International" },
            "status": "accepted",
            "createdAt": "2026-07-10T18:00:00.000Z",
            "updatedAt": "2026-07-10T18:04:00.000Z",
            "acceptedAt": "2026-07-10T18:04:00.000Z"
          }
        }
        """.utf8)
        let (client, _) = client([.init(status: 409, body: body)])

        do {
            _ = try await client.createRideRequest(RideRequestCreateRequest(
                vehicleId: "clxyz1234567890abcdef",
                pickup: RidePlace(lat: 37.7793, lng: -122.3937, label: "Current location"),
                dropoff: RidePlace(lat: 37.6156, lng: -122.3900, label: "SFO · Terminal 2")
            ))
            XCTFail("expected RestError.rideActive")
        } catch let error as RestError {
            guard case .rideActive(let active) = error else { return XCTFail("wrong case: \(error)") }
            let adopted = try XCTUnwrap(active, "the sibling activeRideRequest must decode for adoption")
            XCTAssertEqual(adopted.id, "clride0000000000000007")
            XCTAssertEqual(adopted.status, .accepted)
            XCTAssertEqual(adopted.dropoff.label, "SFO · Terminal 2")
        }
    }

    /// The rare terminal-race body (§7.8): `409 ride_active` with NO
    /// `activeRideRequest` sibling. It still maps to `.rideActive`, with
    /// `active == nil` so the caller re-syncs from its own open list.
    func testRideActive409WithoutSiblingYieldsNilActive() async throws {
        let body = Data("""
        { "error": { "code": "ride_active", "message": "you already have an active ride request", "subCode": null } }
        """.utf8)
        let (client, _) = client([.init(status: 409, body: body)])

        do {
            _ = try await client.createRideRequest(RideRequestCreateRequest(
                vehicleId: "clxyz1234567890abcdef",
                pickup: RidePlace(lat: 37.7793, lng: -122.3937, label: "Current location"),
                dropoff: RidePlace(lat: 37.6156, lng: -122.3900, label: "SFO · Terminal 2")
            ))
            XCTFail("expected RestError.rideActive")
        } catch let error as RestError {
            guard case .rideActive(let active) = error else { return XCTFail("wrong case: \(error)") }
            XCTAssertNil(active, "missing sibling → nil, caller refetches its open list")
        }
    }
}
