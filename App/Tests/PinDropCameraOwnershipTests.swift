import CoreLocation
import DesignSystem
import MapKit
@testable import MyRoboTaxi
import XCTest

// MARK: - MYR-217 — single camera owner for pin-drop
//
// The regression class these tests exist to kill: FOUR rounds (MYR-213/215/216)
// shipped a pin-drop zoom fix that passed cold-launch probes and regressed on
// the client's real entry path (idle → search → Continue → pinDrop with async
// region updates in flight). Root cause: multiple independent camera writers,
// and a one-shot correction that wrote `span: context.region.span` — the span
// of WHATEVER (possibly stale, wide) settle triggered it. These tests replay
// the REAL interleaving against the single owner and pin two invariants:
//
//   A. every camera write emitted during pin-drop carries the STREET span —
//      a span can never be inherited from a settle context;
//   B. no writer other than the owner (or the user's own gesture) may mutate
//      the camera during pin-drop (`VehicleMapView.cameraWritePermitted`).

@MainActor
final class PinDropCameraOwnershipTests: XCTestCase {

    // The client's live fix (Town & Country Blvd area, Frisco TX) — the same
    // coordinate the empirical probe uses.
    private let fix = CLLocationCoordinate2D(latitude: 33.086114, longitude: -96.851844)
    private let fixture = DriveFixtures.home
    private let viewport = CGSize(width: 393, height: 852)
    private let street = MRTMetrics.pinDropStreetSpanDelta
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func makeController() -> PinDropCameraController {
        PinDropCameraController()
    }

    private func assertStreetSpan(_ write: PinDropCameraController.Write,
                                  _ message: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(write.region.span.latitudeDelta, street, accuracy: 1e-12,
                       message, file: file, line: line)
        XCTAssertEqual(write.region.span.longitudeDelta, street, accuracy: 1e-12,
                       message, file: file, line: line)
    }

    // MARK: invariant B — the ownership permission table

    func testOnlyTheOwnerMayWriteDuringPinDrop() {
        // The regression: ANY legacy writer (onAppear framing, follow tick,
        // follow re-engage, device-fix recenter) mutating the camera while the
        // pin is up. The permission gate must refuse them all.
        XCTAssertFalse(VehicleMapView.cameraWritePermitted(source: .legacyRecenter, isPinDropActive: true),
                       "legacy recenters are subordinated during pin-drop")
        XCTAssertTrue(VehicleMapView.cameraWritePermitted(source: .pinDropOwner, isPinDropActive: true),
                      "the owner holds the camera during pin-drop")
        // And outside pin-drop the owner has no business writing.
        XCTAssertTrue(VehicleMapView.cameraWritePermitted(source: .legacyRecenter, isPinDropActive: false))
        XCTAssertFalse(VehicleMapView.cameraWritePermitted(source: .pinDropOwner, isPinDropActive: false))
    }

    // MARK: invariant A — the REAL entry path never emits a wide write
    //
    // This is the test MYR-216 would have FAILED: the scripted event stream is
    // the client's exact interleaving — entry from search with pre-entry motion
    // still delivering settles at the WIDE span, async fresh fixes landing
    // mid-seat — and EVERY write the owner emits must carry the street span.

    func testRealEntryPathEveryWriteIsStreetSpan() {
        let camera = makeController()
        var writes: [PinDropCameraController.Write] = []

        // 1. Warm entry from search (the `.onChange(isPinDropActive)` seam).
        writes.append(camera.enter(fix: fix, fallbackCenter: fixture, viewportSize: viewport,
                                   animated: true, now: t0))

        // 2. THE KILLER SETTLE (7:41 AM client evidence): a stale settle from
        // pre-entry motion lands inside the write window, still at the WIDE
        // idle/search geometry, glyph nowhere near the fix. MYR-216 responded
        // by writing `span: context.region.span` (0.09 here) — re-asserting
        // the wide span. The owner must refine at the STREET span instead.
        let staleGlyph = CLLocationCoordinate2D(latitude: fix.latitude + 0.012, longitude: fix.longitude - 0.008)
        let outcome1 = camera.cameraSettled(glyphCoordinate: staleGlyph,
                                            cameraCenter: fixture,
                                            cameraLatitudeDelta: 0.09,
                                            now: t0.addingTimeInterval(0.2))
        guard case .refine(let refine1) = outcome1 else {
            return XCTFail("a stale wide mid-seat settle must be refined, got \(outcome1)")
        }
        writes.append(refine1)

        // 3. A fresh fix from `enterPinDrop()`'s `refresh()` lands async.
        let freshFix = CLLocationCoordinate2D(latitude: fix.latitude + 0.0002, longitude: fix.longitude - 0.0001)
        if let reseat = camera.fixChanged(freshFix, now: t0.addingTimeInterval(0.5)) {
            writes.append(reseat)
        } else {
            XCTFail("a fresh fix during seating re-seats")
        }

        // 4. The owner's write settles at street geometry, glyph on the fix.
        let visibleLat = PinDropCameraController.visibleLatitudeDelta(
            requestedSpanDelta: street, latitude: freshFix.latitude, viewportSize: viewport)
        let outcome2 = camera.cameraSettled(glyphCoordinate: freshFix,
                                            cameraCenter: writes.last!.region.center,
                                            cameraLatitudeDelta: visibleLat,
                                            now: t0.addingTimeInterval(1.0))
        XCTAssertEqual(outcome2, .seated, "aligned street-geometry settle finishes seating")

        // THE INVARIANT: every single write carried the street span.
        for (i, write) in writes.enumerated() {
            assertStreetSpan(write, "write #\(i) must be street span — a wide write is the four-round regression")
        }
    }

    func testStaleWideSettleRefinesToTheAnalyticStreetTarget() {
        // A wide-geometry settle must NOT be trusted for delta math (deltas
        // measured at the wrong zoom) — the owner re-issues the analytic
        // street-span target, whose center seats the fix under the glyph.
        let camera = makeController()
        let entry = camera.enter(fix: fix, fallbackCenter: fixture, viewportSize: viewport,
                                 animated: true, now: t0)
        let staleGlyph = CLLocationCoordinate2D(latitude: fix.latitude + 0.02, longitude: fix.longitude)
        let outcome = camera.cameraSettled(glyphCoordinate: staleGlyph,
                                           cameraCenter: fixture,
                                           cameraLatitudeDelta: 0.06,
                                           now: t0.addingTimeInterval(0.1))
        guard case .refine(let write) = outcome else { return XCTFail("expected refine") }
        assertStreetSpan(write, "refinement from a wide settle is street span")
        XCTAssertEqual(write.region.center.latitude, entry.region.center.latitude, accuracy: 1e-9,
                       "wide-geometry settle re-issues the analytic target, it never delta-shifts")
        XCTAssertEqual(write.region.center.longitude, entry.region.center.longitude, accuracy: 1e-9)
    }

    func testStreetGeometryResidualIsDeltaShiftedExactly() {
        // Once the geometry is street-scale, the observed (fix − glyph)
        // residual shifts the center exactly (MapProxy ground truth beats the
        // analytic estimate) — still at the street span.
        let camera = makeController()
        let entry = camera.enter(fix: fix, fallbackCenter: fixture, viewportSize: viewport,
                                 animated: true, now: t0)
        let visibleLat = PinDropCameraController.visibleLatitudeDelta(
            requestedSpanDelta: street, latitude: fix.latitude, viewportSize: viewport)
        // Glyph reads 30-ish meters south-east of the fix at street geometry.
        let glyph = CLLocationCoordinate2D(latitude: fix.latitude - 0.0003, longitude: fix.longitude + 0.0002)
        let outcome = camera.cameraSettled(glyphCoordinate: glyph,
                                           cameraCenter: entry.region.center,
                                           cameraLatitudeDelta: visibleLat,
                                           now: t0.addingTimeInterval(0.5))
        guard case .refine(let write) = outcome else { return XCTFail("expected refine") }
        assertStreetSpan(write, "street-geometry refinement is street span")
        XCTAssertEqual(write.region.center.latitude,
                       entry.region.center.latitude + (fix.latitude - glyph.latitude), accuracy: 1e-12)
        XCTAssertEqual(write.region.center.longitude,
                       entry.region.center.longitude + (fix.longitude - glyph.longitude), accuracy: 1e-12)
    }

    func testInsetStretchedStreetSettleStillDeltaShifts() {
        // EMPIRICAL (MYR-217 probe round 1): with the pin-drop sheet's 280pt
        // bottom inset, MapKit shows ~0.010° latitude for the 0.004° request —
        // wider than any analytic estimate. That settle is still OUR street
        // geometry and must be delta-shifted; classifying it "wide" re-issued
        // the same analytic target until the budget died with the pin off the
        // dot. The classifier is a generous factor of the REQUESTED span.
        let camera = makeController()
        let entry = camera.enter(fix: fix, fallbackCenter: fixture, viewportSize: viewport,
                                 animated: true, now: t0)
        let glyph = CLLocationCoordinate2D(latitude: fix.latitude - 0.0014, longitude: fix.longitude)
        let outcome = camera.cameraSettled(glyphCoordinate: glyph,
                                           cameraCenter: entry.region.center,
                                           cameraLatitudeDelta: 0.0104, // inset-stretched street settle
                                           now: t0.addingTimeInterval(0.5))
        guard case .refine(let write) = outcome else { return XCTFail("expected refine") }
        assertStreetSpan(write, "inset-stretched refinement is still street span")
        XCTAssertEqual(write.region.center.latitude,
                       entry.region.center.latitude + (fix.latitude - glyph.latitude), accuracy: 1e-12,
                       "street-scale settle delta-shifts (never re-issues the analytic guess)")
    }

    // MARK: user takeover — the owner never fights a gesture

    func testLateSettleIsTheUsersAndOwnerStandsDown() {
        let camera = makeController()
        _ = camera.enter(fix: fix, fallbackCenter: fixture, viewportSize: viewport,
                         animated: true, now: t0)
        // A settle OUTSIDE the write window is a user drag/zoom.
        let outcome = camera.cameraSettled(glyphCoordinate: fix, cameraCenter: fix,
                                           cameraLatitudeDelta: street,
                                           now: t0.addingTimeInterval(5))
        XCTAssertEqual(outcome, .userTookOver)
        XCTAssertEqual(camera.phase, .userControlled)
        // From here the owner NEVER writes again this entry — not even for a
        // fresh device fix (the "no fighting" rule).
        XCTAssertNil(camera.fixChanged(fix, now: t0.addingTimeInterval(6)),
                     "a user-held camera is never re-seated")
        // Later drags just report (label tracks the pin).
        let drag = camera.cameraSettled(glyphCoordinate: fixture, cameraCenter: fixture,
                                        cameraLatitudeDelta: 0.002,
                                        now: t0.addingTimeInterval(8))
        XCTAssertEqual(drag, .report)
    }

    func testUserDragAfterSeatingTakesOver() {
        let camera = makeController()
        let entry = camera.enter(fix: fix, fallbackCenter: fixture, viewportSize: viewport,
                                 animated: true, now: t0)
        let visibleLat = PinDropCameraController.visibleLatitudeDelta(
            requestedSpanDelta: street, latitude: fix.latitude, viewportSize: viewport)
        XCTAssertEqual(camera.cameraSettled(glyphCoordinate: fix, cameraCenter: entry.region.center,
                                            cameraLatitudeDelta: visibleLat,
                                            now: t0.addingTimeInterval(0.4)),
                       .seated)
        // A settle long after the last owner write = the user moved the map.
        let outcome = camera.cameraSettled(glyphCoordinate: fixture, cameraCenter: fixture,
                                           cameraLatitudeDelta: street,
                                           now: t0.addingTimeInterval(10))
        XCTAssertEqual(outcome, .userTookOver)
        XCTAssertNil(camera.fixChanged(fix, now: t0.addingTimeInterval(11)))
    }

    // MARK: seating bounds

    func testRefinementBudgetIsBoundedThenAccepts() {
        let camera = makeController()
        _ = camera.enter(fix: fix, fallbackCenter: fixture, viewportSize: viewport,
                         animated: true, now: t0)
        let visibleLat = PinDropCameraController.visibleLatitudeDelta(
            requestedSpanDelta: street, latitude: fix.latitude, viewportSize: viewport)
        let stubbornGlyph = CLLocationCoordinate2D(latitude: fix.latitude + 0.001, longitude: fix.longitude)
        var refinements = 0
        var now = t0.addingTimeInterval(0.2)
        for _ in 0..<10 {
            let outcome = camera.cameraSettled(glyphCoordinate: stubbornGlyph,
                                               cameraCenter: fixture,
                                               cameraLatitudeDelta: visibleLat, now: now)
            if case .refine(let write) = outcome {
                refinements += 1
                assertStreetSpan(write, "bounded refinements stay street span")
                now = now.addingTimeInterval(0.3)
            } else {
                XCTAssertEqual(outcome, .seated, "budget exhausted → accept (MapProxy keeps the pickup honest)")
                break
            }
        }
        XCTAssertEqual(refinements, 3, "seating never loops — exactly the per-seat budget")
        XCTAssertEqual(camera.phase, .settled)
    }

    // MARK: no-fix entry (sim / unauthorized) — MYR-215 framing preserved

    func testNoFixEntryFramesTheFallbackCenterAtStreetSpan() {
        let camera = makeController()
        let write = camera.enter(fix: nil, fallbackCenter: fixture, viewportSize: viewport,
                                 animated: false, now: t0)
        assertStreetSpan(write, "sim entry is street span (MYR-215 client-approved deviation)")
        XCTAssertEqual(write.region.center.latitude, fixture.latitude, accuracy: 1e-12,
                       "no fix → the fallback center, byte-identical to the MYR-215 cold recenter")
        XCTAssertEqual(write.region.center.longitude, fixture.longitude, accuracy: 1e-12)
        XCTAssertFalse(write.animated)
        // First settle finishes seating — there is no fix to converge on.
        XCTAssertEqual(camera.cameraSettled(glyphCoordinate: fixture, cameraCenter: fixture,
                                            cameraLatitudeDelta: street,
                                            now: t0.addingTimeInterval(0.3)),
                       .seated)
    }

    // MARK: entry geometry (the analytic fix-under-glyph framing)

    func testEntryRegionPutsTheFixUnderTheGlyphNotTheOpticalCenter() {
        let region = PinDropCameraController.entryRegion(
            fix: fix, fallbackCenter: fixture, spanDelta: street,
            glyphScreenFraction: Double(MRTMetrics.ridePinDropGlyphScreenFraction),
            viewportSize: viewport)
        // The glyph sits ABOVE the optical center (fraction 0.36 < 0.5), so the
        // camera center goes SOUTH of the fix — never centered ON the fix (the
        // MYR-216 defect: fix at optical center put the pickup a block south).
        XCTAssertLessThan(region.center.latitude, fix.latitude,
                          "camera center is south of the fix so the glyph (above center) reads the fix")
        XCTAssertEqual(region.center.longitude, fix.longitude, accuracy: 1e-12,
                       "glyph is horizontally centered — longitude matches the fix")
        // And the offset is exactly the glyph's fraction of the VISIBLE span.
        let visibleLat = PinDropCameraController.visibleLatitudeDelta(
            requestedSpanDelta: street, latitude: fix.latitude, viewportSize: viewport)
        let expected = fix.latitude - (0.5 - Double(MRTMetrics.ridePinDropGlyphScreenFraction)) * visibleLat
        XCTAssertEqual(region.center.latitude, expected, accuracy: 1e-12)
    }

    func testVisibleLatitudeSpanAccountsForPortraitAspect() {
        // In a portrait viewport the longitude edge binds, so the shown
        // latitude span stretches by aspect × cos(latitude) — the reason the
        // MYR-216 optical-center framing missed by a full block.
        let visible = PinDropCameraController.visibleLatitudeDelta(
            requestedSpanDelta: street, latitude: fix.latitude, viewportSize: viewport)
        XCTAssertGreaterThan(visible, street, "portrait shows more latitude than requested")
        let expected = street * cos(fix.latitude * .pi / 180) * Double(viewport.height / viewport.width)
        XCTAssertEqual(visible, expected, accuracy: 1e-12)
        // Degenerate viewport → the requested span (never zero/NaN).
        XCTAssertEqual(PinDropCameraController.visibleLatitudeDelta(
            requestedSpanDelta: street, latitude: fix.latitude, viewportSize: .zero), street)
    }

    // MARK: exit releases the camera

    func testExitReturnsToInactiveAndSettlesJustReport() {
        let camera = makeController()
        _ = camera.enter(fix: fix, fallbackCenter: fixture, viewportSize: viewport,
                         animated: true, now: t0)
        camera.exit()
        XCTAssertEqual(camera.phase, .inactive)
        XCTAssertNil(camera.fixChanged(fix, now: t0.addingTimeInterval(1)))
        XCTAssertEqual(camera.cameraSettled(glyphCoordinate: fix, cameraCenter: fix,
                                            cameraLatitudeDelta: street,
                                            now: t0.addingTimeInterval(1)),
                       .report)
    }
}

// MARK: - The full REAL-PATH state walk (idle → search → choose → Continue →
// pinDrop) — the flow-level twin of the camera test above, driving the same
// `SharedViewerState` methods the taps (and the `pinDropRealPath` DEBUG scene)
// call, so the unit suite exercises the client's sequence, not a cold seed.

@MainActor
final class PinDropRealPathFlowTests: XCTestCase {

    func testIdleToSearchToContinueLandsOnPinDropForReview() {
        let state = SharedViewerState() // simulated seams
        XCTAssertEqual(state.sheetPhase, .idle)

        state.sheetPhase = .search // "Where to?" tap
        state.chooseDestination(RideRequestFixtures.recentPlaces[1]) // result row tap
        XCTAssertEqual(state.sheetPhase, .search, "choose-then-proceed: no auto-advance (MYR-215)")

        state.proceedFromSearch() // the Continue CTA
        XCTAssertEqual(state.sheetPhase, .pinDrop(returnTo: .review),
                       "no pickup set → Continue routes through pin-drop")
    }

    func testRealPathSceneSeedsIdleOnly() {
        // The probe scene must NOT cold-seed pinDrop — booting to idle and
        // walking the transitions is its entire reason to exist.
        let viewer = SharedViewerState()
        DebugScene.pinDropRealPath.apply(viewer: viewer, service: SimulatedRideRequestService())
        XCTAssertEqual(viewer.sheetPhase, .idle)
        XCTAssertNil(viewer.draftDestination)
        XCTAssertTrue(DebugScene.pinDropRealPath.replaysRealPinDropPath)
        XCTAssertFalse(DebugScene.pinDrop.replaysRealPinDropPath)
    }
}
