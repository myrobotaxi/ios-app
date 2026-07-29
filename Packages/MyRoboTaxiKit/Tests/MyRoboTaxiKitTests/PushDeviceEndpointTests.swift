import XCTest
@testable import MyRoboTaxiKit
import MyRobotaxiContracts

/// REST-surface tests for APNs device-token registration (MYR-186): authenticated
/// PUT/DELETE path assembly, the two-key body BOTH verbs carry, the discarded
/// response (an "empty-ish" 200 must not be decoded), the single 401 refresh-retry,
/// and the error catalog folded through the typed `RestError`. No network — the
/// deterministic `RecordingHTTP` replays scripted responses.
final class PushDeviceEndpointTests: XCTestCase {
    private let devEnvironment = BackendEnvironment(
        restBaseURL: URL(string: "https://api.myrobotaxi.com/api")!,
        webSocketURL: URL(string: "wss://api.myrobotaxi.com/api/ws")!,
        allowsInsecureLoopback: false
    )

    private func client(_ stubs: [RecordingHTTP.Stub]) -> (RestClient, RecordingHTTP) {
        let http = RecordingHTTP(stubs)
        return (RestClient(environment: devEnvironment, tokenProvider: StaticTokenProvider("tkn"), http: http), http)
    }

    /// A representative 64-hex APNs token (32 raw bytes).
    private let hexToken = "0011223344556677" + "8899aabbccddeeff" + "0011223344556677" + "8899aabbccddeeff"

    // MYR-186 — the authenticated PUT lands on /api/push/devices carrying BOTH
    // contract keys, with the token verbatim (the client never re-cases or trims
    // it) and `sandbox` as a real JSON boolean, not a string.
    func testRegisterPutsTokenAndSandboxFlag() async throws {
        let (client, http) = client([.init(status: 200, body: Data("{}".utf8))])

        try await client.registerPushDevice(token: hexToken, sandbox: true)

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "PUT")
        XCTAssertEqual(requests[0].url?.path, "/api/push/devices")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer tkn")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Content-Type"), "application/json; charset=utf-8")

        let body = try XCTUnwrap(requests[0].httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["deviceToken", "sandbox"], "the contract body is exactly these two keys")
        XCTAssertEqual(json["deviceToken"] as? String, hexToken, "the token is sent verbatim")
        XCTAssertEqual(json["sandbox"] as? Bool, true, "`sandbox` is a JSON boolean, not a string")
    }

    // MYR-186 — a production (TestFlight / App Store) build sends `sandbox:false`.
    // A token is only valid against the APNs environment that minted it and the
    // token itself does not say which, so this flag is the whole routing decision.
    func testRegisterSendsFalseSandboxForProductionBuilds() async throws {
        let (client, http) = client([.init(status: 200, body: Data())])

        try await client.registerPushDevice(token: hexToken, sandbox: false)

        let requests = await http.capturedRequests()
        let raw = String(decoding: try XCTUnwrap(requests[0].httpBody), as: UTF8.self)
        XCTAssertTrue(raw.contains("\"sandbox\":false"), "production builds send an explicit false, never an omitted key")
    }

    // MYR-186 — the DELETE (sign-out) carries the SAME body as the register call.
    // A body on DELETE is unusual, so this pins it: dropping the body would leave
    // the server unable to identify which device to forget.
    func testUnregisterDeletesWithTheSameBody() async throws {
        let (client, http) = client([.init(status: 200, body: Data("{}".utf8))])

        try await client.unregisterPushDevice(token: hexToken, sandbox: true)

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "DELETE")
        XCTAssertEqual(requests[0].url?.path, "/api/push/devices")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer tkn")

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(requests[0].httpBody)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["deviceToken", "sandbox"], "DELETE carries the identical body")
        XCTAssertEqual(json["deviceToken"] as? String, hexToken)
    }

    // MYR-186 — the contract's success is "200 with an empty-ish body". A
    // ZERO-BYTE 200 must be plain success: routing these through the decoding
    // `perform` would raise `RestError.decoding` on exactly the response the
    // server is documented to send.
    func testEmptyBodySucceedsOnBothVerbs() async throws {
        let (register, _) = client([.init(status: 200, body: Data())])
        try await register.registerPushDevice(token: hexToken, sandbox: true)

        let (unregister, _) = client([.init(status: 200, body: Data())])
        try await unregister.unregisterPushDevice(token: hexToken, sandbox: true)
    }

    // MYR-186 — an unexpected but well-formed JSON body is ALSO success. The
    // client asserts nothing about the response shape, so a server that later
    // starts echoing a record does not break a shipped build.
    func testUnexpectedResponseBodyIsStillSuccess() async throws {
        let (client, _) = client([.init(status: 200, body: Data(#"{"deviceId":"dev_1","registered":true}"#.utf8))])
        try await client.registerPushDevice(token: hexToken, sandbox: true)
    }

    // FR-6.2 — the shared pipeline's single 401 refresh-retry applies here too:
    // the token provider is told its token was rejected, the request is retried
    // exactly once, and a second 401 surfaces typed.
    func testRegisterRetriesOnceAfterUnauthorized() async {
        let body = Data(#"{"error":{"code":"auth_failed","message":"nope"}}"#.utf8)
        let (client, http) = client(Array(repeating: RecordingHTTP.Stub(status: 401, body: body), count: 2))

        do {
            try await client.registerPushDevice(token: hexToken, sandbox: true)
            XCTFail("expected an error on a repeated 401")
        } catch let error as RestError {
            XCTAssertTrue(error.isAuthFailure, "a second 401 surfaces as a typed auth failure")
        } catch {
            XCTFail("expected RestError, got \(error)")
        }

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 2, "exactly one retry — never a refresh loop")
        XCTAssertEqual(requests[0].httpBody, requests[1].httpBody, "the retry re-sends the identical body")
    }

    // MYR-186 — the error catalog folds onto the typed outcomes. The caller's
    // policy is "retry next foreground" for every one of these; none of them may
    // block UI, which is why they are surfaced as ordinary typed throws.
    func testErrorCatalogFoldsOntoTypedOutcomes() async {
        let cases: [(status: Int, code: String, expected: RestError.CommandFailureKind)] = [
            (400, "invalid_request", .invalidRequest),
            (401, "auth_failed", .auth),
            (404, "not_found", .notFound),
            (500, "internal_error", .other),
        ]
        for c in cases {
            let body = Data(#"{"error":{"code":"\#(c.code)","message":"nope"}}"#.utf8)
            // 401 retries once after the refresh hook, so stub it twice.
            let stubs = Array(repeating: RecordingHTTP.Stub(status: c.status, body: body), count: 2)
            let (client, _) = client(stubs)
            do {
                try await client.registerPushDevice(token: hexToken, sandbox: true)
                XCTFail("expected an error on \(c.status)")
            } catch let error as RestError {
                XCTAssertEqual(error.commandFailureKind, c.expected, "for \(c.code)")
            } catch {
                XCTFail("expected RestError for \(c.code), got \(error)")
            }
        }
    }

    // MYR-186 — an unregister failure is typed the same way. Sign-out is
    // best-effort: the caller swallows this, but it must still be a typed throw
    // rather than a silent success, so the caller can decide.
    func testUnregisterSurfacesTypedFailure() async {
        let body = Data(#"{"error":{"code":"not_found","message":"unknown device"}}"#.utf8)
        let (client, _) = client([.init(status: 404, body: body)])
        do {
            try await client.unregisterPushDevice(token: hexToken, sandbox: false)
            XCTFail("expected an error on 404")
        } catch let error as RestError {
            XCTAssertEqual(error.httpStatus, 404)
        } catch {
            XCTFail("expected RestError, got \(error)")
        }
    }

    // The registration DTO round-trips through the wire keys the contract names.
    func testRegistrationPayloadRoundTrips() throws {
        let payload = PushDeviceRegistration(deviceToken: hexToken, sandbox: true)
        let data = try JSONEncoder().encode(payload)
        XCTAssertEqual(try JSONDecoder().decode(PushDeviceRegistration.self, from: data), payload)
    }
}
