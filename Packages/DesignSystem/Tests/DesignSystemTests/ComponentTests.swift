import XCTest
import SwiftUI
@testable import DesignSystem

final class ComponentTests: XCTestCase {
    /// Handoff §3: heights sm 38 · md 46 · lg 52.
    func testButtonSizes() {
        XCTAssertEqual(MRTButtonSize.sm.height, 38)
        XCTAssertEqual(MRTButtonSize.md.height, 46)
        XCTAssertEqual(MRTButtonSize.lg.height, 52)
    }

    /// Variant raw values match the prototype's variant keys 1:1.
    func testVariantKeysMatchPrototype() {
        XCTAssertEqual(
            MRTButtonVariant.allCases.map(\.rawValue),
            ["gold", "outline", "outline-muted", "outline-draw", "outline-static", "ghost"]
        )
    }

    /// Handoff §7 overlay metrics.
    func testOverlayMetrics() {
        XCTAssertEqual(MRTMetrics.dialogRadius, 22)
        XCTAssertEqual(MRTMetrics.dialogMaxWidth, 300)
        XCTAssertEqual(MRTMetrics.dialogIconSize, 46)
        XCTAssertEqual(MRTMetrics.configSheetRadius, 26)
        XCTAssertEqual(MRTMetrics.toastBottomOffset, 116)
        XCTAssertEqual(MRTMetrics.sheetPeekHeight, 260)
    }

    // MARK: - Tall sheet detent (MYR-332 — pulling the owner sheet higher)

    /// The stop is the sheet grammar's own tallest surface, not a new number: the
    /// rider search sheet is `SHEET_HEIGHTS.search` = 712 on the prototype's 852pt
    /// canvas (ride-request.jsx:47), which leaves 140pt of chrome above it. If
    /// this ever drifts, the owner sheet and the rider sheet stop topping out at
    /// the same place.
    func testTallClearanceIsTheGrammarsOwnTallestSurface() {
        XCTAssertEqual(MRTMetrics.sheetTallTopClearance, 852 - 712)
        // …and it clears the MapHeader switcher whole (top 60 + a 40pt chip), so
        // the owner can still see WHICH car the controls belong to.
        XCTAssertGreaterThan(
            MRTMetrics.sheetTallTopClearance,
            MRTMetrics.mapHeaderTop + MRTMetrics.mapChipHeight,
            "a tall sheet that covers the vehicle switcher is a takeover, not a detent"
        )
    }

    /// The detent is measured from the PHYSICAL screen, so every device lands the
    /// sheet's top edge at the same 140pt from its own top.
    func testTallHeightIsTheScreenLessTheClearance() {
        for screen in [CGFloat(667), 852, 874, 956] {
            XCTAssertEqual(
                MRTMetrics.sheetTallHeight(screenHeight: screen, halfHeight: 400),
                screen - MRTMetrics.sheetTallTopClearance,
                "screen \(screen)"
            )
        }
    }

    /// A sheet only gains the stop when it is worth having. Two detents a finger
    /// cannot tell apart are worse than one, and a NaN must never reach layout
    /// (MYR-227) — both collapse to "no tall detent", which leaves the peek↔half
    /// pair exactly as it was.
    func testTallHeightIsRefusedWhenItWouldNotBeADistinctStop() {
        // Half already at/above the cap.
        XCTAssertNil(MRTMetrics.sheetTallHeight(screenHeight: 852, halfHeight: 712))
        // Half within a hair of it.
        XCTAssertNil(MRTMetrics.sheetTallHeight(screenHeight: 852, halfHeight: 700))
        // Comfortably below it — offered.
        XCTAssertNotNil(MRTMetrics.sheetTallHeight(screenHeight: 852, halfHeight: 600))
        // Non-finite inputs never produce a detent.
        XCTAssertNil(MRTMetrics.sheetTallHeight(screenHeight: .nan, halfHeight: 400))
        XCTAssertNil(MRTMetrics.sheetTallHeight(screenHeight: 852, halfHeight: .infinity))
    }

    /// The owner sheet's real geometry: the 0.58 half fraction leaves the tall
    /// detent a genuine step up on every device this ships to.
    func testOwnerSheetGainsAMeaningfulTallStepOnEveryDevice() {
        for screen in [CGFloat(667), 852, 874, 956] {
            // The sheet's container is the screen less the top safe area; 0 is the
            // worst case for `half` being close to the cap.
            let half = screen * MRTMetrics.homeHalfHeightFraction
            let tall = MRTMetrics.sheetTallHeight(screenHeight: screen, halfHeight: half)
            let step = try? XCTUnwrap(tall) - half
            XCTAssertNotNil(tall, "screen \(screen) should offer a tall detent")
            XCTAssertGreaterThan(step ?? 0, 100, "screen \(screen): the tall stop must be a real step above half")
        }
    }

    // MARK: - Owner sheet peek band (MYR-315 — the crowded freshness stamp)

    /// The band is the prototype's number when the hero holds the prototype's
    /// content. This is the byte-identity guard: the simulated / drift-gate path
    /// renders no live-only qualifier line, so it must land on 210 / 280 exactly.
    func testPeekBandIsThePrototypeNumberWithNoLiveOnlyLines() {
        XCTAssertEqual(
            MRTMetrics.homePeekHeight(base: MRTMetrics.homePeekHeightParked, qualifierLines: 0),
            MRTMetrics.homePeekHeightParked
        )
        XCTAssertEqual(
            MRTMetrics.homePeekHeight(base: MRTMetrics.homePeekHeightDriving, qualifierLines: 0),
            MRTMetrics.homePeekHeightDriving
        )
        XCTAssertEqual(
            MRTMetrics.homePeekHeight(base: 210, qualifierLines: -1), 210,
            "a negative count is nonsense and must not SHRINK the band"
        )
    }

    /// A live-only qualifier line brings its OWN room. The client's complaint was
    /// that it did not: MYR-315 appended the freshness stamp to a fixed 210pt band,
    /// so the added line ate into the clearance `BottomSheet` reserves above the
    /// floating nav — and the stamp, being interactive, put its ≥44pt target across
    /// the nav's top edge. Growing the band by at least a full line + the tap
    /// overhang is what puts that clearance back.
    func testEachLiveOnlyQualifierLineGrowsTheBandByItsOwnHeight() {
        let one = MRTMetrics.homePeekHeight(base: 210, qualifierLines: 1)
        let two = MRTMetrics.homePeekHeight(base: 210, qualifierLines: 2)
        XCTAssertEqual(one - 210, MRTMetrics.homePeekQualifierLineHeight)
        XCTAssertEqual(two - one, MRTMetrics.homePeekQualifierLineHeight)
        // An in-service car on the live path renders BOTH lines — the case the
        // client was actually looking at.
        XCTAssertEqual(two, 258)
    }

    /// The arithmetic the fix rests on, asserted rather than left in a comment:
    /// the design reserves a 100pt band above the physical edge for sheet content
    /// (components.jsx:542), and the floating nav's own top edge sits INSIDE it at
    /// 86pt (60pt tall, floating 26pt up). Sheet content that respects the 100 can
    /// never reach the nav; content that spends the 100 reaches it immediately.
    func testTheReservedSheetBandClearsTheFloatingNav() {
        XCTAssertEqual(MRTMetrics.bottomNavTopEdge, 86)
        XCTAssertGreaterThan(
            MRTMetrics.homeSheetContentBottomPadding, MRTMetrics.bottomNavTopEdge,
            "the reserved band must extend ABOVE the nav, or it reserves nothing"
        )
        XCTAssertGreaterThanOrEqual(
            MRTMetrics.homePeekQualifierLineHeight,
            MRTMetrics.homeSheetContentBottomPadding - MRTMetrics.bottomNavTopEdge,
            "one added line must at least restore the 14pt the nav band leaves over"
        )
    }

    /// The trace gradient starts and ends on the same stop, so the 2.6s loop
    /// is seamless (the jsx conic's 0deg and 360deg stops match).
    func testTraceGradientIsSeamless() {
        let stops = MRTTraceBorder.traceStops
        XCTAssertEqual(stops.first?.location, 0)
        XCTAssertEqual(stops.last?.location, 1)
        XCTAssertEqual(stops.first?.color, stops.last?.color)
        let comet = MRTTraceBorder.cometStops
        XCTAssertEqual(comet.first?.color, .clear)
        XCTAssertEqual(comet.last?.color, .clear)
    }

    func testDialogConfigDefaultDismissLabel() {
        let config = MRTConfirmDialogConfig(
            kind: .destructive, icon: "xmark", title: "t", message: "m",
            actionLabel: "a", action: {}
        )
        XCTAssertEqual(config.dismissLabel, "Cancel")
    }
}
