@testable import MyRoboTaxi
import XCTest

// MARK: - MYR-204 deliverable 4 — Battery display guard (MYR-207)
//
// A live drive can arrive with startChargeLevel = 0, producing "0% → 75% /
// -75% used". The guard renders the start & "used" figures as "—" when the
// start reading is untrustworthy (≤ 0, or below end), keeping only the real
// end reading. Sim readings (start ≥ 76, end < start) stay untouched.
final class BatteryReadoutTests: XCTestCase {

    func testTrustworthyReadingRendersRealFigures() {
        let r = BatteryReadout(usedPercent: 18, startPercent: 80, endPercent: 62)
        XCTAssertTrue(r.isStartKnown)
        XCTAssertEqual(r.startText, "80")
        XCTAssertEqual(r.endText, "62")
        XCTAssertEqual(r.usedText, "18% used")
        XCTAssertEqual(r.startFraction, 0.80, accuracy: 1e-9)
        XCTAssertEqual(r.endFraction, 0.62, accuracy: 1e-9)
    }

    func testZeroStartIsGuardedToDash() {
        // The MYR-207 bug: start 0, end 75, delta 75 → used -75.
        let r = BatteryReadout(usedPercent: -75, startPercent: 0, endPercent: 75)
        XCTAssertFalse(r.isStartKnown)
        XCTAssertEqual(r.startText, "—")
        XCTAssertEqual(r.usedText, "— used")
        XCTAssertEqual(r.endText, "75", "the end reading is real and stays")
        XCTAssertEqual(r.startFraction, 0, "no start fill / START marker for a bogus start")
        XCTAssertEqual(r.endFraction, 0.75, accuracy: 1e-9)
    }

    func testNegativeStartIsGuarded() {
        let r = BatteryReadout(usedPercent: -80, startPercent: -5, endPercent: 75)
        XCTAssertFalse(r.isStartKnown)
        XCTAssertEqual(r.startText, "—")
        XCTAssertEqual(r.usedText, "— used")
    }

    func testStartBelowEndIsGuarded() {
        // Charging / garbage: start < end can't be a battery "used" over a drive.
        let r = BatteryReadout(usedPercent: 15, startPercent: 40, endPercent: 55)
        XCTAssertFalse(r.isStartKnown)
        XCTAssertEqual(r.startText, "—")
        XCTAssertEqual(r.usedText, "— used")
        XCTAssertEqual(r.endText, "55")
    }

    func testEqualStartAndEndIsTrustworthy() {
        let r = BatteryReadout(usedPercent: 0, startPercent: 70, endPercent: 70)
        XCTAssertTrue(r.isStartKnown)
        XCTAssertEqual(r.startText, "70")
        XCTAssertEqual(r.usedText, "0% used")
    }

    func testTypicalSimReadingUnaffected() {
        // A seeded sim drive: start 82, delta -6 → end 76, used 6.
        let r = BatteryReadout(usedPercent: 6, startPercent: 82, endPercent: 76)
        XCTAssertTrue(r.isStartKnown)
        XCTAssertEqual(r.startText, "82")
        XCTAssertEqual(r.endText, "76")
        XCTAssertEqual(r.usedText, "6% used")
    }
}
