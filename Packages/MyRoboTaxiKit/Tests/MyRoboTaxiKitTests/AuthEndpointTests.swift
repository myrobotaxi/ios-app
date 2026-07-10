import XCTest
@testable import MyRoboTaxiKit
import MyRobotaxiContracts

/// Fixture round-trips for the identity-module REST surface (rest-api.md §7.10
/// — MYR-193 apple / refresh / revoke): request-path + method + body assembly,
/// the PRE-AUTH property (no `Authorization` header, no 401 refresh-retry), the
/// token-pair decode, the `204` no-content revoke, and typed error mapping. No
/// network — the deterministic `RecordingHTTP` replays the auth fixtures.
final class AuthEndpointTests: XCTestCase {
    private let devEnvironment = BackendEnvironment(
        restBaseURL: URL(string: "https://api.myrobotaxi.com/api")!,
        webSocketURL: URL(string: "wss://api.myrobotaxi.com/api/ws")!,
        allowsInsecureLoopback: false
    )

    private func client(_ stubs: [RecordingHTTP.Stub]) -> (RestClient, RecordingHTTP) {
        let http = RecordingHTTP(stubs)
        // A non-empty static provider proves auth requests do NOT carry a Bearer
        // header even when a token is available (they are pre-auth).
        return (RestClient(environment: devEnvironment, tokenProvider: StaticTokenProvider("unused"), http: http), http)
    }

    // MARK: - POST /api/auth/apple

    func testAppleSignInPostsBodyToAuthAppleAndDecodesPair() async throws {
        let (client, http) = client([.init(status: 200, body: try Fixture.data("rest/auth_token.json"))])

        let response = try await client.signInWithApple(
            AppleSignInRequest(identityToken: "apple.jwt.token", fullName: "Ada Lovelace", email: "ada@example.com", nonce: "hashed-nonce")
        )

        XCTAssertEqual(response.accessToken.hasPrefix("eyJ"), true)
        XCTAssertEqual(response.expiresIn, 3600)
        XCTAssertEqual(response.refreshToken, "rt_opaque_first_00000000000000000000000000000001")
        XCTAssertEqual(response.user.id, "cmmgr4b1p0005l104ifpctlg8")
        XCTAssertEqual(response.user.name, "Ada Lovelace")

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[0].url?.path, "/api/auth/apple")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Content-Type"), "application/json; charset=utf-8")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"), "auth/apple is pre-auth — no Bearer header")

        // The forwarded body round-trips back into the request shape.
        let sent = try JSONDecoder().decode(AppleSignInRequest.self, from: try XCTUnwrap(requests[0].httpBody))
        XCTAssertEqual(sent.identityToken, "apple.jwt.token")
        XCTAssertEqual(sent.fullName, "Ada Lovelace")
        XCTAssertEqual(sent.nonce, "hashed-nonce")
    }

    func testAppleSignInMapsInvalidRequestToTypedCode() async throws {
        let (client, _) = client([.init(status: 400, body: try Fixture.data("rest/error.invalid_request.json"))])

        do {
            _ = try await client.signInWithApple(AppleSignInRequest(identityToken: ""))
            XCTFail("expected 400 invalid_request")
        } catch let error as RestError {
            guard case .http(let status, let code, _, _) = error else { return XCTFail("wrong case") }
            XCTAssertEqual(status, 400)
            XCTAssertEqual(code, .invalidRequest)
        }
    }

    func testAppleSignInMapsAuthFailedToTypedCode() async throws {
        let (client, _) = client([.init(status: 401, body: try Fixture.data("rest/error.auth_failed.json"))])

        do {
            _ = try await client.signInWithApple(AppleSignInRequest(identityToken: "bad"))
            XCTFail("expected 401 auth_failed")
        } catch let error as RestError {
            XCTAssertTrue(error.isAuthFailure)
            XCTAssertEqual(error.httpStatus, 401)
        }
    }

    // MARK: - POST /api/auth/refresh

    func testRefreshPostsRefreshTokenAndDecodesRotatedPair() async throws {
        let (client, http) = client([.init(status: 200, body: try Fixture.data("rest/auth_token_refreshed.json"))])

        let response = try await client.refreshSession(RefreshTokenRequest(refreshToken: "rt_old"))

        XCTAssertEqual(response.refreshToken, "rt_opaque_rotated_0000000000000000000000000000002", "rotation: a new refresh token")
        XCTAssertTrue(response.accessToken.hasSuffix("rotated"))
        XCTAssertNil(response.user.name, "refresh user carries at least id; name omitted here")

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[0].url?.path, "/api/auth/refresh")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"), "refresh is pre-auth — no Bearer header")
        let sent = try JSONDecoder().decode(RefreshTokenRequest.self, from: try XCTUnwrap(requests[0].httpBody))
        XCTAssertEqual(sent.refreshToken, "rt_old")
    }

    /// Reuse of a spent/revoked refresh token → 401 (family revoked). It must NOT
    /// trigger the Bearer 401 refresh-retry (that path is for authenticated GETs,
    /// not the pre-auth refresh endpoint): exactly one request goes out.
    func testRefreshReuseMapsToAuthFailedWithoutRetry() async throws {
        let (client, http) = client([.init(status: 401, body: try Fixture.data("rest/error.auth_failed.json"))])

        do {
            _ = try await client.refreshSession(RefreshTokenRequest(refreshToken: "rt_spent"))
            XCTFail("expected 401 auth_failed")
        } catch let error as RestError {
            XCTAssertTrue(error.isAuthFailure)
        }
        let requestCount = await http.capturedRequests().count
        XCTAssertEqual(requestCount, 1, "pre-auth refresh must not run the Bearer 401 refresh-retry loop")
    }

    // MARK: - POST /api/auth/revoke (204)

    func testRevokePostsRefreshTokenAndTolerates204() async throws {
        let (client, http) = client([.init(status: 204, body: Data())])

        try await client.revokeSession(RefreshTokenRequest(refreshToken: "rt_current"))

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[0].url?.path, "/api/auth/revoke")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"), "revoke is pre-auth — no Bearer header")
        let sent = try JSONDecoder().decode(RefreshTokenRequest.self, from: try XCTUnwrap(requests[0].httpBody))
        XCTAssertEqual(sent.refreshToken, "rt_current")
    }
}
