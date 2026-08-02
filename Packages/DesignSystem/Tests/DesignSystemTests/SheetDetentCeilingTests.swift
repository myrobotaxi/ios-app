import XCTest
@testable import DesignSystem

// MARK: - MYR-419 — the ceiling a sheet's detents may not rise through
//
// `MRTMetrics.sheetTallTopClearance` (140) is the sheet grammar's own number and
// it is measured for ONE piece of chrome: the `MapHeader` vehicle switcher. The
// owner Live Map stacks a dispatch status pill and a gold CTA under that chip
// while a ride is live, so the chrome above the sheet is ~90pt taller than the
// stop was cut for — and the sheet went straight through it (MYR-419, r18).
//
// The clearance is a PARAMETER now. These tests pin the two halves that matter:
// the default is byte-for-byte the old behaviour, and a raised clearance lowers
// every stop that would otherwise breach it — including `half`, which is where
// this rule would be quietly incomplete if it were expressed as "the tall detent
// stops lower". The sheet passes through every height between its detents on the
// way up, so the ceiling is a fact about the LADDER.
final class SheetDetentCeilingTests: XCTestCase {

    /// iPhone 17 Pro, the destination every capture in this repo is taken on.
    private let screen: CGFloat = 874
    /// 0.58 of the container (the screen less a 62pt top inset) — the owner
    /// sheet's shipped half detent, `MRTMetrics.homeHalfHeightFraction`.
    private var shippedHalf: CGFloat { (874 - 62) * MRTMetrics.homeHalfHeightFraction }
    private let parkedPeek = MRTMetrics.homePeekHeightParked

    // MARK: The default is the old behaviour, exactly

    func testTheDefaultClearanceReproducesTheGrammarsOwnTallStop() {
        let detents = MRTMetrics.sheetDetentHeights(
            peekHeight: parkedPeek,
            halfHeight: shippedHalf,
            screenHeight: screen,
            allowsTallDetent: true
        )
        XCTAssertEqual(detents.count, 3)
        XCTAssertEqual(detents[0], parkedPeek, accuracy: 0.001, "peek is never capped — it is the hero's content band")
        XCTAssertEqual(detents[1], shippedHalf, accuracy: 0.001, "half is the 0.58 fraction, untouched")
        XCTAssertEqual(
            detents[2], screen - MRTMetrics.sheetTallTopClearance, accuracy: 0.001,
            "tall is still the physical screen less the grammar's 140"
        )
    }

    func testATwoDetentSheetIsUnchangedByTheCeiling() {
        let detents = MRTMetrics.sheetDetentHeights(
            peekHeight: 260,
            halfHeight: 406,
            screenHeight: 812,
            allowsTallDetent: false
        )
        XCTAssertEqual(detents, [260, 406], "every peek/half sheet in the app keeps exactly the pair it had")
    }

    // MARK: A raised clearance lowers the stops that breach it

    func testARaisedClearanceLowersTheTallStopByExactlyTheDifference() {
        // The owner's live-dispatch stack: card top 112 + a 44pt pill + 10pt gap
        // + a 38pt CTA + a 24pt gutter below it.
        let clearance: CGFloat = 112 + 92 + 24
        let detents = MRTMetrics.sheetDetentHeights(
            peekHeight: parkedPeek,
            halfHeight: shippedHalf,
            screenHeight: screen,
            allowsTallDetent: true,
            topClearance: clearance
        )
        XCTAssertEqual(detents.count, 3, "the third detent survives the reserve — it does not collapse to peek/half")
        XCTAssertEqual(detents[2], screen - clearance, accuracy: 0.001)
        XCTAssertEqual(
            screen - detents[2], clearance, accuracy: 0.001,
            "the sheet's top edge IS the clearance, which is what the overlap guard measures"
        )
    }

    /// THE HALF-DETENT HALF OF THE RULE. It does not bind at the shipped numbers
    /// — that is what keeps every `MRT_OWNER_DETENT=half` capture byte-identical
    /// — and it DOES bind if a future fraction or a shorter device would put half
    /// through the chrome. Both are asserted, because "it happens not to matter
    /// today" is not the same statement as "it is handled".
    func testHalfIsUntouchedAtTheShippedNumbersAndCappedWhenItWouldBreach() {
        let clearance: CGFloat = 228
        let shipped = MRTMetrics.sheetDetentHeights(
            peekHeight: parkedPeek, halfHeight: shippedHalf, screenHeight: screen,
            allowsTallDetent: true, topClearance: clearance
        )
        XCTAssertEqual(shipped[1], shippedHalf, accuracy: 0.001, "0.58 of the container is far below the ceiling")
        XCTAssertLessThan(shippedHalf, screen - clearance, "…and this is why: it does not reach it")

        let greedy = MRTMetrics.sheetDetentHeights(
            peekHeight: parkedPeek, halfHeight: 820, screenHeight: screen,
            allowsTallDetent: true, topClearance: clearance
        )
        XCTAssertEqual(greedy[1], screen - clearance, accuracy: 0.001, "a half that would breach the ceiling is capped to it")
    }

    /// A clearance so large that no stop above half survives leaves the sheet its
    /// peek/half pair rather than a third detent the finger cannot tell apart
    /// from the second (`sheetTallHeight`'s existing +24 rule, unchanged).
    func testAClearanceThatLeavesNoRoomDropsTheTallDetentRatherThanFakingIt() {
        let detents = MRTMetrics.sheetDetentHeights(
            peekHeight: parkedPeek,
            halfHeight: shippedHalf,
            screenHeight: screen,
            allowsTallDetent: true,
            topClearance: screen - shippedHalf - 10
        )
        XCTAssertEqual(detents.count, 2)
        XCTAssertEqual(detents[1], shippedHalf, accuracy: 0.001)
    }

    // MARK: The ceiling is not the highest reachable height — the band above it is

    /// **A DETENT IS A STOP, NOT A LIMIT.** A finger can pull the sheet above its
    /// tallest detent and `SheetPhysics.rubberBand` resists rather than refuses,
    /// so any consumer reserving room above a sheet has to reserve for the band
    /// too. This pins the bound the owner Home's reserve is sized against: the
    /// resistance SATURATES at its `dimension`, so the visible height can exceed
    /// the top detent by strictly less than 30 however hard the pull.
    func testTheDragCanNeverRiseMoreThanTheRubberBandsSaturationAboveTheTopDetent() {
        let top: CGFloat = 630
        for pull in stride(from: CGFloat(1), through: 4000, by: 37) {
            let banded = SheetPhysics.rubberBand(top + pull, lowerBound: 210, upperBound: top)
            XCTAssertGreaterThanOrEqual(banded, top)
            XCTAssertLessThan(banded, top + 30, "pull \(pull) resisted to \(banded)")
        }
    }

    // MARK: MYR-227 — nothing non-finite reaches layout

    func testNonFiniteGeometryNeverProducesANonFiniteDetent() {
        for detents in [
            MRTMetrics.sheetDetentHeights(peekHeight: parkedPeek, halfHeight: .nan, screenHeight: screen, allowsTallDetent: true),
            MRTMetrics.sheetDetentHeights(peekHeight: parkedPeek, halfHeight: shippedHalf, screenHeight: .infinity, allowsTallDetent: true),
            MRTMetrics.sheetDetentHeights(peekHeight: parkedPeek, halfHeight: shippedHalf, screenHeight: screen, allowsTallDetent: true, topClearance: .nan)
        ] {
            XCTAssertFalse(detents.isEmpty)
            XCTAssertTrue(detents.allSatisfy { $0.isFinite && $0 > 0 }, "\(detents)")
            XCTAssertEqual(detents, detents.sorted(), "the engine requires an ascending ladder")
        }
    }
}
