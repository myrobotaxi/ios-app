import CoreLocation
import DesignSystem
@testable import MyRoboTaxi
import XCTest

// MARK: - MYR-222 — token-based gesture-vs-programmatic settle classification
//
// The classifier that replaced the wall-clock "programmatic window". The
// property the window could never have under a streaming fix (and the reason
// the client's idle map snapped back on every gesture): classification is
// INDEPENDENT OF WRITE RATE — a settle is ours iff it matches a write we
// actually issued, so a 1Hz recenter stream cannot eat the user's drag.

final class CameraSettleLedgerTests: XCTestCase {

    private let overview = MRTMetrics.mapRegionSpanDelta // 0.06 — idle/search framing
    private let center = CLLocationCoordinate2D(latitude: 37.7871, longitude: -122.3971)

    private func offset(_ base: CLLocationCoordinate2D, lat: Double = 0, lon: Double = 0) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: base.latitude + lat, longitude: base.longitude + lon)
    }

    // MARK: our own settles match

    func testOwnWriteSettleMatches() {
        var ledger = CameraSettleLedger()
        ledger.expect(center: center, spanDelta: overview)
        // Empirically our settles land on the target to ~1e-13°, and MapKit
        // stretches the requested span by the viewport fit (observed 1.156×
        // on the idle map).
        XCTAssertTrue(ledger.classifySettle(center: center, latitudeDelta: overview * 1.156))
    }

    func testRetargetDeviationWithinToleranceStillMatches() {
        // Observed in the streaming probe: a follow animation retargeted
        // mid-flight settles ~3.5e-5° off the target. That is OUR settle.
        var ledger = CameraSettleLedger()
        ledger.expect(center: center, spanDelta: overview)
        XCTAssertTrue(ledger.classifySettle(center: offset(center, lat: 3.5e-5),
                                            latitudeDelta: overview * 1.156))
    }

    func testInsetStretchedSpanWithinWindowMatches() {
        // The pin-drop sheet inset stretches the visible span to ~2.6× the
        // request (MYR-217 empirics) — still ours.
        var ledger = CameraSettleLedger()
        ledger.expect(center: center, spanDelta: 0.004)
        XCTAssertTrue(ledger.classifySettle(center: center, latitudeDelta: 0.0104))
    }

    func testRetargetedWriteConsumesSupersededExpectations() {
        // Write A is retargeted by write B before settling — the camera
        // settles ONCE, at B. Matching B must consume A too, so A can never
        // launder a later user settle as programmatic.
        var ledger = CameraSettleLedger()
        let a = center
        let b = offset(center, lat: 0.01)
        ledger.expect(center: a, spanDelta: overview)
        ledger.expect(center: b, spanDelta: overview)
        XCTAssertTrue(ledger.classifySettle(center: b, latitudeDelta: overview * 1.156))
        XCTAssertFalse(ledger.classifySettle(center: a, latitudeDelta: overview * 1.156),
                       "the superseded target was consumed with the newer match")
    }

    // MARK: user gestures do NOT match — follow stops on the first one

    func testUserPanDoesNotMatch() {
        var ledger = CameraSettleLedger()
        ledger.expect(center: center, spanDelta: overview)
        XCTAssertFalse(ledger.classifySettle(center: offset(center, lat: 0.008, lon: 0.006),
                                             latitudeDelta: overview * 1.156),
                       "a drag's settle matches no outstanding write → user → follow off")
    }

    func testUserZoomInDoesNotMatch() {
        // A pinch-in keeps the center but shrinks the span below the request —
        // outside the stretch window (MapKit never shows LESS than requested).
        var ledger = CameraSettleLedger()
        ledger.expect(center: center, spanDelta: overview)
        XCTAssertFalse(ledger.classifySettle(center: center, latitudeDelta: overview * 0.5))
    }

    func testUserZoomOutBeyondStretchWindowDoesNotMatch() {
        var ledger = CameraSettleLedger()
        ledger.expect(center: center, spanDelta: overview)
        XCTAssertFalse(ledger.classifySettle(center: center, latitudeDelta: overview * 5))
    }

    func testStreamingFollowNeverEatsTheUsersDrag() {
        // THE MYR-222 IDLE SCENARIO: a 1Hz fix stream issues a recenter per
        // fix. Under the old wall-clock window the deadline never lapsed and
        // the drag classified programmatic (the client's "camera snaps back
        // on every gesture"). With tokens: every own settle matches, and the
        // drag matches nothing — regardless of how long the stream ran.
        var ledger = CameraSettleLedger()
        var fix = center
        for _ in 0..<300 { // five minutes of 1Hz follow
            fix = offset(fix, lat: 0.00014, lon: 0.00012)
            ledger.expect(center: fix, spanDelta: overview)
            XCTAssertTrue(ledger.classifySettle(center: fix, latitudeDelta: overview * 1.156))
        }
        // One more write is in flight when the user grabs the map…
        ledger.expect(center: offset(fix, lat: 0.00014), spanDelta: overview)
        // …their drag ends 700m away: user, full stop.
        XCTAssertFalse(ledger.classifySettle(center: offset(fix, lat: 0.0065),
                                             latitudeDelta: overview * 1.156))
    }

    // MARK: duplicates, free passes, clearing

    func testDuplicateOfMatchedSettleIsProgrammatic() {
        // MapKit re-fires `.onEnd` for layout churn at an unchanged camera —
        // same center, ~same OBSERVED span. Not a gesture.
        var ledger = CameraSettleLedger()
        ledger.expect(center: center, spanDelta: overview)
        XCTAssertTrue(ledger.classifySettle(center: center, latitudeDelta: overview * 1.156))
        XCTAssertTrue(ledger.classifySettle(center: center, latitudeDelta: overview * 1.156),
                      "the duplicate re-settle is not the user")
        // But a ZOOM at that same center is — the observed span moved.
        XCTAssertFalse(ledger.classifySettle(center: center, latitudeDelta: overview * 1.156 * 2),
                       "same center, different span = the user zoomed")
    }

    func testFreePassAllowsExactlyOneUnmatchedSettle() {
        // Mount / inset-change / resume re-fits settle at geometry we didn't
        // write — one granted pass each, never accumulating.
        var ledger = CameraSettleLedger()
        ledger.grantFreePass()
        ledger.grantFreePass() // grants never stack
        let layoutSettle = offset(center, lat: 0.004)
        XCTAssertTrue(ledger.classifySettle(center: layoutSettle, latitudeDelta: overview))
        XCTAssertFalse(ledger.classifySettle(center: offset(center, lat: 0.009), latitudeDelta: overview),
                       "the single pass was consumed — the next unmatched settle is the user")
    }

    func testClearDropsEverything() {
        var ledger = CameraSettleLedger()
        ledger.expect(center: center, spanDelta: overview)
        ledger.grantFreePass()
        XCTAssertTrue(ledger.classifySettle(center: center, latitudeDelta: overview))
        ledger.clear()
        XCTAssertFalse(ledger.classifySettle(center: center, latitudeDelta: overview),
                       "after clear nothing matches — not the token, not the duplicate, not a pass")
        XCTAssertFalse(ledger.hasPendingWrites)
    }

    func testCapacityAgesOutStaleExpectations() {
        var ledger = CameraSettleLedger()
        let stale = offset(center, lat: -0.02)
        ledger.expect(center: stale, spanDelta: overview)
        for i in 1...CameraSettleLedger.capacity {
            ledger.expect(center: offset(center, lat: Double(i) * 0.001), spanDelta: overview)
        }
        XCTAssertFalse(ledger.classifySettle(center: stale, latitudeDelta: overview),
                       "an expectation older than the cap cannot launder a settle")
    }
}
