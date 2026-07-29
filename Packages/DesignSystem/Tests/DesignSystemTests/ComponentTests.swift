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
