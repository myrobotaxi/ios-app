import XCTest
@testable import MyRoboTaxi
import MyRoboTaxiKit

// MARK: - MYR-258 owner car offboarding (rest-api.md §7.12)
//
// The deterministic seams of the live teardown flow: the consent-revoke callback
// deep-link → outcome mapping (mirroring `TeslaLinkCallbackTests`). The
// `ASWebAuthenticationSession` itself is system UI and can't run headless, so
// `LiveTeslaRevokeSession`'s glue is exercised only up to the pure parser.

final class TeslaUnlinkCallbackTests: XCTestCase {

    // The §7.12 revoke `back_url` return → TeslaUnlinkOutcome.
    func testCallbackOutcomeMapping() {
        let cases: [(url: String, expected: TeslaUnlinkOutcome)] = [
            // A matching scheme+host is the owner returning — there is no
            // status/reason contract on Tesla's revoke page, so any match completes.
            ("myrobotaxi://tesla-unlinked", .completed),
            ("myrobotaxi://tesla-unlinked?anything=ignored", .completed),
            ("MyRoboTaxi://TESLA-UNLINKED", .completed),
            // Wrong host → unknown (never confuse it with the link callback).
            ("myrobotaxi://tesla-linked", .unknown),
            ("myrobotaxi://something-else", .unknown),
            // Wrong scheme → unknown.
            ("https://tesla-unlinked", .unknown),
        ]
        for c in cases {
            let url = URL(string: c.url)!
            XCTAssertEqual(TeslaUnlinkCallback.outcome(from: url), c.expected, "for \(c.url)")
        }
    }

    // Scheme/host constants match the registered URL scheme + the revoke back_url.
    func testCallbackConstants() {
        XCTAssertEqual(TeslaUnlinkCallback.scheme, "myrobotaxi")
        XCTAssertEqual(TeslaUnlinkCallback.host, "tesla-unlinked")
        // Shares the single registered scheme with the link callback.
        XCTAssertEqual(TeslaUnlinkCallback.scheme, TeslaLinkCallback.scheme)
    }
}
