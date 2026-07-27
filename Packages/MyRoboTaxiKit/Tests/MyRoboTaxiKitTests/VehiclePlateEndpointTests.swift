import XCTest
@testable import MyRoboTaxiKit
import MyRobotaxiContracts

/// REST-surface tests for the owner license-plate entry endpoint (rest-api.md
/// §7.14 — MYR-286): authenticated PUT path assembly, the `plate` request key
/// (NOT `licensePlate` — the server strict-decodes), the NORMALIZED echo the
/// client must adopt, the empty-string clear, and the §7.14 error catalog folded
/// through the typed `RestError`. No network — the deterministic `RecordingHTTP`
/// replays canonical fixture responses.
final class VehiclePlateEndpointTests: XCTestCase {
    private let devEnvironment = BackendEnvironment(
        restBaseURL: URL(string: "https://api.myrobotaxi.com/api")!,
        webSocketURL: URL(string: "wss://api.myrobotaxi.com/api/ws")!,
        allowsInsecureLoopback: false
    )

    private func client(_ stubs: [RecordingHTTP.Stub]) -> (RestClient, RecordingHTTP) {
        let http = RecordingHTTP(stubs)
        return (RestClient(environment: devEnvironment, tokenProvider: StaticTokenProvider("tkn"), http: http), http)
    }

    // §7.14 — the authenticated PUT lands on /api/tesla/vehicles/{id}/plate with
    // the body key `plate` carrying the RAW owner input, and the response's
    // NORMALIZED `licensePlate` comes back for the caller to adopt.
    func testSetPlatePutsRawInputAndReturnsNormalizedEcho() async throws {
        let (client, http) = client([.init(status: 200, body: try Fixture.data("rest/vehicle_plate.json"))])

        // Deliberately messy input: the server trims THEN uppercases, then
        // validates the normalized value — so this is accepted, not a 400.
        let response = try await client.setLicensePlate("  abc 1234  ", vehicleID: "clxyz1234567890abcdef")

        XCTAssertEqual(response.vehicleId, "clxyz1234567890abcdef")
        XCTAssertEqual(response.licensePlate, "ABC 1234")

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "PUT")
        XCTAssertEqual(requests[0].url?.path, "/api/tesla/vehicles/clxyz1234567890abcdef/plate")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer tkn")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Content-Type"), "application/json; charset=utf-8")

        // The wire key is `plate` and the value is UNMODIFIED by the client — the
        // server owns normalization, and a client that pre-normalized would
        // silently diverge from the server's rule.
        let body = try XCTUnwrap(requests[0].httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Array(json.keys), ["plate"], "§7.14 strict-decodes the body — no extra keys")
        XCTAssertEqual(json["plate"] as? String, "  abc 1234  ")
        XCTAssertNil(json["licensePlate"], "`licensePlate` is the RESPONSE key; sending it would 400")
    }

    // §7.14 — an empty string CLEARS. It is an ordinary write (200 + empty echo),
    // never a validation failure and never a separate DELETE verb.
    func testEmptyPlateClearsAndEchoesEmptyString() async throws {
        let (client, http) = client([.init(status: 200, body: try Fixture.data("rest/vehicle_plate_cleared.json"))])

        let response = try await client.setLicensePlate("", vehicleID: "clxyz1234567890abcdef")

        XCTAssertEqual(response.licensePlate, "", "cleared is an EMPTY STRING, not nil and not a missing key")

        let requests = await http.capturedRequests()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(requests[0].httpBody)) as? [String: Any])
        XCTAssertEqual(json["plate"] as? String, "")
    }

    // §7.14 — a plate that violates the charset / 10-char cap AFTER normalization
    // is `400 invalid_request`, and the rejected P1 value is NEVER echoed back in
    // the message. It folds onto the typed `.invalidRequest` outcome the app maps
    // to its honest "that plate doesn't look right" notice.
    func testValidationFailureSurfacesTypedInvalidRequest() async {
        let body = Data(#"{"error":{"code":"invalid_request","message":"plate must be at most 10 characters from [A-Z0-9 -]"}}"#.utf8)
        let (client, _) = client([.init(status: 400, body: body)])
        do {
            _ = try await client.setLicensePlate("!!!!!!!!!!!!", vehicleID: "veh")
            XCTFail("expected an error on 400")
        } catch let error as RestError {
            guard case .http(let status, let code, let message, _) = error else {
                return XCTFail("expected .http, got \(error)")
            }
            XCTAssertEqual(status, 400)
            XCTAssertEqual(code?.rawValue, "invalid_request")
            XCTAssertEqual(error.commandFailureKind, .invalidRequest)
            XCTAssertFalse(message?.contains("!!!!!!!!!!!!") ?? false, "the rejected P1 value is never echoed")
        } catch {
            XCTFail("expected RestError, got \(error)")
        }
    }

    // §7.14 — the rest of the error catalog folds onto the typed outcomes the app
    // switches on. 404 is deliberately indistinguishable from ownership-filtered
    // (matches §7.12) — it must not read as "not owned".
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
                _ = try await client.setLicensePlate("ABC", vehicleID: "veh")
                XCTFail("expected an error on \(c.status)")
            } catch let error as RestError {
                XCTAssertEqual(error.commandFailureKind, c.expected, "for \(c.code)")
            } catch {
                XCTFail("expected RestError for \(c.code), got \(error)")
            }
        }
    }

    // Contracts v0.15.0 — the READ half. `licensePlate` decodes off BOTH the
    // §7.1 snapshot and the §7.0 list row, and the list fixture carries the two
    // states that matter: set, and the always-emitted EMPTY STRING for "not set".
    func testLicensePlateDecodesOnBothReadSurfaces() async throws {
        let (client, _) = client([
            .init(status: 200, body: try Fixture.data("rest/snapshot.json")),
            .init(status: 200, body: try Fixture.data("rest/vehicles_list.json")),
        ])

        let state = try await client.snapshot(vehicleId: "clxyz1234567890abcdef")
        XCTAssertEqual(state.licensePlate, "ABC 1234")

        let items = try await client.vehicles()
        XCTAssertEqual(items[0].licensePlate, "ABC 1234")
        XCTAssertEqual(items[1].licensePlate, "", "not-set is an EMPTY STRING, never a fabricated value")
    }

    // Tolerant decode: an ABSENT key (a pre-MYR-286 server) is nil, which means
    // exactly the same thing as the empty string — "no plate set" — and NEVER
    // "this car has a plate we could not read".
    func testAbsentLicensePlateDecodesAsNil() throws {
        let json = #"{"vehicleId":"v","name":"n","model":"Model 3","year":2024,"color":"","vinLast4":"0001","status":"parked","chargeLevel":50,"estimatedRange":100,"lastUpdated":"2026-07-27T00:00:00Z","role":"owner"}"#
        let summary = try JSONDecoder().decode(VehicleSummary.self, from: Data(json.utf8))
        XCTAssertNil(summary.licensePlate)
    }
}
