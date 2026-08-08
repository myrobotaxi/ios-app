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

    // MARK: - Owner upcoming reservations for ONE vehicle (MYR-360)

    /// The WIRE, exactly: the same `/incoming` resource, plus the one query
    /// parameter that selects the upcoming-reservations slice for a vehicle. The
    /// parameter NAME is the single thing the client and the server must agree on
    /// by string, so it is asserted against the constant AND against the literal.
    func testUpcomingReservationsTargetsIncomingWithTheVehicleQuery() async throws {
        let (client, http) = client([
            .init(status: 200, body: try Fixture.data("rest/ride_requests_upcoming_for_vehicle.json"))
        ])

        _ = try await client.upcomingReservations(vehicleID: "clxyz1234567890abcdef")

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests[0].httpMethod, "GET")
        let components = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(components.path, "/api/ride-requests/incoming", "the same resource as the owner feed")
        XCTAssertEqual(RestClient.upcomingForVehicleQueryName, "upcomingForVehicle")
        XCTAssertEqual(
            components.queryItems,
            [
                URLQueryItem(name: "upcomingForVehicle", value: "clxyz1234567890abcdef"),
                URLQueryItem(name: "limit", value: "20")
            ],
            "exactly two query items on a cursorless first page, default limit 20"
        )
    }

    /// The decode the pause warning is built from: `requesterName` and
    /// `scheduledFor` on every item, SOONEST FIRST, and an absent `requesterName`
    /// surviving as `nil` rather than as an empty string the client would then have
    /// to guess about.
    func testUpcomingReservationsDecodeCarriesRequesterNameAndScheduledFor() async throws {
        let (client, _) = client([
            .init(status: 200, body: try Fixture.data("rest/ride_requests_upcoming_for_vehicle.json"))
        ])

        let page = try await client.upcomingReservations(vehicleID: "clxyz1234567890abcdef")

        XCTAssertEqual(page.items.count, 2)
        XCTAssertFalse(page.hasMore)
        XCTAssertNil(page.nextCursor, "null nextCursor => the final page")
        XCTAssertTrue(page.items.allSatisfy { $0.status == .accepted }, "reservations are ACCEPTED, not requested")

        XCTAssertEqual(page.items[0].requesterName, "Alex")
        XCTAssertEqual(page.items[0].scheduledFor, "2026-08-02T17:30:00.000Z")
        XCTAssertNil(page.items[1].requesterName, "an omitted name decodes as absent, never as \"\"")
        XCTAssertEqual(page.items[1].scheduledFor, "2026-08-03T01:15:00.000Z")

        let times = page.items.compactMap(\.scheduledFor)
        XCTAssertEqual(times, times.sorted(), "the server orders soonest first")
    }

    /// Cursor + limit behave exactly as the sibling list endpoints', because they
    /// ARE the sibling list endpoint — same envelope, same `(createdAt, id)` cursor,
    /// same 1…100 clamp.
    func testUpcomingReservationsForwardsCursorAndClampsLimit() async throws {
        let (client, http) = client([
            .init(status: 200, body: try Fixture.data("rest/ride_requests_upcoming_for_vehicle.json"))
        ])

        _ = try await client.upcomingReservations(vehicleID: "veh-1", cursor: "PAGE2", limit: 500)

        let requests = await http.capturedRequests()
        let components = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(
            components.queryItems,
            [
                URLQueryItem(name: "upcomingForVehicle", value: "veh-1"),
                URLQueryItem(name: "limit", value: "100"),
                URLQueryItem(name: "cursor", value: "PAGE2")
            ]
        )
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

    // MARK: - 409 vehicle_unavailable (MYR-233, MYR-277)

    /// A create refused because the VEHICLE can't take the ride surfaces as a
    /// plain typed `.http(409, …)` whose code carries the raw wire value —
    /// `vehicle_unavailable` is not a member of the contracts `ErrorPayload.Code`
    /// enum as of 0.14.0, so it lands in the forward-compat `.unrecognized` arm.
    /// `RestError.isVehicleUnavailable` reads that typed value (never the human
    /// `message`, FR-7.1), so callers branch honestly instead of string-matching.
    func testVehicleUnavailable409IsTypedAndDetectable() async throws {
        let body = Data("""
        { "error": { "code": "vehicle_unavailable", "message": "vehicle has an active ride", "subCode": null } }
        """.utf8)
        let (client, _) = client([.init(status: 409, body: body)])

        do {
            _ = try await client.createRideRequest(RideRequestCreateRequest(
                vehicleId: "clxyz1234567890abcdef",
                pickup: RidePlace(lat: 37.7793, lng: -122.3937, label: "Current location"),
                dropoff: RidePlace(lat: 37.6156, lng: -122.3900, label: "SFO · Terminal 2")
            ))
            XCTFail("expected a 409 RestError")
        } catch let error as RestError {
            guard case .http(let status, let code, _, _) = error else { return XCTFail("wrong case: \(error)") }
            XCTAssertEqual(status, 409)
            XCTAssertEqual(code?.rawValue, "vehicle_unavailable")
            XCTAssertTrue(error.isVehicleUnavailable)
            // It must NOT be confused with the rider-scoped `ride_active` 409.
            if case .rideActive = error { XCTFail("vehicle_unavailable is not ride_active") }
        }
    }

    /// The helper is narrow: a different 409, a different status, and the
    /// non-`.http` cases all read false, so no unrelated failure is ever
    /// mistaken for a busy vehicle.
    func testIsVehicleUnavailableIsNarrow() {
        XCTAssertFalse(RestError.http(status: 409, code: .conflict, message: "x", subCode: nil).isVehicleUnavailable)
        XCTAssertFalse(RestError.http(status: 409, code: .rideActive, message: "x", subCode: nil).isVehicleUnavailable)
        XCTAssertFalse(
            RestError.http(status: 403, code: .unrecognized("vehicle_unavailable"), message: "x", subCode: nil).isVehicleUnavailable,
            "only a 409 carries this meaning"
        )
        XCTAssertFalse(RestError.invalidResponse.isVehicleUnavailable)
        XCTAssertFalse(RestError.rideActive(active: nil).isVehicleUnavailable)
    }

    // MARK: - 403 vehicle_not_owned on CREATE (MYR-478)

    /// §7.8's create gate reads the grant's live `allow_rides` flag, and the
    /// contract spells out what a viewer who fails it gets: *"visible-but-not-
    /// accessible, and any viewer whose grant lacks the ride capability →
    /// `403 vehicle_not_owned`"*. That is the wire behind the external-beta pair
    /// (MYR-451): the owner had turned James's Rides toggle off, his app kept
    /// offering the booking flow, and the create was refused at the last step.
    ///
    /// It surfaces as a plain typed `.http(403, …)`, so `isVehicleNotOwned` reads
    /// the typed code's RAW WIRE VALUE (never the human `message`, FR-7.1) — the
    /// same forward-compat shape `isVehicleUnavailable` uses.
    func testVehicleNotOwned403IsTypedAndDetectable() async throws {
        let body = Data("""
        { "error": { "code": "vehicle_not_owned", "message": "vehicle not accessible", "subCode": null } }
        """.utf8)
        let (client, _) = client([.init(status: 403, body: body)])

        do {
            _ = try await client.createRideRequest(RideRequestCreateRequest(
                vehicleId: "clxyz1234567890abcdef",
                pickup: RidePlace(lat: 37.7793, lng: -122.3937, label: "Current location"),
                dropoff: RidePlace(lat: 37.6156, lng: -122.3900, label: "SFO \u{00B7} Terminal 2")
            ))
            XCTFail("expected a 403 RestError")
        } catch let error as RestError {
            guard case .http(let status, let code, _, _) = error else { return XCTFail("wrong case: \(error)") }
            XCTAssertEqual(status, 403)
            XCTAssertEqual(code?.rawValue, "vehicle_not_owned")
            XCTAssertTrue(error.isVehicleNotOwned)
        }
    }

    /// **NARROW ON THE CODE, NOT THE STATUS**, and that is the whole reason this
    /// predicate exists rather than a bare `httpStatus == 403`.
    ///
    /// A 403 carrying `auth_failed` / `auth_timeout` is a DEAD SESSION (MYR-220
    /// split it out precisely because the backend puts auth codes on a 403), and a
    /// 403 carrying `permission_denied` is a wrong-role action — on §7.8 that is
    /// an owner trying to cancel, which is not a capability a rider can be told
    /// about. Both must keep their own branches.
    func testIsVehicleNotOwnedIsNarrow() {
        XCTAssertFalse(RestError.http(status: 403, code: .authFailed, message: "x", subCode: nil).isVehicleNotOwned)
        XCTAssertFalse(RestError.http(status: 403, code: .authTimeout, message: "x", subCode: nil).isVehicleNotOwned)
        XCTAssertFalse(RestError.http(status: 403, code: .permissionDenied, message: "x", subCode: nil).isVehicleNotOwned)
        XCTAssertFalse(
            RestError.http(status: 404, code: .unrecognized("vehicle_not_owned"), message: "x", subCode: nil).isVehicleNotOwned,
            "only a 403 carries this meaning"
        )
        XCTAssertFalse(RestError.invalidResponse.isVehicleNotOwned)
        XCTAssertFalse(RestError.transport(underlying: URLError(.notConnectedToInternet)).isVehicleNotOwned)
        // And it is disjoint from the 409 arm, so the two can never both fire.
        XCTAssertFalse(
            RestError.http(status: 409, code: .unrecognized("vehicle_unavailable"), message: "x", subCode: nil).isVehicleNotOwned
        )
        XCTAssertFalse(
            RestError.http(status: 403, code: .unrecognized("vehicle_not_owned"), message: "x", subCode: nil).isVehicleUnavailable
        )
    }
}
