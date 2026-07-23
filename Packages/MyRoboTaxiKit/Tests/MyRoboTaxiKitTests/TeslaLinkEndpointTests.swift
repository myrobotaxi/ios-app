import XCTest
@testable import MyRoboTaxiKit

/// REST-surface tests for the in-app Tesla link start endpoint (rest-api.md
/// §7.11.1 — MYR-246): authenticated POST path assembly, no request body, and the
/// `{ authorizeUrl, state }` decode. No network — the deterministic `RecordingHTTP`
/// replays a canonical response.
final class TeslaLinkEndpointTests: XCTestCase {
    private let devEnvironment = BackendEnvironment(
        restBaseURL: URL(string: "https://api.myrobotaxi.com/api")!,
        webSocketURL: URL(string: "wss://api.myrobotaxi.com/api/ws")!,
        allowsInsecureLoopback: false
    )

    private func client(_ stubs: [RecordingHTTP.Stub]) -> (RestClient, RecordingHTTP) {
        let http = RecordingHTTP(stubs)
        return (RestClient(environment: devEnvironment, tokenProvider: StaticTokenProvider("tkn"), http: http), http)
    }

    func testStartTargetsAuthenticatedPostPathWithNoBodyAndDecodes() async throws {
        let json = """
        {
          "authorizeUrl": "https://auth.tesla.com/oauth2/v3/authorize?client_id=abc&state=nonce123&response_type=code",
          "state": "nonce123"
        }
        """
        let (client, http) = client([.init(status: 200, body: Data(json.utf8))])

        let response = try await client.teslaLinkStart()

        XCTAssertEqual(response.state, "nonce123")
        XCTAssertTrue(response.authorizeUrl.hasPrefix("https://auth.tesla.com/oauth2/v3/authorize"))

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[0].url?.path, "/api/tesla/link/start")
        // Owner-authenticated → carries the Bearer (not the pre-auth path).
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer tkn")
        // Contract: request body is none.
        XCTAssertNil(requests[0].httpBody)
    }

    // A 401 surfaces as a typed auth_failed (the authenticated pipeline's mapping).
    func testStartMapsUnauthorizedToTypedError() async {
        let body = Data(#"{"error":{"code":"auth_failed","message":"missing bearer"}}"#.utf8)
        // Two 401s (initial + the single post-refresh retry) both reject.
        let (client, _) = client([.init(status: 401, body: body), .init(status: 401, body: body)])
        do {
            _ = try await client.teslaLinkStart()
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
}
