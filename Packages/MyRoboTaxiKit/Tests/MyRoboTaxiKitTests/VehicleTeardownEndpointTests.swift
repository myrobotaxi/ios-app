import XCTest
@testable import MyRoboTaxiKit

/// REST-surface tests for the owner car-offboarding teardown endpoint (rest-api.md
/// §7.12 — MYR-258): authenticated DELETE path assembly, no request body, and the
/// full §7.12 response decode (including the optional `revokeUrl` + nested
/// `virtualKeyRemoval`). No network — the deterministic `RecordingHTTP` replays a
/// canonical response.
final class VehicleTeardownEndpointTests: XCTestCase {
    private let devEnvironment = BackendEnvironment(
        restBaseURL: URL(string: "https://api.myrobotaxi.com/api")!,
        webSocketURL: URL(string: "wss://api.myrobotaxi.com/api/ws")!,
        allowsInsecureLoopback: false
    )

    private func client(_ stubs: [RecordingHTTP.Stub]) -> (RestClient, RecordingHTTP) {
        let http = RecordingHTTP(stubs)
        return (RestClient(environment: devEnvironment, tokenProvider: StaticTokenProvider("tkn"), http: http), http)
    }

    // §7.12 — DELETE the vehicle cuid path, authenticated, no body; decode the
    // honest post-state + owner-action items exactly as the contract example.
    func testRemoveTargetsAuthenticatedDeletePathWithNoBodyAndDecodes() async throws {
        let json = """
        {
          "removed": true,
          "wasLastVehicle": true,
          "teslaTokensCleared": true,
          "streamConfigDeleted": true,
          "revokeUrl": "https://auth.tesla.com/user/revoke/consent?back_url=myrobotaxi%3A%2F%2Ftesla-unlinked&revoke_client_id=abc",
          "virtualKeyRemoval": {
            "required": true,
            "automatable": false,
            "steps": [
              "Open the Tesla app or your car's touchscreen",
              "Go to Controls \\u2192 Locks",
              "Tap the \\u201CMyRoboTaxi\\u201D key",
              "Tap Remove/Delete Key",
              "Authenticate by tapping a key card on the center console"
            ]
          }
        }
        """
        let (client, http) = client([.init(status: 200, body: Data(json.utf8))])

        let response = try await client.removeVehicle(vehicleID: "clz9veh0001")

        XCTAssertTrue(response.removed)
        XCTAssertTrue(response.wasLastVehicle)
        XCTAssertTrue(response.teslaTokensCleared)
        XCTAssertTrue(response.streamConfigDeleted)
        XCTAssertEqual(
            response.revokeUrl,
            "https://auth.tesla.com/user/revoke/consent?back_url=myrobotaxi%3A%2F%2Ftesla-unlinked&revoke_client_id=abc"
        )
        XCTAssertTrue(response.virtualKeyRemoval.required)
        XCTAssertFalse(response.virtualKeyRemoval.automatable)
        XCTAssertEqual(response.virtualKeyRemoval.steps.count, 5)
        XCTAssertEqual(response.virtualKeyRemoval.steps.first, "Open the Tesla app or your car's touchscreen")

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "DELETE")
        XCTAssertEqual(requests[0].url?.path, "/api/tesla/vehicles/clz9veh0001")
        // Owner-authenticated → carries the Bearer (not the pre-auth path).
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer tkn")
        // Contract: request body is none.
        XCTAssertNil(requests[0].httpBody)
    }

    // §7.12 — the mid-account removal: `revokeUrl` omitted (nil) and NOT the last
    // vehicle. Decodes cleanly with the optional field absent.
    func testRemoveDecodesNonLastVehicleWithoutRevokeUrl() async throws {
        let json = """
        {
          "removed": true,
          "wasLastVehicle": false,
          "teslaTokensCleared": false,
          "streamConfigDeleted": false,
          "virtualKeyRemoval": { "required": true, "automatable": false, "steps": ["Remove the key in the Tesla app"] }
        }
        """
        let (client, _) = client([.init(status: 200, body: Data(json.utf8))])

        let response = try await client.removeVehicle(vehicleID: "veh2")

        XCTAssertTrue(response.removed)
        XCTAssertFalse(response.wasLastVehicle)
        XCTAssertFalse(response.teslaTokensCleared)
        XCTAssertNil(response.revokeUrl)
        XCTAssertEqual(response.virtualKeyRemoval.steps, ["Remove the key in the Tesla app"])
    }

    // §7.12 — a 401 surfaces as a typed auth_failed (the authenticated pipeline's
    // mapping); two 401s (initial + single post-refresh retry) both reject.
    func testRemoveMapsUnauthorizedToTypedError() async {
        let body = Data(#"{"error":{"code":"auth_failed","message":"missing bearer"}}"#.utf8)
        let (client, _) = client([.init(status: 401, body: body), .init(status: 401, body: body)])
        do {
            _ = try await client.removeVehicle(vehicleID: "veh")
            XCTFail("expected an error on 401")
        } catch let error as RestError {
            if case .http(let status, _, _, _) = error {
                XCTAssertEqual(status, 401)
            } else {
                XCTFail("expected .http, got \(error)")
            }
        } catch {
            XCTFail("expected RestError, got \(error)")
        }
    }

    // §7.12 — a 403 vehicle_not_owned surfaces typed (never leaks; caller folds to
    // honest copy). No retry semantics differ, but confirm the mapping.
    func testRemoveMapsForbiddenToTypedError() async {
        let body = Data(#"{"error":{"code":"forbidden","message":"vehicle_not_owned"}}"#.utf8)
        let (client, _) = client([.init(status: 403, body: body)])
        do {
            _ = try await client.removeVehicle(vehicleID: "veh")
            XCTFail("expected an error on 403")
        } catch let error as RestError {
            if case .http(let status, _, _, _) = error {
                XCTAssertEqual(status, 403)
            } else {
                XCTFail("expected .http, got \(error)")
            }
        } catch {
            XCTFail("expected RestError, got \(error)")
        }
    }
}
