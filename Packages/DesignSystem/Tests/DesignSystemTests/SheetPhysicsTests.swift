import XCTest
import CoreGraphics
@testable import DesignSystem

// MARK: - SheetPhysics (MYR-236) — pure drag math
//
// The fluid-sheet feel is the deliverable, so its decision math is proven
// here table-driven: rubber-band resistance, velocity projection, and
// nearest-detent selection (incl. flick-crosses-detent and slow-drag-returns).
final class SheetPhysicsTests: XCTestCase {

    // Standard home-sheet detents used across the cases.
    private let peek: CGFloat = 260
    private let half: CGFloat = 494 // ~0.58 * 852

    // MARK: Rubber-banding

    /// Inside the detent range the value passes through untouched (1:1 track).
    func testRubberBandIsIdentityWithinBounds() {
        for v in stride(from: peek, through: half, by: 13) {
            XCTAssertEqual(SheetPhysics.rubberBand(v, lowerBound: peek, upperBound: half), v, accuracy: 0.0001)
            // Bounds themselves are inclusive identity.
        }
        XCTAssertEqual(SheetPhysics.rubberBand(peek, lowerBound: peek, upperBound: half), peek, accuracy: 0.0001)
        XCTAssertEqual(SheetPhysics.rubberBand(half, lowerBound: peek, upperBound: half), half, accuracy: 0.0001)
    }

    /// Past a bound the excess is compressed, monotonic, and never exceeds the
    /// `dimension` ceiling (soft wall, not a hard clamp — but bounded).
    func testRubberBandCompressesAndSaturatesAbove() {
        let d: CGFloat = 30
        var last = half
        for over in stride(from: CGFloat(1), through: 400, by: 7) {
            let banded = SheetPhysics.rubberBand(half + over, lowerBound: peek, upperBound: half, dimension: d)
            // Always past the bound but by strictly less than the raw excess.
            XCTAssertGreaterThan(banded, half)
            XCTAssertLessThan(banded, half + over)
            // Never more than `dimension` past the bound.
            XCTAssertLessThan(banded, half + d)
            // Monotonic increasing.
            XCTAssertGreaterThanOrEqual(banded, last)
            last = banded
        }
        // A huge overshoot approaches — but stays under — the ceiling.
        let extreme = SheetPhysics.rubberBand(half + 100_000, lowerBound: peek, upperBound: half, dimension: d)
        XCTAssertEqual(extreme, half + d, accuracy: 0.5)
    }

    /// Symmetric below the lower bound.
    func testRubberBandCompressesAndSaturatesBelow() {
        let d: CGFloat = 30
        var last = peek
        for under in stride(from: CGFloat(1), through: 400, by: 7) {
            let banded = SheetPhysics.rubberBand(peek - under, lowerBound: peek, upperBound: half, dimension: d)
            XCTAssertLessThan(banded, peek)
            XCTAssertGreaterThan(banded, peek - under)
            XCTAssertGreaterThan(banded, peek - d)
            XCTAssertLessThanOrEqual(banded, last)
            last = banded
        }
        let extreme = SheetPhysics.rubberBand(peek - 100_000, lowerBound: peek, upperBound: half, dimension: d)
        XCTAssertEqual(extreme, peek - d, accuracy: 0.5)
    }

    /// Overscroll starts soft: the first point past the bound moves ~`coeff`
    /// of a point, i.e. resistance is felt immediately (not a dead stop).
    func testRubberBandInitialSlope() {
        let banded = SheetPhysics.rubberBand(half + 1, lowerBound: peek, upperBound: half, dimension: 30, coefficient: 0.55)
        let delta = banded - half
        XCTAssertGreaterThan(delta, 0)
        XCTAssertLessThan(delta, 0.55) // slightly under the initial slope
    }

    /// Non-finite input never escapes to layout (MYR-227 rule) — it collapses
    /// to the safe lower bound rather than propagating.
    func testRubberBandGuardsNonFinite() {
        XCTAssertEqual(SheetPhysics.rubberBand(.nan, lowerBound: peek, upperBound: half), peek)
        XCTAssertEqual(SheetPhysics.rubberBand(.infinity, lowerBound: peek, upperBound: half), peek)
    }

    // MARK: Velocity projection

    /// Zero velocity coasts nowhere; sign is preserved; faster ⇒ farther.
    func testProjectionSignAndMagnitude() {
        XCTAssertEqual(SheetPhysics.projection(velocity: 0), 0, accuracy: 0.0001)
        XCTAssertGreaterThan(SheetPhysics.projection(velocity: 1000), 0)
        XCTAssertLessThan(SheetPhysics.projection(velocity: -1000), 0)
        XCTAssertGreaterThan(
            SheetPhysics.projection(velocity: 3000),
            SheetPhysics.projection(velocity: 1000)
        )
        // Symmetric.
        XCTAssertEqual(
            SheetPhysics.projection(velocity: 1500),
            -SheetPhysics.projection(velocity: -1500),
            accuracy: 0.0001
        )
    }

    /// Known value: default rate 0.998 ⇒ factor 499, so v=2000 ⇒ ~998pt.
    func testProjectionKnownValue() {
        XCTAssertEqual(SheetPhysics.projection(velocity: 2000), 998, accuracy: 1)
    }

    func testProjectionGuardsNonFinite() {
        XCTAssertEqual(SheetPhysics.projection(velocity: .nan), 0)
        XCTAssertEqual(SheetPhysics.projection(velocity: .infinity), 0)
    }

    // MARK: Nearest-detent selection

    func testNearestDetentByPosition() {
        // Clearly near peek.
        XCTAssertEqual(SheetPhysics.nearestDetent(toProjectedHeight: peek + 10, peekHeight: peek, halfHeight: half), .peek)
        // Clearly near half.
        XCTAssertEqual(SheetPhysics.nearestDetent(toProjectedHeight: half - 10, peekHeight: peek, halfHeight: half), .half)
        // Exact midpoint biases to peek (resting), matching prototype `> mid`.
        let mid = (peek + half) / 2
        XCTAssertEqual(SheetPhysics.nearestDetent(toProjectedHeight: mid, peekHeight: peek, halfHeight: half), .peek)
        XCTAssertEqual(SheetPhysics.nearestDetent(toProjectedHeight: mid + 1, peekHeight: peek, halfHeight: half), .half)
    }

    /// Fast flick UP from near peek (small displacement) still lands on half,
    /// because projection carries the endpoint across the midpoint.
    func testFastFlickCrossesDetent() {
        let releaseHeight = peek + 20 // barely moved up
        let velocityUp: CGFloat = 2500 // fast upward flick (height-space +)
        let projected = releaseHeight + SheetPhysics.projection(velocity: velocityUp)
        XCTAssertEqual(
            SheetPhysics.nearestDetent(toProjectedHeight: projected, peekHeight: peek, halfHeight: half),
            .half
        )
    }

    /// Slow drag UP most of the way but released with ~no velocity, still short
    /// of the midpoint ⇒ returns to peek (no accidental commit).
    func testSlowDragBelowMidReturns() {
        let releaseHeight = (peek + half) / 2 - 12 // just below midpoint
        let velocity: CGFloat = 10 // near-zero drift (~5pt of coast)
        let projected = releaseHeight + SheetPhysics.projection(velocity: velocity)
        XCTAssertEqual(
            SheetPhysics.nearestDetent(toProjectedHeight: projected, peekHeight: peek, halfHeight: half),
            .peek
        )
    }

    /// Fast flick DOWN from near half collapses to peek even from high up.
    func testFastFlickDownCollapses() {
        let releaseHeight = half - 20
        let velocityDown: CGFloat = -2500 // downward (height-space −)
        let projected = releaseHeight + SheetPhysics.projection(velocity: velocityDown)
        XCTAssertEqual(
            SheetPhysics.nearestDetent(toProjectedHeight: projected, peekHeight: peek, halfHeight: half),
            .peek
        )
    }

    func testNearestDetentGuardsNonFinite() {
        XCTAssertEqual(SheetPhysics.nearestDetent(toProjectedHeight: .nan, peekHeight: peek, halfHeight: half), .peek)
    }
}
