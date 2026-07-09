import XCTest
@testable import MyRoboTaxiKit
import MyRobotaxiContracts

/// Exercises the REST pipeline with a deterministic in-memory transport (no
/// network): bearer-token injection, typed decode, the 401 refresh-and-retry
/// path (FR-6.2), typed error mapping, and transport guarding.
final class RestClientTests: XCTestCase {
    private let devEnvironment = BackendEnvironment(
        restBaseURL: URL(string: "https://api.myrobotaxi.com/api")!,
        webSocketURL: URL(string: "wss://api.myrobotaxi.com/api/ws")!,
        allowsInsecureLoopback: false
    )

    /// A REST-shaped error envelope body (`{ "error": { … } }`, rest-api.md §4.1),
    /// distinct from the WebSocket error frame shape.
    private func restErrorBody(_ code: String) -> Data {
        Data("{\"error\":{\"code\":\"\(code)\",\"message\":\"denied\"}}".utf8)
    }

    func testBearerTokenInjectedFromProvider() async throws {
        let http = RecordingHTTP([.init(status: 200, body: try Fixture.data("rest/vehicles_list.json"))])
        let tokens = CountingTokenProvider(["session-token-abc"])
        let client = RestClient(environment: devEnvironment, tokenProvider: tokens, http: http)

        let vehicles = try await client.vehicles()

        XCTAssertEqual(vehicles.count, 2)
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer session-token-abc")
        XCTAssertEqual(requests[0].url?.absoluteString, "https://api.myrobotaxi.com/api/vehicles")
    }

    func testSnapshotDecodesAndTargetsCorrectPath() async throws {
        let http = RecordingHTTP([.init(status: 200, body: try Fixture.data("rest/snapshot.json"))])
        let client = RestClient(environment: devEnvironment, tokenProvider: StaticTokenProvider("t"), http: http)

        let state = try await client.snapshot(vehicleId: "clxyz1234567890abcdef")

        XCTAssertEqual(state.chargeLevel, 78)
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests[0].url?.path, "/api/vehicles/clxyz1234567890abcdef/snapshot")
    }

    /// 401 → refresh token via provider → retry exactly once → success (FR-6.2).
    func testUnauthorizedRefreshesTokenAndRetriesOnce() async throws {
        let http = RecordingHTTP([
            .init(status: 401, body: restErrorBody("auth_failed")),
            .init(status: 200, body: try Fixture.data("rest/vehicles_list.json")),
        ])
        let tokens = CountingTokenProvider(["stale-token", "fresh-token"])
        let client = RestClient(environment: devEnvironment, tokenProvider: tokens, http: http)

        let vehicles = try await client.vehicles()

        XCTAssertEqual(vehicles.count, 2)
        let tokenCalls = await tokens.callCount()
        XCTAssertEqual(tokenCalls, 2, "provider must be asked again for a fresh token")
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer stale-token")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer fresh-token")
    }

    /// A second 401 is terminal: surface a typed `auth_failed`, retry no further.
    func testSecondUnauthorizedSurfacesTypedAuthFailed() async throws {
        let http = RecordingHTTP([
            .init(status: 401, body: restErrorBody("auth_failed")),
            .init(status: 401, body: restErrorBody("auth_failed")),
        ])
        let tokens = CountingTokenProvider(["t1", "t2"])
        let client = RestClient(environment: devEnvironment, tokenProvider: tokens, http: http)

        do {
            _ = try await client.vehicles()
            XCTFail("expected RestError.http")
        } catch let error as RestError {
            XCTAssertTrue(error.isAuthFailure)
            XCTAssertEqual(error.httpStatus, 401)
            if case .http(_, let code, _, _) = error { XCTAssertEqual(code, .authFailed) }
        }
        let tokenCalls = await tokens.callCount()
        XCTAssertEqual(tokenCalls, 2, "exactly one refresh, then stop")
        let requestCount = await http.capturedRequests().count
        XCTAssertEqual(requestCount, 2)
    }

    func testNotFoundMapsToTypedCode() async throws {
        let http = RecordingHTTP([.init(status: 404, body: try Fixture.data("rest/error.not_found.json"))])
        let client = RestClient(environment: devEnvironment, tokenProvider: StaticTokenProvider("t"), http: http)

        do {
            _ = try await client.snapshot(vehicleId: "missing")
            XCTFail("expected RestError.http 404")
        } catch let error as RestError {
            guard case .http(let status, let code, _, _) = error else { return XCTFail("wrong case") }
            XCTAssertEqual(status, 404)
            XCTAssertEqual(code, .notFound)
        }
    }

    func testInsecureTransportRejectedBeforeAnyRequest() async throws {
        let insecure = BackendEnvironment(
            restBaseURL: URL(string: "http://api.myrobotaxi.com/api")!, // plaintext, non-loopback
            webSocketURL: URL(string: "ws://api.myrobotaxi.com/api/ws")!,
            allowsInsecureLoopback: false
        )
        let http = RecordingHTTP([])
        let client = RestClient(environment: insecure, tokenProvider: StaticTokenProvider("t"), http: http)

        do {
            _ = try await client.vehicles()
            XCTFail("expected insecureTransport")
        } catch let error as RestError {
            guard case .insecureTransport = error else { return XCTFail("wrong case: \(error)") }
        }
        let requestCount = await http.capturedRequests().count
        XCTAssertEqual(requestCount, 0, "must not hit the network")
    }
}
