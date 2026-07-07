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
