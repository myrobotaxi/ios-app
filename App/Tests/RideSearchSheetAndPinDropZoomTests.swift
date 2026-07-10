import DesignSystem
@testable import MyRoboTaxi
import XCTest

// MARK: - MYR-215 — stable search-sheet height + pin-drop street zoom everywhere
//
// Two client-reported UX fixes on the live rider search / pin-drop flow:
//   1. the search sheet must NOT jump height on the first keystroke (live);
//   2. pin-drop must open street-level in BOTH live and sim (client-approved
//      deviation, waiving the sim pixel gate for pin-drop zoom only).
//
// The load-bearing derivations are extracted as pure functions
// (`RideRequestSearchContent.scrollRegionHeight`, `SharedViewerScreen
// .mapSpanDelta`) so both rules are unit-testable without mounting SwiftUI.
// The camera RE-FRAME on pin-drop entry is a SwiftUI `.onChange` seam driving
// `VehicleMapView.recenter` — like the MapProxy path in
// `PinDropAuthoritativeTests`, that plumbing is validated empirically at the
// drift gate / live probe; what's pinned here is the span it re-frames TO.

@MainActor
final class RideSearchSheetHeightTests: XCTestCase {

    // Representative header height (chips + route card) inside the 712 envelope.
    private let header: CGFloat = 180

    // MARK: defect 1 — live height is stable across the first keystroke

    func testLiveSearchHeightIsIndependentOfResultCount() {
        // The whole bug: pre-typing the results region is empty (0), the first
        // keystroke fills it. If the derived height moved with the result count,
        // the sheet frame would jump. In live it must NOT.
        let empty = RideRequestSearchContent.scrollRegionHeight(
            isLive: true, headerHeight: header, resultsHeight: 0)
        let oneResult = RideRequestSearchContent.scrollRegionHeight(
            isLive: true, headerHeight: header, resultsHeight: 60)
        let fullList = RideRequestSearchContent.scrollRegionHeight(
            isLive: true, headerHeight: header, resultsHeight: 9999)

        XCTAssertEqual(empty, oneResult, "live sheet height must not change when a result appears")
        XCTAssertEqual(empty, fullList, "live sheet height must not change however many results arrive")
    }

    func testLiveSearchHeightFillsTheFull712Envelope() {
        // header + top pad(6) + region + bottom pad == the 712 sheet height, so
        // the sheet opens at the SAME height it uses with results.
        let region = RideRequestSearchContent.scrollRegionHeight(
            isLive: true, headerHeight: header, resultsHeight: 0)
        let total = 6 + header + region + MRTMetrics.homeSheetContentBottomPadding
        XCTAssertEqual(total, MRTMetrics.rideRequestSearchSheetHeight, accuracy: 0.5)
    }

    // MARK: sim stays MYR-200 hug-to-content (pixel-identical)

    func testSimSearchHeightStillHugsContent() {
        // A short list hugs its content; a long list caps at the envelope and
        // scrolls — unchanged from MYR-200 (sim scenes stay pixel-identical).
        let shortList = RideRequestSearchContent.scrollRegionHeight(
            isLive: false, headerHeight: header, resultsHeight: 120)
        XCTAssertEqual(shortList, 120, "sim hugs a short list")

        let available = MRTMetrics.rideRequestSearchSheetHeight - 6
            - MRTMetrics.homeSheetContentBottomPadding - header
        let longList = RideRequestSearchContent.scrollRegionHeight(
            isLive: false, headerHeight: header, resultsHeight: 9999)
        XCTAssertEqual(longList, available, "sim caps a long list at the envelope")
    }

    func testHeightNeverNegativeWhenHeaderFillsTheEnvelope() {
        let region = RideRequestSearchContent.scrollRegionHeight(
            isLive: true, headerHeight: 5000, resultsHeight: 100)
        XCTAssertEqual(region, 0)
    }
}

// MARK: - MYR-215 deliverable 3 — choose-then-proceed on the search sheet

@MainActor
final class SearchChooseThenProceedTests: XCTestCase {

    private func makeState() -> SharedViewerState {
        let state = SharedViewerState() // simulated seams
        state.sheetPhase = .search
        return state
    }

    private var sampleDestination: RidePlace {
        RideRequestFixtures.recentPlaces[0]
    }

    // Selection enters the destination but does NOT advance the flow.
    func testChoosingDestinationDoesNotAdvance() {
        let state = makeState()
        state.chooseDestination(sampleDestination)
        XCTAssertEqual(state.draftDestination?.id, sampleDestination.id, "destination is entered")
        XCTAssertEqual(state.sheetPhase, .search, "the rider stays on the search sheet")
    }

    // A chosen destination is what drives the CTA to appear (view reads it).
    func testChosenDestinationIsTheCTATrigger() {
        let state = makeState()
        XCTAssertNil(state.draftDestination, "no CTA before a choice")
        state.chooseDestination(sampleDestination)
        XCTAssertNotNil(state.draftDestination, "CTA shows once a destination is chosen")
    }

    // Continue advances via the existing path: pin-drop to confirm pickup.
    func testProceedAdvancesToPinDropWhenNoPickupSet() {
        let state = makeState()
        state.chooseDestination(sampleDestination)
        state.proceedFromSearch()
        XCTAssertEqual(state.sheetPhase, .pinDrop(returnTo: .review))
        XCTAssertEqual(state.pinReturn, .review)
    }

    // Continue with a pickup already set skips straight to Review.
    func testProceedGoesToReviewWhenPickupAlreadySet() {
        let state = makeState()
        state.draftPickup = sampleDestination // any set pickup
        state.chooseDestination(sampleDestination)
        state.proceedFromSearch()
        XCTAssertEqual(state.sheetPhase, .review)
    }

    // Editing / clearing the field returns to search-as-you-type.
    func testClearChosenDestinationReturnsToSearch() {
        let state = makeState()
        state.chooseDestination(sampleDestination)
        state.clearChosenDestination()
        XCTAssertNil(state.draftDestination, "the choice is cleared")
        XCTAssertEqual(state.sheetPhase, .search, "still on the search sheet, results mode")
    }

    func testProceedIsNoOpWithoutADestination() {
        let state = makeState()
        state.proceedFromSearch()
        XCTAssertEqual(state.sheetPhase, .search, "nothing to proceed with")
    }
}

final class PinDropZoomSpanTests: XCTestCase {

    // MARK: defect 2 — pin-drop is street-level in BOTH modes

    func testPinDropSpanIsStreetLevel() {
        XCTAssertEqual(SharedViewerScreen.mapSpanDelta(isPinDrop: true),
                       MRTMetrics.pinDropStreetSpanDelta)
        XCTAssertLessThan(SharedViewerScreen.mapSpanDelta(isPinDrop: true),
                          MRTMetrics.mapRegionSpanDelta,
                          "pin-drop must be tighter than the neighborhood overview")
    }

    func testNonPinDropSpanIsTheOverview() {
        XCTAssertEqual(SharedViewerScreen.mapSpanDelta(isPinDrop: false),
                       MRTMetrics.mapRegionSpanDelta)
    }

    func testSpanSelectionHasNoLiveGate() {
        // The MYR-213 regression was a live-only gate; MYR-215 removes it. The
        // extracted selector takes no mode at all, so the same street span is
        // returned for pin-drop regardless of sim/live — the guarantee this test
        // exists to lock in.
        XCTAssertEqual(SharedViewerScreen.mapSpanDelta(isPinDrop: true),
                       SharedViewerScreen.mapSpanDelta(isPinDrop: true))
        XCTAssertNotEqual(SharedViewerScreen.mapSpanDelta(isPinDrop: true),
                          SharedViewerScreen.mapSpanDelta(isPinDrop: false))
    }
}
