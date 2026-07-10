import CoreLocation
import DesignSystem
import MapKit
@testable import MyRoboTaxi
import XCTest

// MARK: - MYR-217/MYR-222 — single camera owner for pin-drop
//
// The regression class these tests exist to kill: FOUR rounds (MYR-213/215/216)
// shipped a pin-drop zoom fix that passed cold-launch probes and regressed on
// the client's real entry path (idle → search → Continue → pinDrop with async
// region updates in flight). Root cause: multiple independent camera writers,
// and a one-shot correction that wrote `span: context.region.span` — the span
// of WHATEVER (possibly stale, wide) settle triggered it.
//
// MYR-222 added the FIFTH round's lesson: all prior verification used a STATIC
// simulated fix, while real devices STREAM fixes (~1Hz). The MYR-217 owner
// re-armed a full re-seat on every fix and attributed settles by a wall-clock
// window that a 1Hz stream never lets lapse — a live feedback loop (the pin
// "bounces back and forth", drags snap back, backgrounding "heals" it by
// starving the loop). These tests replay the STREAMING interleavings and pin
// the MYR-222 invariants on top of MYR-217's:
//
//   A. every camera write emitted during pin-drop carries the STREET span —
//      a span can never be inherited from a settle context;
//   B. no writer other than the owner (or the user's own gesture) may mutate
//      the camera during pin-drop (`VehicleMapView.cameraWritePermitted`);
//   C. ONE seating sequence per ENTRY — after `.settled`, N streaming fixes
//      produce ZERO writes; the per-entry budget bounds every pass;
//   D. the user wins immediately (`userGestureBegan`) and permanently
//      (`.userControlled` → zero writes) — with NO wall clock anywhere,
//      classification cannot be starved by fix rate;
//   E. background/foreground is a designed no-op (settled/userControlled
//      survive untouched); a suspend mid-seat resumes with ONE clean re-seat.

@MainActor
final class PinDropCameraOwnershipTests: XCTestCase {

    // The client's live fix (Town & Country Blvd area, Frisco TX) — the same
    // coordinate the empirical probe uses.
    private let fix = CLLocationCoordinate2D(latitude: 33.086114, longitude: -96.851844)
    private let fixture = DriveFixtures.home
    private let viewport = CGSize(width: 393, height: 852)
    private let street = MRTMetrics.pinDropStreetSpanDelta

    private func makeController() -> PinDropCameraController {
        PinDropCameraController()
    }

    /// The observed latitude span of the owner's own street-span settle
    /// (aspect-stretched — see `visibleLatitudeDelta`).
    private func ownSettleSpan(at latitude: Double) -> Double {
        PinDropCameraController.visibleLatitudeDelta(
            requestedSpanDelta: street, latitude: latitude, viewportSize: viewport)
    }

    /// Drive the controller through a converged seat: entry write, then its
    /// settle with the glyph ON the fix. Returns the entry write.
    @discardableResult
    private func seat(_ camera: PinDropCameraController,
                      fix: CLLocationCoordinate2D,
                      file: StaticString = #filePath, line: UInt = #line) -> PinDropCameraController.Write {
        let entry = camera.enter(fix: fix, fallbackCenter: fixture, viewportSize: viewport, animated: true)
        let outcome = camera.cameraSettled(glyphCoordinate: fix,
                                           cameraCenter: entry.region.center,
                                           cameraLatitudeDelta: ownSettleSpan(at: fix.latitude))
        XCTAssertEqual(outcome, .seated, "aligned settle of the entry write finishes seating", file: file, line: line)
        XCTAssertEqual(camera.phase, .settled, file: file, line: line)
        return entry
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
    // The scripted event stream is the client's exact interleaving — entry
    // from search with pre-entry motion still delivering settles at the WIDE
    // span, an async fresh fix landing mid-seat — and EVERY write the owner
    // emits must carry the street span.

    func testRealEntryPathEveryWriteIsStreetSpan() {
        let camera = makeController()
        var writes: [PinDropCameraController.Write] = []

        // 1. Warm entry from search (the `.onChange(isPinDropActive)` seam).
        writes.append(camera.enter(fix: fix, fallbackCenter: fixture, viewportSize: viewport, animated: true))

        // 2. THE KILLER SETTLE (7:41 AM client evidence): a stale settle from
        // pre-entry motion lands mid-seat, still at the WIDE idle/search
        // geometry, at a center the owner never wrote. MYR-216 responded by
        // writing `span: context.region.span` (0.09 here) — re-asserting the
        // wide span. The owner must refine at the STREET span instead.
        let staleGlyph = CLLocationCoordinate2D(latitude: fix.latitude + 0.012, longitude: fix.longitude - 0.008)
        let outcome1 = camera.cameraSettled(glyphCoordinate: staleGlyph,
                                            cameraCenter: fixture,
                                            cameraLatitudeDelta: 0.09)
        guard case .refine(let refine1) = outcome1 else {
            return XCTFail("a stale wide mid-seat settle must be refined, got \(outcome1)")
        }
        writes.append(refine1)

        // 3. A fresh fix from `enterPinDrop()`'s `refresh()` lands async while
        // still seating — it re-aims the in-flight pass (budget-bounded).
        let freshFix = CLLocationCoordinate2D(latitude: fix.latitude + 0.0002, longitude: fix.longitude - 0.0001)
        if let reseat = camera.fixChanged(freshFix) {
            writes.append(reseat)
        } else {
            XCTFail("a fresh fix during seating re-aims the in-flight pass")
        }

        // 4. The owner's write settles at street geometry, glyph on the fix.
        let outcome2 = camera.cameraSettled(glyphCoordinate: freshFix,
                                            cameraCenter: writes.last!.region.center,
                                            cameraLatitudeDelta: ownSettleSpan(at: freshFix.latitude))
        XCTAssertEqual(outcome2, .seated, "aligned street-geometry settle finishes seating")

        // THE INVARIANT: every single write carried the street span.
        for (i, write) in writes.enumerated() {
            assertStreetSpan(write, "write #\(i) must be street span — a wide write is the four-round regression")
        }
    }

    func testStaleWideSettleRefinesToTheAnalyticStreetTarget() {
        // A settle the owner didn't write, at wide geometry, must NOT be
        // trusted for delta math (deltas measured at the wrong zoom) — the
        // owner re-issues the analytic street-span target, whose center seats
        // the fix under the glyph.
        let camera = makeController()
        let entry = camera.enter(fix: fix, fallbackCenter: fixture, viewportSize: viewport, animated: true)
        let staleGlyph = CLLocationCoordinate2D(latitude: fix.latitude + 0.02, longitude: fix.longitude)
        let outcome = camera.cameraSettled(glyphCoordinate: staleGlyph,
                                           cameraCenter: fixture,
                                           cameraLatitudeDelta: 0.06)
        guard case .refine(let write) = outcome else { return XCTFail("expected refine") }
        assertStreetSpan(write, "refinement from a wide settle is street span")
        XCTAssertEqual(write.region.center.latitude, entry.region.center.latitude, accuracy: 1e-9,
                       "unrecognized-geometry settle re-issues the analytic target, it never delta-shifts")
        XCTAssertEqual(write.region.center.longitude, entry.region.center.longitude, accuracy: 1e-9)
    }

    func testStreetGeometryResidualIsDeltaShiftedExactly() {
        // The owner's OWN settle (token-matched: the settle center IS the
        // entry write's target): the observed (fix − glyph) residual shifts
        // the center exactly (MapProxy ground truth beats the analytic
        // estimate) — still at the street span.
        let camera = makeController()
        let entry = camera.enter(fix: fix, fallbackCenter: fixture, viewportSize: viewport, animated: true)
        // Glyph reads 30-ish meters south-east of the fix at street geometry.
        let glyph = CLLocationCoordinate2D(latitude: fix.latitude - 0.0003, longitude: fix.longitude + 0.0002)
        let outcome = camera.cameraSettled(glyphCoordinate: glyph,
                                           cameraCenter: entry.region.center,
                                           cameraLatitudeDelta: ownSettleSpan(at: fix.latitude))
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
        // wider than any analytic estimate. That settle is still OUR write
        // (token center match; 2.6× is inside the ledger's stretch window) and
        // must be delta-shifted; classifying it foreign re-issued the same
        // analytic target until the budget died with the pin off the dot.
        let camera = makeController()
        let entry = camera.enter(fix: fix, fallbackCenter: fixture, viewportSize: viewport, animated: true)
        let glyph = CLLocationCoordinate2D(latitude: fix.latitude - 0.0014, longitude: fix.longitude)
        let outcome = camera.cameraSettled(glyphCoordinate: glyph,
                                           cameraCenter: entry.region.center,
                                           cameraLatitudeDelta: 0.0104) // inset-stretched street settle
        guard case .refine(let write) = outcome else { return XCTFail("expected refine") }
        assertStreetSpan(write, "inset-stretched refinement is still street span")
        XCTAssertEqual(write.region.center.latitude,
                       entry.region.center.latitude + (fix.latitude - glyph.latitude), accuracy: 1e-12,
                       "own street-scale settle delta-shifts (never re-issues the analytic guess)")
    }

    // MARK: invariant C (MYR-222) — seat ONCE per entry; streaming fixes never write

    func testStreamingFixesAfterSeatedNeverWrite() {
        // THE CLIENT BUG: a 1Hz GPS stream re-armed a full re-seat from
        // `.settled` on every fix — two opposing writes per second, forever
        // ("the pin bounces back and forth"). After the one seating pass,
        // N fixes must produce ZERO writes: they move the blue dot only.
        let camera = makeController()
        seat(camera, fix: fix)
        var moving = fix
        for tick in 0..<120 { // two minutes of 1Hz stream
            moving.latitude += 0.00014 // ~15 m/s northward, the probe's speed
            moving.longitude += 0.00012
            XCTAssertNil(camera.fixChanged(moving),
                         "fix #\(tick) after settled must not write — fixes are blue-dot-only once seated")
        }
        XCTAssertEqual(camera.phase, .settled, "the seat outlives any number of fixes")
    }

    func testMidSeatFixReaimsAreBudgetBounded() {
        // Fixes landing DURING the seating pass may re-aim it, but they draw
        // from the same per-entry budget — a stream can never keep a pass
        // alive indefinitely.
        let camera = makeController()
        _ = camera.enter(fix: fix, fallbackCenter: fixture, viewportSize: viewport, animated: true)
        var moving = fix
        var writes = 0
        for _ in 0..<10 {
            moving.latitude += 0.00014
            if camera.fixChanged(moving) != nil { writes += 1 }
        }
        XCTAssertEqual(writes, 3, "mid-seat re-aims stop at the per-entry budget")
        XCTAssertEqual(camera.phase, .seating, "still seating — the next settle completes the pass")
        // Budget exhausted → the next settle accepts even unaligned.
        let outcome = camera.cameraSettled(glyphCoordinate: fixture,
                                           cameraCenter: fixture,
                                           cameraLatitudeDelta: ownSettleSpan(at: fix.latitude))
        XCTAssertEqual(outcome, .seated, "budget exhausted → accept (MapProxy keeps the pickup honest)")
    }

    func testReEntryReseatsExactlyOnce() {
        // Leaving pin-drop and entering again is a NEW entry: exactly one new
        // seating pass, then done again.
        let camera = makeController()
        seat(camera, fix: fix)
        camera.exit()
        XCTAssertEqual(camera.phase, .inactive)

        let secondFix = CLLocationCoordinate2D(latitude: fix.latitude + 0.01, longitude: fix.longitude + 0.01)
        let entry2 = camera.enter(fix: secondFix, fallbackCenter: fixture, viewportSize: viewport, animated: true)
        assertStreetSpan(entry2, "re-entry write is street span")
        XCTAssertEqual(camera.phase, .seating, "re-entry arms exactly one fresh pass")
        XCTAssertEqual(camera.cameraSettled(glyphCoordinate: secondFix,
                                            cameraCenter: entry2.region.center,
                                            cameraLatitudeDelta: ownSettleSpan(at: secondFix.latitude)),
                       .seated)
        // …and the stream is blue-dot-only again.
        XCTAssertNil(camera.fixChanged(fix))
    }

    // MARK: invariant D (MYR-222) — the user wins immediately and permanently

    func testUserGestureWinsImmediatelyEvenMidSeating() {
        // The gesture recognizer path: the user's finger lands mid-seat — the
        // owner stands down NOW, without budget-fighting or settle inference.
        let camera = makeController()
        _ = camera.enter(fix: fix, fallbackCenter: fixture, viewportSize: viewport, animated: true)
        camera.userGestureBegan()
        XCTAssertEqual(camera.phase, .userControlled)
        XCTAssertNil(camera.fixChanged(fix), "a user-held camera is never re-seated")
        // Later settles just report (label keeps tracking the pin via MapProxy).
        XCTAssertEqual(camera.cameraSettled(glyphCoordinate: fixture, cameraCenter: fixture,
                                            cameraLatitudeDelta: 0.002),
                       .report)
    }

    func testUnmatchedSettleAfterSeatingIsTheUsersAndOwnerStandsDown() {
        // The settle-classification path (belt to the recognizer's braces): a
        // settle after `.settled` that matches NO outstanding owner write is
        // the user's drag — there is no wall-clock window for a fix stream to
        // hold open (the MYR-222 unreachable-`.userControlled` bug).
        let camera = makeController()
        seat(camera, fix: fix)
        let outcome = camera.cameraSettled(glyphCoordinate: fixture, cameraCenter: fixture,
                                           cameraLatitudeDelta: street)
        XCTAssertEqual(outcome, .userTookOver)
        XCTAssertEqual(camera.phase, .userControlled)
        XCTAssertNil(camera.fixChanged(fix), "a user-held camera is never re-seated")
        // Later drags just report (label tracks the pin).
        XCTAssertEqual(camera.cameraSettled(glyphCoordinate: fixture, cameraCenter: fixture,
                                            cameraLatitudeDelta: 0.002),
                       .report)
    }

    func testStreamingFixesDuringUserControlledNeverWrite() {
        let camera = makeController()
        seat(camera, fix: fix)
        camera.userGestureBegan()
        var moving = fix
        for tick in 0..<120 {
            moving.latitude += 0.00014
            XCTAssertNil(camera.fixChanged(moving),
                         "fix #\(tick) during userControlled must not write — the user won for this entry")
        }
        XCTAssertEqual(camera.phase, .userControlled)
    }

    func testOwnDuplicateSettleAfterSeatingIsNotTheUser() {
        // MapKit re-fires `.onEnd` for layout churn at an unchanged camera —
        // a duplicate of the settle that finished seating must NOT flip the
        // phase to `.userControlled` (that would silently disable re-seat
        // paths the user never asked for).
        let camera = makeController()
        let entry = camera.enter(fix: fix, fallbackCenter: fixture, viewportSize: viewport, animated: true)
        let span = ownSettleSpan(at: fix.latitude)
        XCTAssertEqual(camera.cameraSettled(glyphCoordinate: fix,
                                            cameraCenter: entry.region.center,
                                            cameraLatitudeDelta: span),
                       .seated)
        let duplicate = camera.cameraSettled(glyphCoordinate: fix,
                                             cameraCenter: entry.region.center,
                                             cameraLatitudeDelta: span)
        XCTAssertEqual(duplicate, .report, "a duplicate of our own settle just reports")
        XCTAssertEqual(camera.phase, .settled)
    }

    // MARK: invariant E (MYR-222) — background/foreground safe BY DESIGN

    func testBackgroundForegroundAfterSettledIsANoOp() {
        // Pre-fix, backgrounding was the accidental CURE (it starved the
        // wall-clock loop). Post-fix it must be a designed no-op: the seat
        // survives, no re-seat, no writes.
        let camera = makeController()
        seat(camera, fix: fix)
        camera.sceneWillBackground()
        XCTAssertEqual(camera.phase, .settled)
        XCTAssertNil(camera.sceneDidForeground(), "resume after a finished seat never writes")
        XCTAssertNil(camera.fixChanged(fix), "…and the stream stays blue-dot-only")
    }

    func testBackgroundForegroundDuringUserControlledIsANoOp() {
        let camera = makeController()
        seat(camera, fix: fix)
        camera.userGestureBegan()
        camera.sceneWillBackground()
        XCTAssertNil(camera.sceneDidForeground())
        XCTAssertEqual(camera.phase, .userControlled, "the user's takeover survives the round-trip")
    }

    func testBackgroundMidSeatingResumesWithOneCleanReseat() {
        // Suspension interrupts the pass (its settles never arrive). Resume
        // re-arms ONE clean re-seat — fresh budget, un-animated — and the pass
        // completes normally. Never a loop.
        let camera = makeController()
        _ = camera.enter(fix: fix, fallbackCenter: fixture, viewportSize: viewport, animated: true)
        camera.sceneWillBackground()
        XCTAssertEqual(camera.phase, .seating)

        guard let reseat = camera.sceneDidForeground() else {
            return XCTFail("resume mid-seat re-arms a single re-seat")
        }
        assertStreetSpan(reseat, "the re-seat is street span")
        XCTAssertFalse(reseat.animated, "resume framing appears in place — no camera fly-in")
        XCTAssertEqual(camera.cameraSettled(glyphCoordinate: fix,
                                            cameraCenter: reseat.region.center,
                                            cameraLatitudeDelta: ownSettleSpan(at: fix.latitude)),
                       .seated)
        // And done: another round-trip is now the settled no-op.
        camera.sceneWillBackground()
        XCTAssertNil(camera.sceneDidForeground())
    }

    // MARK: seating bounds

    func testRefinementBudgetIsBoundedThenAccepts() {
        // A glyph that stubbornly never aligns (hard camera constraint) —
        // refinements stop at the per-entry budget, then accept.
        let camera = makeController()
        var lastWrite = camera.enter(fix: fix, fallbackCenter: fixture, viewportSize: viewport, animated: true)
        let stubbornGlyph = CLLocationCoordinate2D(latitude: fix.latitude + 0.001, longitude: fix.longitude)
        var refinements = 0
        for _ in 0..<10 {
            let outcome = camera.cameraSettled(glyphCoordinate: stubbornGlyph,
                                               cameraCenter: lastWrite.region.center,
                                               cameraLatitudeDelta: ownSettleSpan(at: fix.latitude))
            if case .refine(let write) = outcome {
                refinements += 1
                assertStreetSpan(write, "bounded refinements stay street span")
                lastWrite = write
            } else {
                XCTAssertEqual(outcome, .seated, "budget exhausted → accept (MapProxy keeps the pickup honest)")
                break
            }
        }
        XCTAssertEqual(refinements, 3, "seating never loops — exactly the per-entry budget")
        XCTAssertEqual(camera.phase, .settled)
    }

    // MARK: no-fix entry (sim / unauthorized) — MYR-215 framing preserved

    func testNoFixEntryFramesTheFallbackCenterAtStreetSpan() {
        let camera = makeController()
        let write = camera.enter(fix: nil, fallbackCenter: fixture, viewportSize: viewport, animated: false)
        assertStreetSpan(write, "sim entry is street span (MYR-215 client-approved deviation)")
        XCTAssertEqual(write.region.center.latitude, fixture.latitude, accuracy: 1e-12,
                       "no fix → the fallback center, byte-identical to the MYR-215 cold recenter")
        XCTAssertEqual(write.region.center.longitude, fixture.longitude, accuracy: 1e-12)
        XCTAssertFalse(write.animated)
        // First settle finishes seating — there is no fix to converge on.
        XCTAssertEqual(camera.cameraSettled(glyphCoordinate: fixture, cameraCenter: fixture,
                                            cameraLatitudeDelta: street),
                       .seated)
    }

    func testLateFirstFixCompletesTheEntrySeatOnce() {
        // A live entry can beat the FIRST CoreLocation fix (cold authorize).
        // The fallback framing settles, and the first fix to arrive completes
        // the entry's one real seat — once. Fix #2 onward is blue-dot-only.
        let camera = makeController()
        _ = camera.enter(fix: nil, fallbackCenter: fixture, viewportSize: viewport, animated: false)
        XCTAssertEqual(camera.cameraSettled(glyphCoordinate: fixture, cameraCenter: fixture,
                                            cameraLatitudeDelta: street),
                       .seated, "fallback framing settles without a fix")

        guard let lateSeat = camera.fixChanged(fix) else {
            return XCTFail("the FIRST fix completes the entry's real seat")
        }
        assertStreetSpan(lateSeat, "the late seat is street span")
        XCTAssertEqual(camera.cameraSettled(glyphCoordinate: fix,
                                            cameraCenter: lateSeat.region.center,
                                            cameraLatitudeDelta: ownSettleSpan(at: fix.latitude)),
                       .seated)
        // Once seated on a fix, the entry is done for good.
        var moving = fix
        for _ in 0..<30 {
            moving.latitude += 0.00014
            XCTAssertNil(camera.fixChanged(moving), "fixes after the late seat are blue-dot-only")
        }
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
        _ = camera.enter(fix: fix, fallbackCenter: fixture, viewportSize: viewport, animated: true)
        camera.exit()
        XCTAssertEqual(camera.phase, .inactive)
        XCTAssertNil(camera.fixChanged(fix))
        XCTAssertEqual(camera.cameraSettled(glyphCoordinate: fix, cameraCenter: fix,
                                            cameraLatitudeDelta: street),
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
