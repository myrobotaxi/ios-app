import CoreLocation
import DesignSystem
@testable import MyRoboTaxi
import XCTest

// MARK: - MYR-223 deliverables 2 & 3 — per-phase map insets + rider recenter

@MainActor
final class PerPhaseMapInsetTests: XCTestCase {

    // MARK: deliverable 2 — the phase→bottom-chrome-inset table
    //
    // The bug: the map's bottom inset (which keeps the MapKit attribution above
    // the chrome) was FIXED at the tall greeting-sheet height for every idle
    // state, so when the idle sheet shrank to the short "Request sent" pending
    // pill the attribution floated at mid-page. The inset must track the ACTUAL
    // chrome height per phase — one source of truth.

    func testIdleGreetingUsesTheTallSheetInset() {
        XCTAssertEqual(SharedViewerScreen.mapBottomInset(phase: .idle, isPendingPill: false),
                       MRTMetrics.sharedIdleSheetHeight)
    }

    func testPendingPillInsetIsShorterThanGreeting() {
        let greeting = SharedViewerScreen.mapBottomInset(phase: .idle, isPendingPill: false)
        let pill = SharedViewerScreen.mapBottomInset(phase: .idle, isPendingPill: true)
        XCTAssertEqual(pill, MRTMetrics.sharedPendingPillSheetHeight)
        // The regression guard: the attribution inset SHRINKS with the chrome —
        // exactly what the fixed 286 failed to do (floating the ⚠ at mid-page).
        XCTAssertLessThan(pill, greeting)
    }

    func testSearchPinDropAndRouteInsetsPerPhase() {
        XCTAssertEqual(SharedViewerScreen.mapBottomInset(phase: .search, isPendingPill: false),
                       MRTMetrics.rideRequestSearchSheetHeight)
        XCTAssertEqual(SharedViewerScreen.mapBottomInset(phase: .pinDrop(returnTo: .search), isPendingPill: false),
                       MRTMetrics.rideRequestPinDropMapInset)
        for phase in [RiderSheetPhase.review, .booking] {
            XCTAssertEqual(SharedViewerScreen.mapBottomInset(phase: phase, isPendingPill: false),
                           MRTMetrics.rideRequestRouteMapBottomInset)
        }
        // MYR-177: tracking has its own (shorter) sheet-cover inset.
        XCTAssertEqual(SharedViewerScreen.mapBottomInset(phase: .tracking, isPendingPill: false),
                       MRTMetrics.trackingMapBottomInset)
    }

    func testSummaryIsFullScreenNoInset() {
        // Summary is a full-screen takeover — no bottom sheet to clear.
        XCTAssertEqual(SharedViewerScreen.mapBottomInset(phase: .summary, isPendingPill: false), 0)
    }
}

// MARK: - MYR-223 deliverable 3 — rider recenter re-engages follow cleanly
//
// The recenter button sets `isFollowing = true`, which drives the same
// programmatic `recenter()` + `CameraSettleLedger` accounting the owner map uses
// (VehicleMapView). These tests exercise that ledger the way the recenter flow
// does: the programmatic recenter (and the follow fixes after it) must classify
// as OURS, and the rider's next gesture must stand follow back down — no
// misclassification, no re-fighting the user.

final class RiderRecenterFollowTests: XCTestCase {

    private let overview = MRTMetrics.mapRegionSpanDelta // idle recenter framing span
    private let fix0 = CLLocationCoordinate2D(latitude: 37.7871, longitude: -122.3971)

    private func moved(_ base: CLLocationCoordinate2D, lat: Double, lon: Double = 0) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: base.latitude + lat, longitude: base.longitude + lon)
    }

    func testRecenterThenFollowFixesClassifyProgrammaticThenGestureStandsDown() {
        var ledger = CameraSettleLedger()

        // 1. Tap recenter → isFollowing=true → recenter() writes the region at the
        //    current fix and registers the expected settle.
        ledger.expect(center: fix0, spanDelta: overview)
        XCTAssertTrue(ledger.classifySettle(center: fix0, latitudeDelta: overview * 1.156),
                      "the programmatic recenter is ours — follow re-engages, not a gesture")

        // 2. N device fixes arrive while following → each recenters (expect+settle)
        //    and must classify as ours (follow keeps tracking), at any fix rate.
        var fix = fix0
        for _ in 0..<5 {
            fix = moved(fix, lat: 0.0009, lon: -0.0009)
            ledger.expect(center: fix, spanDelta: overview)
            XCTAssertTrue(ledger.classifySettle(center: fix, latitudeDelta: overview * 1.156),
                          "a follow fix after recenter is ours")
        }

        // 3. The rider pans → an unmatched settle → the user wins, follow stands
        //    down again (the button reappears). No leftover expectation launders it.
        let dragged = moved(fix, lat: 0.02, lon: 0.02)
        XCTAssertFalse(ledger.classifySettle(center: dragged, latitudeDelta: overview * 1.156),
                       "the rider's gesture is NOT ours — follow disengages")
    }

    func testRecenterButtonMirrorsTheOwnerPlacementGap() {
        // Deliverable 3 mirrors the owner's `peekH + 80` placement metric — the
        // rider button floats one `mapButtonBottomGap` above the phase chrome.
        XCTAssertEqual(MRTMetrics.mapButtonBottomGap, 80)
    }
}
