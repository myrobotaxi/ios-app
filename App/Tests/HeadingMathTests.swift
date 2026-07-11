import DesignSystem
import XCTest

// MARK: - MYR-177 — shortest-arc heading interpolation
//
// The wrap the marker must NOT get wrong: 359° → 1° is a +2° turn, never a
// −358° spin. `unwrapped` produces a continuous angle so `withAnimation`
// rotates the short way; Reduce Motion snaps to the same value.

final class HeadingMathTests: XCTestCase {

    func testShortestDeltaWrapsForward() {
        XCTAssertEqual(HeadingMath.shortestDelta(from: 359, to: 1), 2, accuracy: 1e-9)
    }

    func testShortestDeltaWrapsBackward() {
        XCTAssertEqual(HeadingMath.shortestDelta(from: 1, to: 359), -2, accuracy: 1e-9)
    }

    func testShortestDeltaStraightAhead() {
        XCTAssertEqual(HeadingMath.shortestDelta(from: 10, to: 80), 70, accuracy: 1e-9)
    }

    func testShortestDeltaHalfTurnIsPositive180() {
        // The boundary: exactly opposite resolves to +180 (either way is equal).
        XCTAssertEqual(HeadingMath.shortestDelta(from: 0, to: 180), 180, accuracy: 1e-9)
        XCTAssertEqual(HeadingMath.shortestDelta(from: 0, to: 181), -179, accuracy: 1e-9)
    }

    func testUnwrappedIsContinuousAcrossWrap() {
        // Displayed at 359; new target 1 → we render 361 (short way), not 1.
        XCTAssertEqual(HeadingMath.unwrapped(from: 359, to: 1), 361, accuracy: 1e-9)
        // Displayed at 361 (already past a full turn), target 5 → 365.
        XCTAssertEqual(HeadingMath.unwrapped(from: 361, to: 5), 365, accuracy: 1e-9)
    }

    func testUnwrappedBackwardAcrossZero() {
        XCTAssertEqual(HeadingMath.unwrapped(from: 2, to: 358), -2, accuracy: 1e-9)
    }

    func testNonFiniteInputsAreSafe() {
        XCTAssertEqual(HeadingMath.shortestDelta(from: .nan, to: 90), 0)
        XCTAssertEqual(HeadingMath.unwrapped(from: .infinity, to: 90), 90)
        XCTAssertTrue(HeadingMath.unwrapped(from: 10, to: .nan).isFinite)
    }

    func testMapRelativeSubtractsCameraHeading() {
        // Map-relative: a north-up camera renders heading verbatim; a rotated
        // camera counter-rotates so the bearing stays correct on the ground.
        XCTAssertEqual(HeadingMath.mapRelative(heading: 90, cameraHeading: 0), 90, accuracy: 1e-9)
        XCTAssertEqual(HeadingMath.mapRelative(heading: 90, cameraHeading: 30), 60, accuracy: 1e-9)
    }
}
