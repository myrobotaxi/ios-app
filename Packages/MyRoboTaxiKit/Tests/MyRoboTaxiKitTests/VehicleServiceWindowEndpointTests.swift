import XCTest
@testable import MyRoboTaxiKit
import MyRobotaxiContracts

/// REST-surface tests for the owner "expected back" service-window endpoint
/// (MYR-316): authenticated PUT path assembly, the `expectedEndAt` request key,
/// the explicit-null CLEAR, the owner-column echo the client adopts, and the
/// error catalog folded through the typed `RestError`. Plus the READ half:
/// `serviceEstimatedEndAt` decoding off both read surfaces, and its tolerant
/// absence.
///
/// MYR-362 — **`expectedEndAt` is the key on BOTH halves of §7.16**, request and
/// response, and the response's is the OWNER COLUMN rather than the resolved
/// `serviceEstimatedEndAt`. This file used to assert the opposite against a
/// hand-authored fixture that agreed with it, so the suite was green about a body
/// the server has never sent — and every SET in production decoded nil. The two
/// fixtures are corrected to §7.16's own "Response `200`" example. **The read
/// surfaces are unaffected**: `serviceEstimatedEndAt` remains the §7.0 / §7.1 key
/// and is where Tesla precedence becomes visible, which is exactly the asymmetry
/// the endpoint intends.
///
/// No network — the deterministic `RecordingHTTP` replays canonical fixtures.
final class VehicleServiceWindowEndpointTests: XCTestCase {
    private let devEnvironment = BackendEnvironment(
        restBaseURL: URL(string: "https://api.myrobotaxi.com/api")!,
        webSocketURL: URL(string: "wss://api.myrobotaxi.com/api/ws")!,
        allowsInsecureLoopback: false
    )

    private func client(_ stubs: [RecordingHTTP.Stub]) -> (RestClient, RecordingHTTP) {
        let http = RecordingHTTP(stubs)
        return (RestClient(environment: devEnvironment, tokenProvider: StaticTokenProvider("tkn"), http: http), http)
    }

    // The authenticated PUT lands on /api/tesla/vehicles/{id}/service-window with
    // the body key `expectedEndAt`, and the response echoes the stored OWNER
    // COLUMN under that same key (MYR-362).
    func testSetServiceWindowPutsExpectedEndAtAndReturnsTheStoredOwnerColumn() async throws {
        let (client, http) = client([.init(status: 200, body: try Fixture.data("rest/vehicle_service_window.json"))])

        let response = try await client.setServiceWindow(
            expectedEndAt: "2026-08-01T21:00:00.000Z", vehicleID: "clxyz1234567890abcdef"
        )

        XCTAssertEqual(response.vehicleId, "clxyz1234567890abcdef")
        // The instant the owner sent, re-formatted by the server to `time.RFC3339`
        // (seconds, no fractional part). The caller adopts THIS rather than the
        // string it submitted, so a server that normalizes or coerces is honoured.
        XCTAssertEqual(response.expectedEndAt, "2026-08-01T21:00:00Z")

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "PUT")
        XCTAssertEqual(requests[0].url?.path, "/api/tesla/vehicles/clxyz1234567890abcdef/service-window")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer tkn")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Content-Type"), "application/json; charset=utf-8")

        let body = try XCTUnwrap(requests[0].httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Array(json.keys), ["expectedEndAt"], "the server strict-decodes the body — no extra keys")
        XCTAssertEqual(json["expectedEndAt"] as? String, "2026-08-01T21:00:00.000Z")
        XCTAssertNil(
            json["serviceEstimatedEndAt"],
            "`serviceEstimatedEndAt` belongs to the READ surfaces only; sending it would 400"
        )
    }

    // MYR-362 — the tripwire. §7.16 never emits `serviceEstimatedEndAt`, so a
    // response type shaped around that key decodes SILENTLY to nil on every save:
    // no throw, no notice, no log, and an owner's completion date gone from a
    // sheet whose write returned `200`. Asserting on the RAW fixture keys is the
    // only way to catch a wrong key on an optional property, because the decode
    // itself can never fail.
    func testTheResponseFixtureCarriesTheOwnerColumnKeyAndNotTheResolvedOne() throws {
        for name in ["rest/vehicle_service_window.json", "rest/vehicle_service_window_cleared.json"] {
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: try Fixture.data(name)) as? [String: Any]
            )
            XCTAssertTrue(json.keys.contains("expectedEndAt"), "\(name): §7.16 echoes the owner column")
            XCTAssertNil(
                json["serviceEstimatedEndAt"],
                "\(name): §7.16 deliberately does NOT echo the resolved field — a fixture that does is fiction"
            )
        }
    }

    // `nil` CLEARS, and it must travel as an EXPLICIT JSON null. Swift's
    // synthesized encoder omits a nil optional, which would send `{}` — a body
    // that says "change nothing" rather than "clear it". This asserts the custom
    // encoder on `VehicleServiceWindowUpdateRequest` actually runs.
    func testNilExpectedEndAtSendsExplicitNullAndClears() async throws {
        let (client, http) = client([
            .init(status: 200, body: try Fixture.data("rest/vehicle_service_window_cleared.json"))
        ])

        let response = try await client.setServiceWindow(expectedEndAt: nil, vehicleID: "clxyz1234567890abcdef")
        XCTAssertNil(response.expectedEndAt, "a cleared owner column echoes null, not an empty string")

        let requests = await http.capturedRequests()
        let raw = String(decoding: try XCTUnwrap(requests[0].httpBody), as: UTF8.self)
        XCTAssertTrue(
            raw.contains("\"expectedEndAt\":null"),
            "the clear must be an explicit null, not an omitted key — got \(raw)"
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(requests[0].httpBody)) as? [String: Any]
        )
        XCTAssertTrue(json.keys.contains("expectedEndAt"))
        XCTAssertTrue(json["expectedEndAt"] is NSNull)
    }

    // A past instant is `400 invalid_request`. The client is expected to have
    // prevented this locally (the picker floors at "now"), so this is the
    // defensive path — it folds onto the typed `.invalidRequest` outcome, never a
    // parsed human message (FR-7.1).
    func testPastInstantSurfacesTypedInvalidRequest() async {
        let body = Data(#"{"error":{"code":"invalid_request","message":"expectedEndAt must be in the future"}}"#.utf8)
        let (client, _) = client([.init(status: 400, body: body)])
        do {
            _ = try await client.setServiceWindow(expectedEndAt: "2020-01-01T00:00:00.000Z", vehicleID: "veh")
            XCTFail("expected an error on 400")
        } catch let error as RestError {
            guard case .http(let status, let code, _, _) = error else {
                return XCTFail("expected .http, got \(error)")
            }
            XCTAssertEqual(status, 400)
            XCTAssertEqual(code?.rawValue, "invalid_request")
            XCTAssertEqual(error.commandFailureKind, .invalidRequest)
        } catch {
            XCTFail("expected RestError, got \(error)")
        }
    }

    // The rest of the catalog folds onto the typed outcomes the app switches on.
    // 404 stays deliberately indistinguishable from ownership-filtered (§7.12/§7.14).
    func testErrorCatalogFoldsOntoTypedOutcomes() async {
        let cases: [(status: Int, code: String, expected: RestError.CommandFailureKind)] = [
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
                _ = try await client.setServiceWindow(expectedEndAt: "2026-08-01T21:00:00.000Z", vehicleID: "veh")
                XCTFail("expected an error on \(c.status)")
            } catch let error as RestError {
                XCTAssertEqual(error.commandFailureKind, c.expected, "for \(c.code)")
            } catch {
                XCTFail("expected RestError for \(c.code), got \(error)")
            }
        }
    }

    // Contracts 0.17.0 — the READ half. `serviceEstimatedEndAt` decodes off BOTH
    // the snapshot and the list row, and the list fixture carries the two states
    // that matter: an in-service car with a window, and a parked car whose window
    // the server has already cleared to null.
    func testServiceEstimatedEndAtDecodesOnBothReadSurfaces() async throws {
        let (client, _) = client([
            .init(status: 200, body: try Fixture.data("rest/snapshot_in_service.json")),
            .init(status: 200, body: try Fixture.data("rest/vehicles_list_service.json")),
        ])

        let state = try await client.snapshot(vehicleId: "clxyz1234567890abcdef")
        XCTAssertEqual(state.status, .inService)
        XCTAssertEqual(state.serviceEstimatedEndAt, "2026-08-01T21:00:00.000Z")

        let items = try await client.vehicles()
        XCTAssertEqual(items[0].status, .inService)
        XCTAssertEqual(items[0].serviceEstimatedEndAt, "2026-08-01T21:00:00.000Z")
        XCTAssertNil(
            items[1].serviceEstimatedEndAt,
            "a non-service row never carries a window — the server clears it on the status change"
        )
    }

    // Tolerant decode: an ABSENT key (a pre-0.17.0 server) is nil, which means
    // exactly what an explicit null means — "no window known" — and NEVER "this
    // car has a window we couldn't read". Consumers must not gate scheduling on it.
    func testAbsentServiceEstimatedEndAtDecodesAsNil() throws {
        let json = #"{"vehicleId":"v","name":"n","model":"Model 3","year":2024,"color":"","vinLast4":"0001","status":"in_service","chargeLevel":50,"estimatedRange":100,"lastUpdated":"2026-07-28T00:00:00Z","role":"owner"}"#
        let summary = try JSONDecoder().decode(VehicleSummary.self, from: Data(json.utf8))
        XCTAssertNil(summary.serviceEstimatedEndAt)
    }

    // The parked `snapshot.json` every other test uses must keep carrying NO
    // window — the fixture pair is what makes "non-null only while in_service"
    // observable rather than asserted in prose.
    func testParkedSnapshotCarriesNoServiceWindow() async throws {
        let (client, _) = client([.init(status: 200, body: try Fixture.data("rest/snapshot.json"))])
        let state = try await client.snapshot(vehicleId: "clxyz1234567890abcdef")
        XCTAssertNotEqual(state.status, .inService)
        XCTAssertNil(state.serviceEstimatedEndAt)
    }
}
