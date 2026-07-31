import MyRobotaxiContracts
import XCTest
@testable import MyRoboTaxiKit

// MARK: - POST/DELETE /api/ride-requests/{id}/activity-token (§7.21, MYR-172)
//
// Same harness every endpoint test in this package uses: a fixed environment, a
// static token provider, and `RecordingHTTP` replaying stubbed responses.
// Assertions are on path + method + the encoded body BYTES, then the decoded
// contract type.

final class RideActivityTokenEndpointTests: XCTestCase {
    private let devEnvironment = BackendEnvironment(
        restBaseURL: URL(string: "https://api.myrobotaxi.com/api")!,
        webSocketURL: URL(string: "wss://api.myrobotaxi.com/api/ws")!,
        allowsInsecureLoopback: false
    )

    private func makeClient(_ stubs: [RecordingHTTP.Stub]) -> (RestClient, RecordingHTTP) {
        let http = RecordingHTTP(stubs)
        return (RestClient(environment: devEnvironment, tokenProvider: StaticTokenProvider("t"), http: http), http)
    }

    func testRegisterPostsTheTokenToTheRideScopedPathAndDecodes200() async throws {
        let body = Data("""
        {"registered":true,"sandbox":true}
        """.utf8)
        let (client, http) = makeClient([.init(status: 200, body: body)])

        let response = try await client.registerRideActivityToken(
            rideID: "clride0000000000000001",
            token: "8a1f4c2e9b7d0356a1f4c2e9b7d0356a1f4c2e9b7d0356a1f4c2e9b7d0356a1f",
            sandbox: true
        )

        XCTAssertTrue(response.registered)
        XCTAssertTrue(response.sandbox)

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(
            requests[0].url?.path,
            "/api/ride-requests/clride0000000000000001/activity-token",
            "the endpoint is RIDE-SCOPED — one Activity per (ride, rider)"
        )
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Content-Type"), "application/json; charset=utf-8")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer t")
    }

    func testTheRegisterBodyCarriesExactlyTheTwoContractKeys() async throws {
        let (client, http) = makeClient([
            .init(status: 200, body: Data(#"{"registered":true,"sandbox":false}"#.utf8))
        ])

        _ = try await client.registerRideActivityToken(rideID: "r1", token: "deadbeef", sandbox: false)

        let requests = await http.capturedRequests()
        let sent = try XCTUnwrap(requests[0].httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: sent) as? [String: Any])

        XCTAssertEqual(
            Set(json.keys),
            ["activityToken", "sandbox"],
            "the raw wire keys, not the Swift spelling of them"
        )
        XCTAssertEqual(json["activityToken"] as? String, "deadbeef")
        XCTAssertEqual(
            json["sandbox"] as? Bool,
            false,
            """
            Sent EXPLICITLY on the production arm rather than omitted. The schema \
            defaults a missing key to production, so omitting it would make \
            "production" and "the client did not say" identical bytes — and those \
            two are worth telling apart in a server log when a lock screen is silent.
            """
        )

        // And it round-trips back into the generated request type.
        let decoded = try JSONDecoder().decode(RegisterLiveActivityRequest.self, from: sent)
        XCTAssertEqual(decoded.activityToken, "deadbeef")
        XCTAssertEqual(decoded.sandbox, false)
    }

    func testTheRegisterBodyNEVERCarriesAnythingElse() async throws {
        // The token is P1 — a capability. The body is the one place it legitimately
        // travels, and nothing else about the ride or the rider belongs beside it
        // (the ride is the path, the rider is the JWT).
        let (client, http) = makeClient([
            .init(status: 200, body: Data(#"{"registered":true,"sandbox":true}"#.utf8))
        ])

        _ = try await client.registerRideActivityToken(rideID: "r1", token: "abc123", sandbox: true)

        let requests = await http.capturedRequests()
        let sent = try XCTUnwrap(requests[0].httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: sent) as? [String: Any])
        XCTAssertEqual(json.count, 2)
    }

    func testATerminalRideAnswers409AndTheClientCanRecogniseIt() async throws {
        // "Posting against a ride that has already reached a terminal state is 409
        // conflict — that Activity will never be pushed to, and the 409 is the
        // signal to end it locally."
        let (client, _) = makeClient([
            .init(status: 409, body: Data(#"{"error":{"code":"conflict","message":"ride is terminal"}}"#.utf8))
        ])

        do {
            _ = try await client.registerRideActivityToken(rideID: "r1", token: "abc123", sandbox: true)
            XCTFail("expected a 409 to throw")
        } catch let error as RestError {
            XCTAssertEqual(error.httpStatus, 409)
            XCTAssertTrue(
                error.isTerminalRideActivityConflict,
                "this is the flag the coordinator ends the Activity on"
            )
        }
    }

    func testEndDeletesTheRideScopedPathWithNOBodyAndDecodesEnded() async throws {
        let (client, http) = makeClient([.init(status: 200, body: Data(#"{"ended":true}"#.utf8))])

        let response = try await client.endRideActivityToken(rideID: "clride0000000000000001")

        XCTAssertTrue(response.ended)

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests[0].httpMethod, "DELETE")
        XCTAssertEqual(requests[0].url?.path, "/api/ride-requests/clride0000000000000001/activity-token")
        XCTAssertNil(
            requests[0].httpBody,
            """
            Deliberately no body — the ride is the path and the rider is the JWT, so \
            re-sending the token would put a P1 capability in a request with no use \
            for it. This is the intended asymmetry with unregisterPushDevice, whose \
            DELETE does carry one because there the token is the only thing naming \
            which device to forget.
            """
        )
    }

    func testEndingAnAlreadyEndedActivityIsA200ReportingFalseRatherThanAnError() async throws {
        // "IDEMPOTENT: ending an already-ended Activity is a 200 reporting false,
        // not an error, because the client's end and the server's terminal-state
        // push race by design and both are correct."
        let (client, _) = makeClient([.init(status: 200, body: Data(#"{"ended":false}"#.utf8))])

        let response = try await client.endRideActivityToken(rideID: "r1")

        XCTAssertFalse(response.ended)
    }

    func testA401RefreshesTheTokenOnceAndRetriesTheSameBody() async throws {
        let (client, http) = makeClient([
            .init(status: 401, body: Data()),
            .init(status: 200, body: Data(#"{"registered":true,"sandbox":true}"#.utf8)),
        ])

        let response = try await client.registerRideActivityToken(rideID: "r1", token: "abc123", sandbox: true)

        XCTAssertTrue(response.registered)
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 2, "exactly one refresh-retry, inherited from the shared pipeline")
        XCTAssertEqual(requests[1].httpBody, requests[0].httpBody, "the same encoded body rides the retry")
    }

    // MARK: - Redaction

    func testTheTokenRedactionKeepsOnlyAnEightCharacterPrefix() {
        let token = "8a1f4c2e9b7d0356a1f4c2e9b7d0356a1f4c2e9b7d0356a1f4c2e9b7d0356a1f"

        XCTAssertEqual(LiveActivityTokenRedaction.redacted(token), "8a1f4c2e")
        XCTAssertEqual(LiveActivityTokenRedaction.prefixLength, 8)
        XCTAssertFalse(
            LiveActivityTokenRedaction.redacted(token).contains("9b7d"),
            "§7.21 permits an 8-character prefix and nothing more — the token is a capability"
        )
    }
}
