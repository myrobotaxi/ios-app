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

    // MARK: MYR-250 item 1 — the map stays PUT under the idle↔search sheet
    //
    // The client: "When I swipe up rider bottom sheet it moves the entire map up.
    // The bottom sheet should be swiping up over the map, not moving the map up
    // with it." Root cause: the `VehicleMapView`'s `.safeAreaPadding(.bottom:)`
    // was the FULL 712pt search-sheet height on `.search`, so committing
    // idle→search grew the inset (286→712) and MapKit shifted the framed center
    // UP by that jump — the map "moving up with the sheet". The `VehicleMapView`
    // camera inset for SEARCH must equal the IDLE inset so the map holds still;
    // the taller sheet simply covers more of the same map (the Apple Maps model).

    func testVehicleMapInsetForSearchEqualsIdleSoTheMapStaysPut() {
        // The camera inset the idle/search/pin-drop VehicleMapView actually uses:
        // search shares idle's, so idle→search never recenters the map.
        let idle = SharedViewerScreen.vehicleMapBottomInset(phase: .idle, isPendingPill: false)
        let search = SharedViewerScreen.vehicleMapBottomInset(phase: .search, isPendingPill: false)
        XCTAssertEqual(search, idle,
                       "the search VehicleMapView must share the idle camera inset so opening search never shifts the map")
        XCTAssertEqual(search, MRTMetrics.sharedIdleSheetHeight)
        // And it is DECOUPLED from the tall search-sheet chrome height (which the
        // attribution table still reports) — that jump was the coupling to remove.
        XCTAssertNotEqual(search, SharedViewerScreen.mapBottomInset(phase: .search, isPendingPill: false))
    }

    func testVehicleMapInsetLeavesPinDropAndOtherPhasesOnTheirOwn() {
        // Pin-drop is a legitimate street-level refit — it keeps its own inset.
        XCTAssertEqual(
            SharedViewerScreen.vehicleMapBottomInset(phase: .pinDrop(returnTo: .search), isPendingPill: false),
            SharedViewerScreen.mapBottomInset(phase: .pinDrop(returnTo: .search), isPendingPill: false)
        )
        // Idle (greeting + pending pill) is unchanged.
        XCTAssertEqual(SharedViewerScreen.vehicleMapBottomInset(phase: .idle, isPendingPill: true),
                       SharedViewerScreen.mapBottomInset(phase: .idle, isPendingPill: true))
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
