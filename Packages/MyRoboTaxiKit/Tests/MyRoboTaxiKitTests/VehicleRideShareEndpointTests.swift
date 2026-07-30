import XCTest
@testable import MyRoboTaxiKit
import MyRobotaxiContracts

/// REST-surface tests for the owner ride-share pause toggle (MYR-342,
/// rest-api.md §7.18): authenticated PUT path assembly, the `enabled` request key
/// (which is ALSO the response key — NOT the read shapes' `rideShareEnabled`), the
/// echo the client must adopt, idempotency in both directions, the error catalog
/// folded through the typed `RestError`, and the READ half on both surfaces with
/// its tolerant absence.
///
/// The absence case is the one that matters most and is asserted twice below: an
/// ABSENT key means ENABLED, never paused. A consumer that failed closed on a
/// missing key would withdraw a car nobody withdrew — the contract says so in as
/// many words ("consumers MUST NOT render a paused state, MUST NOT hide the
/// ride-request affordance, and MUST NOT fail closed on a missing key").
///
/// No network — the deterministic `RecordingHTTP` replays canonical fixtures.
final class VehicleRideShareEndpointTests: XCTestCase {
    private let devEnvironment = BackendEnvironment(
        restBaseURL: URL(string: "https://api.myrobotaxi.com/api")!,
        webSocketURL: URL(string: "wss://api.myrobotaxi.com/api/ws")!,
        allowsInsecureLoopback: false
    )

    private func client(_ stubs: [RecordingHTTP.Stub]) -> (RestClient, RecordingHTTP) {
        let http = RecordingHTTP(stubs)
        return (RestClient(environment: devEnvironment, tokenProvider: StaticTokenProvider("tkn"), http: http), http)
    }

    // The authenticated PUT lands on /api/tesla/vehicles/{id}/ride-share with the
    // body key `enabled`, and the response's RESOLVED `enabled` comes back for the
    // caller to adopt.
    func testPauseputsEnabledAndReturnsTheResolvedEcho() async throws {
        let (client, http) = client([.init(status: 200, body: try Fixture.data("rest/vehicle_ride_share_paused.json"))])

        let response = try await client.setRideShareEnabled(false, vehicleID: "clxyz1234567890abcdef")

        XCTAssertEqual(response.vehicleId, "clxyz1234567890abcdef")
        XCTAssertEqual(response.enabled, false)

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "PUT")
        XCTAssertEqual(requests[0].url?.path, "/api/tesla/vehicles/clxyz1234567890abcdef/ride-share")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer tkn")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Content-Type"), "application/json; charset=utf-8")

        let body = try XCTUnwrap(requests[0].httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Array(json.keys), ["enabled"], "the server strict-decodes the body — an unknown key is a 400")
        XCTAssertEqual(json["enabled"] as? Bool, false)
        XCTAssertNil(
            json["rideShareEnabled"],
            "`rideShareEnabled` is the READ field name; the write names the owner's input"
        )
    }

    // `false` is a VALUE, not an absence, and it must travel as an explicit JSON
    // `false` rather than being omitted. This is the §7.18 divergence from its
    // §7.16 template made observable: the service-window body treats an absent key
    // as a clear, whereas here BOTH values are decisions and a body that names
    // neither is a `400`.
    func testPauseSendsAnExplicitFalseRatherThanOmittingTheKey() async throws {
        let (client, http) = client([.init(status: 200, body: try Fixture.data("rest/vehicle_ride_share_paused.json"))])
        _ = try await client.setRideShareEnabled(false, vehicleID: "veh")

        let requests = await http.capturedRequests()
        let raw = String(decoding: try XCTUnwrap(requests[0].httpBody), as: UTF8.self)
        XCTAssertTrue(raw.contains("\"enabled\":false"), "the pause must be an explicit false — got \(raw)")
    }

    // Idempotent in BOTH directions (§4.5 / §7.18): resume is an ordinary write of
    // the other value, not a separate verb, and repeating either yields the same
    // 200 and the same stored value.
    func testResumeIsTheSameWriteWithTheOtherValueAndRepeatsCleanly() async throws {
        let resumed = try Fixture.data("rest/vehicle_ride_share_resumed.json")
        let (client, http) = client([
            .init(status: 200, body: resumed),
            .init(status: 200, body: resumed),
        ])

        let first = try await client.setRideShareEnabled(true, vehicleID: "clxyz1234567890abcdef")
        let second = try await client.setRideShareEnabled(true, vehicleID: "clxyz1234567890abcdef")
        XCTAssertEqual(first, second, "PUTting the same value twice is the same answer — not a one-way door")
        XCTAssertEqual(first.enabled, true)

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/api/tesla/vehicles/clxyz1234567890abcdef/ride-share")
        }
    }

    // The error catalog folds onto the typed outcomes the app switches on. 403 is
    // the one worth naming: §7.18 refuses a VIEWER AT ANY SHARE TIER, including the
    // top `rides` tier, because the pause is the owner's switch and a rider able to
    // flip it would invert the feature. 404 stays deliberately indistinguishable
    // from ownership-filtered (§7.12/§7.14/§7.16).
    func testErrorCatalogFoldsOntoTypedOutcomes() async {
        let cases: [(status: Int, code: String, expected: RestError.CommandFailureKind)] = [
            (400, "invalid_request", .invalidRequest),
            (401, "auth_failed", .auth),
            (403, "vehicle_not_owned", .notOwned),
            (404, "not_found", .notFound),
            (500, "internal_error", .other),
        ]
        for c in cases {
            let body = Data(#"{"error":{"code":"\#(c.code)","message":"nope"}}"#.utf8)
            // 401 retries once after the refresh hook, so stub it twice.
            let stubs = Array(repeating: RecordingHTTP.Stub(status: c.status, body: body), count: 2)
            let (client, _) = client(stubs)
            do {
                _ = try await client.setRideShareEnabled(false, vehicleID: "veh")
                XCTFail("expected an error on \(c.status)")
            } catch let error as RestError {
                XCTAssertEqual(error.commandFailureKind, c.expected, "for \(c.code)")
            } catch {
                XCTFail("expected RestError for \(c.code), got \(error)")
            }
        }
    }

    // A 500 is ATOMIC and must NEVER read as success: §7.18 spells out why — "a
    // 200 over a failed write would leave an owner believing their car is paused
    // while it is still taking requests". Asserted as a throw rather than a
    // silently-defaulted value.
    func testStoreFailureThrowsRatherThanReportingAPause() async {
        let body = Data(#"{"error":{"code":"internal_error","message":"store failure"}}"#.utf8)
        let (client, _) = client([.init(status: 500, body: body)])
        do {
            _ = try await client.setRideShareEnabled(false, vehicleID: "veh")
            XCTFail("a failed write must not resolve to a value the owner would trust")
        } catch let error as RestError {
            XCTAssertEqual(error.commandFailureKind, .other)
        } catch {
            XCTFail("expected RestError, got \(error)")
        }
    }

    // Contracts 0.20.0 — the READ half. `rideShareEnabled` decodes off BOTH read
    // surfaces, and the list fixture carries all three states that matter:
    // explicit false (paused), explicit true, and the ABSENT key.
    func testRideShareEnabledDecodesOnBothReadSurfaces() async throws {
        let (client, _) = client([
            .init(status: 200, body: try Fixture.data("rest/snapshot_ride_share_paused.json")),
            .init(status: 200, body: try Fixture.data("rest/vehicles_list_ride_share.json")),
        ])

        let state = try await client.snapshot(vehicleId: "clxyz1234567890abcdef")
        XCTAssertEqual(state.rideShareEnabled, false)
        XCTAssertEqual(
            state.status, .parked,
            "the pause is OWNER INTENT, not vehicle state — the car itself is perfectly healthy"
        )

        let items = try await client.vehicles()
        XCTAssertEqual(items[0].rideShareEnabled, false, "explicit false — paused")
        XCTAssertEqual(items[1].rideShareEnabled, true, "explicit true — taking requests")
        XCTAssertNil(items[2].rideShareEnabled, "an absent key decodes as nil, which means ENABLED, never paused")
    }

    // Tolerant decode, stated at the type level: an ABSENT key (a pre-0.20.0
    // server) is nil. Nil is NOT "we couldn't read it" and is NOT paused — the
    // consumer rule is `== false` explicitly, never `!= true`.
    func testAbsentRideShareEnabledDecodesAsNilOnASummary() throws {
        let json = #"{"vehicleId":"v","name":"n","model":"Model 3","year":2024,"color":"","vinLast4":"0001","status":"parked","chargeLevel":50,"estimatedRange":100,"lastUpdated":"2026-07-29T00:00:00Z","role":"owner"}"#
        let summary = try JSONDecoder().decode(VehicleSummary.self, from: Data(json.utf8))
        XCTAssertNil(summary.rideShareEnabled)
        XCTAssertNotEqual(summary.rideShareEnabled, false, "absence must never satisfy the paused predicate")
    }

    // The parked `snapshot.json` every other test uses must keep carrying NO
    // ride-share key — the fixture pair is what makes "absent means enabled"
    // observable rather than asserted in prose, and it is what keeps every
    // pre-MYR-342 test reading an un-paused car.
    func testTheBaselineSnapshotCarriesNoRideShareKey() async throws {
        let (client, _) = client([.init(status: 200, body: try Fixture.data("rest/snapshot.json"))])
        let state = try await client.snapshot(vehicleId: "clxyz1234567890abcdef")
        XCTAssertNil(state.rideShareEnabled)
    }
}
