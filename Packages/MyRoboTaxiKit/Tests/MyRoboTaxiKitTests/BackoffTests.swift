import XCTest
@testable import MyRoboTaxiKit

/// Verifies the reconnect backoff curve (Rule CG-SM-7 / §7.1): initial 1s, 2×,
/// 30s cap, ±25% jitter.
final class BackoffTests: XCTestCase {
    func testStandardParameters() {
        let backoff = ExponentialBackoff.standard
        XCTAssertEqual(backoff.initialDelay, 1)
        XCTAssertEqual(backoff.multiplier, 2)
        XCTAssertEqual(backoff.maxDelay, 30)
        XCTAssertEqual(backoff.jitterFraction, 0.25)
    }

    func testBaseDelayDoublesAndCaps() {
        let backoff = ExponentialBackoff.standard
        XCTAssertEqual(backoff.baseDelay(attempt: 1), 1)
        XCTAssertEqual(backoff.baseDelay(attempt: 2), 2)
        XCTAssertEqual(backoff.baseDelay(attempt: 3), 4)
        XCTAssertEqual(backoff.baseDelay(attempt: 4), 8)
        XCTAssertEqual(backoff.baseDelay(attempt: 5), 16)
        XCTAssertEqual(backoff.baseDelay(attempt: 6), 30) // 32 → capped
        XCTAssertEqual(backoff.baseDelay(attempt: 9), 30) // stays capped
    }

    func testJitterMapsLinearlyAndStaysInBounds() {
        let backoff = ExponentialBackoff.standard
        // attempt 3 → base 4s; ±25% → [3.0, 5.0)
        XCTAssertEqual(backoff.delay(attempt: 3, random: 0.0), 3.0, accuracy: 1e-9)   // -25%
        XCTAssertEqual(backoff.delay(attempt: 3, random: 0.5), 4.0, accuracy: 1e-9)   // no jitter
        XCTAssertEqual(backoff.delay(attempt: 3, random: 1.0), 5.0, accuracy: 1e-9)   // +25%

        for _ in 0..<200 {
            let unit = Double.random(in: 0..<1)
            let delay = backoff.delay(attempt: 5, random: unit) // base 16
            XCTAssertGreaterThanOrEqual(delay, 12.0)
            XCTAssertLessThan(delay, 20.0)
        }
    }

    func testDelayNeverNegative() {
        let backoff = ExponentialBackoff(initialDelay: 1, multiplier: 2, maxDelay: 30, jitterFraction: 2.0)
        XCTAssertGreaterThanOrEqual(backoff.delay(attempt: 1, random: 0.0), 0)
    }
}
