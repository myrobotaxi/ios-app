import XCTest
@testable import MyRoboTaxi
import MyRoboTaxiKit

// MARK: - MYR-246 in-app Tesla link (rest-api.md §7.11)
//
// The deterministic seams of the live link: the callback deep-link → outcome
// mapping (every §7.11 status/reason), the reason→failure mapping, and the
// `/start` plumbing with a fake `TeslaLinkEndpoint`. The `ASWebAuthenticationSession`
// itself is system UI and can't run headless, so `LiveTeslaAuthenticator`'s glue
// is exercised only up to the point these pure pieces cover.

final class TeslaLinkCallbackTests: XCTestCase {

    // §7.11.2 status/reason table → TeslaAuthOutcome.
    func testCallbackOutcomeMapping() {
        let cases: [(url: String, expected: TeslaAuthOutcome)] = [
            ("myrobotaxi://tesla-linked?status=success", .granted),
            ("myrobotaxi://tesla-linked?status=error&reason=tesla_denied", .failed(.teslaDenied)),
            ("myrobotaxi://tesla-linked?status=error&reason=invalid_state", .failed(.sessionExpired)),
            ("myrobotaxi://tesla-linked?status=error&reason=session_expired", .failed(.sessionExpired)),
            ("myrobotaxi://tesla-linked?status=error&reason=missing_code", .failed(.missingCode)),
            ("myrobotaxi://tesla-linked?status=error&reason=exchange_failed", .failed(.exchangeFailed)),
            ("myrobotaxi://tesla-linked?status=error&reason=account_not_provisioned", .failed(.accountNotProvisioned)),
            ("myrobotaxi://tesla-linked?status=error&reason=persist_failed", .failed(.persistFailed)),
            // Error with an unrecognised reason → unknown (forward-compatible).
            ("myrobotaxi://tesla-linked?status=error&reason=brand_new_reason", .failed(.unknown)),
            // Error with NO reason → unknown.
            ("myrobotaxi://tesla-linked?status=error", .failed(.unknown)),
            // Missing status → unknown.
            ("myrobotaxi://tesla-linked", .failed(.unknown)),
            // Wrong host → unknown (never treat a stray redirect as success).
            ("myrobotaxi://something-else?status=success", .failed(.unknown)),
            // Wrong scheme → unknown.
            ("https://tesla-linked?status=success", .failed(.unknown)),
        ]
        for c in cases {
            let url = URL(string: c.url)!
            XCTAssertEqual(TeslaLinkCallback.outcome(from: url), c.expected, "for \(c.url)")
        }
    }

    // Scheme/host constants match the registered URL scheme + backend redirect.
    func testCallbackConstants() {
        XCTAssertEqual(TeslaLinkCallback.scheme, "myrobotaxi")
        XCTAssertEqual(TeslaLinkCallback.host, "tesla-linked")
    }

    // Direct reason→failure mapping (used by the callback + any future caller).
    func testFailureReasonMapping() {
        XCTAssertEqual(TeslaLinkFailure(reason: "tesla_denied"), .teslaDenied)
        XCTAssertEqual(TeslaLinkFailure(reason: "invalid_state"), .sessionExpired)
        XCTAssertEqual(TeslaLinkFailure(reason: "session_expired"), .sessionExpired)
        XCTAssertEqual(TeslaLinkFailure(reason: "missing_code"), .missingCode)
        XCTAssertEqual(TeslaLinkFailure(reason: "exchange_failed"), .exchangeFailed)
        XCTAssertEqual(TeslaLinkFailure(reason: "account_not_provisioned"), .accountNotProvisioned)
        XCTAssertEqual(TeslaLinkFailure(reason: "persist_failed"), .persistFailed)
        XCTAssertEqual(TeslaLinkFailure(reason: nil), .unknown)
        XCTAssertEqual(TeslaLinkFailure(reason: "???"), .unknown)
    }

    // Every failure carries honest, non-empty user copy + a retry affordance.
    func testEveryFailureHasCopy() {
        let all: [TeslaLinkFailure] = [
            .teslaDenied, .sessionExpired, .missingCode, .exchangeFailed,
            .accountNotProvisioned, .persistFailed, .startFailed, .unknown,
        ]
        for f in all {
            XCTAssertFalse(f.title.isEmpty, "\(f) title")
            XCTAssertFalse(f.message.isEmpty, "\(f) message")
        }
    }

    // The virtual-key pairing handoff URL is the documented tesla.com/_ak endpoint.
    func testVirtualKeyPairingURL() {
        XCTAssertEqual(TeslaVirtualKey.pairingURL.absoluteString, "https://tesla.com/_ak/myrobotaxi.app")
    }
}

// MARK: - /start plumbing

private enum FakeError: Error { case boom }

/// Fake `TeslaLinkEndpoint`: replays a canned response, or throws.
private struct FakeTeslaLinkClient: TeslaLinkEndpoint {
    let response: TeslaLinkStartResponse?
    func teslaLinkStart() async throws -> TeslaLinkStartResponse {
        guard let response else { throw FakeError.boom }
        return response
    }
}

final class TeslaLinkStarterTests: XCTestCase {

    func testReturnsAuthorizeURLFromValidResponse() async throws {
        let client = FakeTeslaLinkClient(
            response: TeslaLinkStartResponse(
                authorizeUrl: "https://auth.tesla.com/oauth2/v3/authorize?client_id=abc&state=xyz",
                state: "xyz"
            )
        )
        let url = try await TeslaLinkStarter(client: client).authorizeURL()
        XCTAssertEqual(url.host, "auth.tesla.com")
        XCTAssertEqual(url.scheme, "https")
    }

    func testRejectsNonHTTPSAuthorizeURL() async {
        let cases = [
            "http://auth.tesla.com/oauth2/v3/authorize",  // not https
            "not a url at all ~~~",                        // unparseable
            "myrobotaxi://tesla-linked",                   // custom scheme, not https
            "",                                            // empty
        ]
        for value in cases {
            let client = FakeTeslaLinkClient(response: TeslaLinkStartResponse(authorizeUrl: value, state: "s"))
            do {
                _ = try await TeslaLinkStarter(client: client).authorizeURL()
                XCTFail("expected throw for \(value)")
            } catch {
                XCTAssertEqual(error as? TeslaLinkStartError, .invalidAuthorizeURL, "for \(value)")
            }
        }
    }

    func testPropagatesClientError() async {
        let client = FakeTeslaLinkClient(response: nil) // throws FakeError.boom
        do {
            _ = try await TeslaLinkStarter(client: client).authorizeURL()
            XCTFail("expected the client error to propagate")
        } catch {
            XCTAssertTrue(error is FakeError)
        }
    }
}
