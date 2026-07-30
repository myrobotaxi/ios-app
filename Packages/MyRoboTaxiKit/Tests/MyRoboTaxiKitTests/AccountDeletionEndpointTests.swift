import XCTest
@testable import MyRoboTaxiKit
import MyRobotaxiContracts

/// REST-surface tests for account deletion (MYR-355): the authenticated DELETE's
/// path + verb, the ABSENCE of a request body, the discarded `204 No Content`
/// response (the regression guard — a zero-byte body must not be decoded), the
/// single 401 refresh-retry, and the error catalog folded through the typed
/// `RestError`. No network — the deterministic `RecordingHTTP` replays scripted
/// responses.
final class AccountDeletionEndpointTests: XCTestCase {
    private let devEnvironment = BackendEnvironment(
        restBaseURL: URL(string: "https://api.myrobotaxi.com/api")!,
        webSocketURL: URL(string: "wss://api.myrobotaxi.com/api/ws")!,
        allowsInsecureLoopback: false
    )

    private func client(_ stubs: [RecordingHTTP.Stub]) -> (RestClient, RecordingHTTP) {
        let http = RecordingHTTP(stubs)
        return (RestClient(environment: devEnvironment, tokenProvider: StaticTokenProvider("tkn"), http: http), http)
    }

    // MYR-355 — the authenticated DELETE lands on /api/users/me carrying the
    // Bearer and NOTHING else. The absent body is asserted explicitly: the
    // contract has no request payload at all, and a client that grew one (an
    // options object, a confirmation flag) would be inventing a wire shape.
    func testDeleteAccountSendsAnAuthenticatedDeleteToUsersMeWithNoBody() async throws {
        let (client, http) = client([.init(status: 204, body: Data())])

        try await client.deleteAccount()

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "DELETE")
        XCTAssertEqual(requests[0].url?.path, "/api/users/me")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer tkn")
        XCTAssertNil(requests[0].httpBody, "the contract has NO request body")
        XCTAssertNil(
            requests[0].value(forHTTPHeaderField: "Content-Type"),
            "no body means no Content-Type — the header is attached only when a body is"
        )
    }

    // MYR-355 — THE REGRESSION GUARD. The contract's success is `204 No Content`,
    // i.e. a genuinely ZERO-BYTE body. Routing this through the decoding `perform`
    // would raise `RestError.decoding` on exactly the response the server is
    // documented to send, and no fixture or screenshot could ever catch it —
    // which is why `deleteAccount` runs `performDiscardingBody`.
    func testA204WithAnEmptyBodyIsPlainSuccess() async throws {
        let (client, _) = client([.init(status: 204, body: Data())])
        try await client.deleteAccount()
    }

    // MYR-355 — a 200 carrying an unexpected but well-formed body is ALSO success.
    // The client asserts nothing about the response shape, so a server that later
    // starts echoing a record does not break a shipped build.
    func testAnUnexpectedSuccessBodyIsStillSuccess() async throws {
        let (client, _) = client([.init(status: 200, body: Data(#"{"deleted":true}"#.utf8))])
        try await client.deleteAccount()
    }

    // MYR-355 — a `500 internal_error` surfaces as `RestError.http(status: 500, …)`
    // with the typed code off the standard envelope, never a string match on the
    // human message (FR-7.1). This is the error the flow renders its retry notice
    // from, and the retry is safe because the endpoint is re-runnable.
    func testAnInternalErrorSurfacesAsATypedHttpFailure() async {
        let body = Data(#"{"error":{"code":"internal_error","message":"boom"}}"#.utf8)
        let (client, http) = client([.init(status: 500, body: body)])

        do {
            try await client.deleteAccount()
            XCTFail("expected an error on 500")
        } catch let error as RestError {
            guard case .http(let status, let code, let message, let subCode) = error else {
                return XCTFail("expected .http, got \(error)")
            }
            XCTAssertEqual(status, 500)
            XCTAssertEqual(code?.rawValue, "internal_error")
            XCTAssertEqual(message, "boom")
            XCTAssertNil(subCode, "MYR-355 ships NO reauth sub-code gate")
            XCTAssertEqual(error.httpStatus, 500)
        } catch {
            XCTFail("expected RestError, got \(error)")
        }

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 1, "a 500 is not retried by the transport — the USER retries")
    }

    // MYR-355 — the rest of the contract's error catalog folds onto typed
    // outcomes. `429 rate_limited` matters here in particular: a user tapping
    // "Delete permanently" twice must see a typed refusal, never a fake success.
    func testTheErrorCatalogFoldsOntoTypedOutcomes() async {
        let cases: [(status: Int, code: String)] = [
            (401, "auth_failed"),
            (429, "rate_limited"),
            (500, "internal_error"),
        ]
        for c in cases {
            let body = Data(#"{"error":{"code":"\#(c.code)","message":"nope"}}"#.utf8)
            // 401 retries once after the refresh hook, so stub it twice.
            let stubs = Array(repeating: RecordingHTTP.Stub(status: c.status, body: body), count: 2)
            let (client, _) = client(stubs)
            do {
                try await client.deleteAccount()
                XCTFail("expected an error on \(c.status)")
            } catch let error as RestError {
                XCTAssertEqual(error.httpStatus, c.status, "for \(c.code)")
            } catch {
                XCTFail("expected RestError for \(c.code), got \(error)")
            }
        }
    }

    // FR-6.2 — the shared pipeline's single 401 refresh-retry applies here too:
    // the provider is told its token was rejected, the request is retried exactly
    // once, and a second 401 surfaces as a typed auth failure.
    func testDeleteAccountRetriesOnceAfterUnauthorized() async {
        let body = Data(#"{"error":{"code":"auth_failed","message":"nope"}}"#.utf8)
        let (client, http) = client(Array(repeating: RecordingHTTP.Stub(status: 401, body: body), count: 2))

        do {
            try await client.deleteAccount()
            XCTFail("expected an error on a repeated 401")
        } catch let error as RestError {
            XCTAssertTrue(error.isAuthFailure, "a second 401 surfaces as a typed auth failure")
        } catch {
            XCTFail("expected RestError, got \(error)")
        }

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 2, "exactly one retry — never a refresh loop")
        XCTAssertNil(requests[1].httpBody, "the retry is the same bodyless DELETE")
    }

    // MYR-355 — the endpoint is RE-RUNNABLE by contract: a partial failure leaves
    // a state where calling it again finishes the job. Nothing in the client
    // latches after a failure, so a second call goes out exactly like the first.
    func testAFailedDeleteCanBeRerunAndSucceed() async throws {
        let http = RecordingHTTP([
            .init(status: 500, body: Data(#"{"error":{"code":"internal_error","message":"boom"}}"#.utf8)),
            .init(status: 204, body: Data()),
        ])
        let client = RestClient(
            environment: devEnvironment,
            tokenProvider: StaticTokenProvider("tkn"),
            http: http
        )

        do {
            try await client.deleteAccount()
            XCTFail("expected the first call to fail")
        } catch {}

        try await client.deleteAccount()

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map(\.httpMethod), ["DELETE", "DELETE"])
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/users/me", "/api/users/me"])
    }
}
