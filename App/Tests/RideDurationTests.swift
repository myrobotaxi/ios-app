@testable import MyRoboTaxi
import XCTest

// MARK: - MYR-395 item 2 — "If over an hour convert to hours and min"
//
// r16. The client's screenshot of a Grayslake IL → Galleria Dallas booking carries
// **"2592 min away"** and **"2623 min · 1049.2 mi trip"**. Both numbers are
// correct; neither is readable.
//
// The reason it took a client to find it is that there was no ONE place to look:
// fifteen surfaces each interpolated `"\(n) min"` into their own string, so
// "what happens past an hour" was never a question anybody had to answer. These
// pin the grammar, and `RideDurationSweepTests` (below) pins that the surfaces
// actually go through it.
final class RideDurationTests: XCTestCase {

    /// Sub-hour is BYTE-IDENTICAL to what every surface printed before this issue.
    /// That is not a nicety — it is what keeps the whole drift gate valid, since
    /// every fixture duration in the app (28, 32, 12, 3…) is under an hour.
    func testSubHourIsUnchanged() {
        XCTAssertEqual(RideDuration.text(minutes: 0), "0 min")
        XCTAssertEqual(RideDuration.text(minutes: 1), "1 min")
        XCTAssertEqual(RideDuration.text(minutes: 3), "3 min")
        XCTAssertEqual(RideDuration.text(minutes: 28), "28 min")
        XCTAssertEqual(RideDuration.text(minutes: 32), "32 min")
        XCTAssertEqual(RideDuration.text(minutes: 59), "59 min")
    }

    /// The three the issue names, plus the boundary either side of each.
    func testTheBoundaryAndTheClientsOwnNumbers() {
        XCTAssertEqual(RideDuration.text(minutes: 59), "59 min")
        XCTAssertEqual(RideDuration.text(minutes: 60), "1 hr")
        XCTAssertEqual(RideDuration.text(minutes: 61), "1 hr 1 min")
        XCTAssertEqual(RideDuration.text(minutes: 2592), "43 hr 12 min")   // his "2592 min away"
        XCTAssertEqual(RideDuration.text(minutes: 2623), "43 hr 43 min")   // his "2623 min · 1049.2 mi trip"
    }

    /// An exact hour never says "0 min". `"1 hr 0 min"` is what a naive
    /// hours/minutes split prints at every hour boundary, and it reads as a bug.
    func testAnExactHourNeverTrailsAZeroRemainder() {
        for hours in 1...48 {
            let text = RideDuration.text(minutes: hours * 60)
            XCTAssertEqual(text, "\(hours) hr")
            XCTAssertFalse(text.contains("0 min"), "\(hours * 60) → \(text)")
        }
    }

    /// **The client's own worked example of the trap**: "never '1 hr 65 min'".
    /// The remainder is a remainder — the way this regresses is somebody writing
    /// `"\(m / 60) hr \(m) min"`, which compiles, passes an eyeball at 61, and is
    /// wrong at every value above it.
    func testTheMinutesPartIsAlwaysTheRemainderAndNeverTheRawCount() {
        for minutes in 60...(60 * 50) {
            let text = RideDuration.text(minutes: minutes)
            let hours = minutes / 60
            let remainder = minutes % 60
            XCTAssertEqual(text, remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min")
            if let range = text.range(of: " min") {
                let tail = text[text.startIndex..<range.lowerBound]
                let printed = Int(tail.split(separator: " ").last!)!
                XCTAssertTrue((1...59).contains(printed), "\(minutes) → \(text)")
            }
        }
    }

    /// A negative estimate is not a duration. Clamped rather than printed, because
    /// "-3 min away" is a worse answer than "0 min away" on every surface here.
    func testANegativeEstimateIsClampedRatherThanPrinted() {
        XCTAssertEqual(RideDuration.text(minutes: -1), "0 min")
        XCTAssertEqual(RideDuration.text(minutes: -2592), "0 min")
    }

    /// The hero split is the SAME sentence cut at its final unit, so the two forms
    /// cannot disagree about whether a duration says "hr". Anything that recomputed
    /// hours here would be a second grammar wearing the first one's name.
    func testTheHeroSplitIsTheSameSentenceCutAtItsUnit() {
        for minutes in [0, 1, 28, 59, 60, 61, 90, 120, 2592, 2623] {
            let parts = RideDuration.heroParts(minutes: minutes)
            XCTAssertEqual(
                "\(parts.value) \(parts.unit)", RideDuration.text(minutes: minutes),
                "the hero halves must recompose into the one string, exactly"
            )
        }
        XCTAssertEqual(RideDuration.heroParts(minutes: 28).value, "28")
        XCTAssertEqual(RideDuration.heroParts(minutes: 28).unit, "min")
        XCTAssertEqual(RideDuration.heroParts(minutes: 60).value, "1")
        XCTAssertEqual(RideDuration.heroParts(minutes: 60).unit, "hr")
        XCTAssertEqual(RideDuration.heroParts(minutes: 2623).value, "43 hr 43")
        XCTAssertEqual(RideDuration.heroParts(minutes: 2623).unit, "min")
    }

    /// `awayText` is the pickup-ETA suffix ("A ride is N min away", the fleet-row
    /// note, the owner's incoming pickup leg) — one composition, so the four
    /// surfaces that say "away" cannot drift from the ones that do not.
    func testTheAwaySuffixComposesOntoTheSameSentence() {
        XCTAssertEqual(RideDuration.awayText(minutes: 3), "3 min away")
        XCTAssertEqual(RideDuration.awayText(minutes: 60), "1 hr away")
        XCTAssertEqual(RideDuration.awayText(minutes: 2592), "43 hr 12 min away")
        for minutes in [0, 1, 59, 60, 61, 2592] {
            XCTAssertEqual(RideDuration.awayText(minutes: minutes), "\(RideDuration.text(minutes: minutes)) away")
        }
    }
}

// MARK: - The surfaces actually go through it

/// A formatter nothing calls is the MYR-369 `VehicleRideShare.display` shape: a
/// pure rule with good tests and no consumers, green forever while the product
/// does something else. These drive the real copy helpers rather than the
/// formatter, so the sweep is asserted rather than reasoned about.
final class RideDurationSweepTests: XCTestCase {

    /// The idle placeholder — the FIRST of the client's two lines, and the one
    /// whose copy MYR-341 copied verbatim from `screens.jsx:1979`. Sub-hour is
    /// still that literal, character for character.
    func testTheIdlePlaceholderKeepsItsCopyAndGainsTheHourGrammar() {
        XCTAssertEqual(RiderIdlePlaceholder.etaLine(minutes: 9), "A ride is 9 min away")
        XCTAssertEqual(RiderIdlePlaceholder.etaLine(minutes: 3), "A ride is 3 min away")
        XCTAssertEqual(RiderIdlePlaceholder.etaLine(minutes: 2592), "A ride is 43 hr 12 min away")
    }

    /// Review's pickup sub-line — the client's literal "2592 min away".
    func testThePickupAwayNoteConverts() {
        XCTAssertEqual(RidePickupETADisplay.awayNote(etaMin: 3), "3 min away")
        XCTAssertEqual(RidePickupETADisplay.awayNote(etaMin: 60), "1 hr away")
        XCTAssertEqual(RidePickupETADisplay.awayNote(etaMin: 2592), "43 hr 12 min away")
    }

    /// MYR-341's 0 sentinel is untouched by all of this: an unmeasurable pickup
    /// still renders NOTHING rather than "0 min away", which the hour grammar must
    /// not accidentally resurrect as a formattable value.
    func testTheUnknownSentinelStillRendersNoNoteAtAll() {
        XCTAssertNil(RidePickupETADisplay.awayNote(etaMin: 0))
        XCTAssertNil(RidePickupETADisplay.minutes(0))
    }
}
