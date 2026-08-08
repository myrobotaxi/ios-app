import CoreLocation
import DesignSystem
import MapKit
@testable import MyRoboTaxi
import XCTest

// MARK: - MYR-177 / MYR-460 — the tracking camera's two frames
//
// MYR-177 pinned the LEG FIT: frame the active leg, re-fit only on a leg flip or
// when the car leaves the frame, never per fix. MYR-460 keeps the ownership
// discipline verbatim (single owner, gesture dethrones, recenter re-engages,
// token-ledger settle classification) and changes WHAT the owner frames: the
// resting frame of a ride is now the CAR, and the leg fit is what we show when
// there is no car position to follow.
//
// The suites split on that: `TrackingCameraFitTests` drives the no-fix path,
// which is the only way the leg fit is now reachable, and
// `TrackingFollowCameraTests` drives the ride.

final class TrackingLegTests: XCTestCase {
    func testLegDerivedFromProgressVsPickupCut() {
        XCTAssertEqual(TrackingLeg.forProgress(0.05, pickupCut: 0.16), .toPickup)
        XCTAssertEqual(TrackingLeg.forProgress(0.16, pickupCut: 0.16), .inRide, "at the cut, we've reached pickup")
        XCTAssertEqual(TrackingLeg.forProgress(0.6, pickupCut: 0.16), .inRide)
    }

    // MYR-234 — the polyline/pin active/inactive split reads off this one value.
    func testActiveLegFollowsPhase() {
        XCTAssertTrue(TrackingLeg.toPickup.isLeg1Active, "heading to pickup → leg 1 (car→pickup) is the active route")
        XCTAssertFalse(TrackingLeg.inRide.isLeg1Active, "in the ride → leg 2 (pickup→destination) is the active route, leg 1 subdued")
    }
}

@MainActor
final class TrackingCameraFitTests: XCTestCase {

    private let car = CLLocationCoordinate2D(latitude: 37.7965, longitude: -122.4079)
    private let pickup = CLLocationCoordinate2D(latitude: 37.7899, longitude: -122.3969)
    private let destination = CLLocationCoordinate2D(latitude: 37.6213, longitude: -122.3790)

    private func region(containing coords: [CLLocationCoordinate2D], _ r: MKCoordinateRegion, file: StaticString = #filePath, line: UInt = #line) {
        let minLat = r.center.latitude - r.span.latitudeDelta / 2
        let maxLat = r.center.latitude + r.span.latitudeDelta / 2
        let minLon = r.center.longitude - r.span.longitudeDelta / 2
        let maxLon = r.center.longitude + r.span.longitudeDelta / 2
        for c in coords {
            XCTAssertTrue(c.latitude >= minLat - 1e-9 && c.latitude <= maxLat + 1e-9, "lat out of frame", file: file, line: line)
            XCTAssertTrue(c.longitude >= minLon - 1e-9 && c.longitude <= maxLon + 1e-9, "lon out of frame", file: file, line: line)
        }
    }

    // MARK: the leg fit is the NO-FIX frame (MYR-460)

    func testEnterWithNoFixFitsLegEndpointsAndSetsFollowing() {
        let c = TrackingCameraController()
        let write = c.enter(leg: .toPickup, carPosition: nil, fitCoords: [car, pickup], bottomInset: 0, viewHeight: 800)
        XCTAssertEqual(c.phase, .following)
        XCTAssertEqual(c.frame, .legFit, "no position for the car → nothing to follow, so frame the leg")
        XCTAssertEqual(c.currentLeg, .toPickup)
        XCTAssertFalse(write.animated, "entry is un-animated (fresh appearance)")
        region(containing: [car, pickup], write.region)
    }

    func testALegFitWritesNothingPerFixWhileThereIsStillNoFix() {
        let c = TrackingCameraController()
        _ = c.enter(leg: .toPickup, carPosition: nil, fitCoords: [car, pickup], bottomInset: 0, viewHeight: 800)
        for _ in 0..<50 {
            XCTAssertNil(
                c.update(leg: .toPickup, carPosition: nil, fitCoords: [car, pickup], bottomInset: 0, viewHeight: 800),
                "a leg fit with nothing new to say produces ZERO writes at any tick rate"
            )
        }
    }

    func testLegFlipRefitsTheLegWhileThereIsNoFix() {
        let c = TrackingCameraController()
        _ = c.enter(leg: .toPickup, carPosition: nil, fitCoords: [car, pickup], bottomInset: 0, viewHeight: 800)
        let refit = c.update(leg: .inRide, carPosition: nil, fitCoords: [pickup, destination], bottomInset: 0, viewHeight: 800)
        XCTAssertNotNil(refit, "the leg flip re-fits to pickup → destination")
        XCTAssertEqual(c.currentLeg, .inRide)
        region(containing: [pickup, destination], refit!.region)
    }

    // MARK: ownership — gesture dethrones, recenter re-engages

    func testUserGestureStandsTheOwnerDown() {
        let c = TrackingCameraController()
        _ = c.enter(leg: .toPickup, carPosition: nil, fitCoords: [car, pickup], bottomInset: 0, viewHeight: 800)
        c.userGestureBegan()
        XCTAssertEqual(c.phase, .userControlled)
        XCTAssertNil(
            c.update(leg: .inRide, carPosition: nil, fitCoords: [pickup, destination], bottomInset: 0, viewHeight: 800),
            "the owner never fights the user's manual zoom-out"
        )
    }

    func testRecenterReEngagesLegFitWhenThereIsStillNoFix() {
        let c = TrackingCameraController()
        _ = c.enter(leg: .toPickup, carPosition: nil, fitCoords: [car, pickup], bottomInset: 0, viewHeight: 800)
        c.userGestureBegan()
        let write = c.recenter(leg: .toPickup, carPosition: nil, fitCoords: [car, pickup], bottomInset: 0, viewHeight: 800)
        XCTAssertEqual(c.phase, .following)
        XCTAssertEqual(c.frame, .legFit)
        region(containing: [car, pickup], write.region)
    }

    // MARK: settle classification (token ledger)

    func testOwnSettleClassifiesAsOursUserSettleDethrones() {
        let c = TrackingCameraController()
        let write = c.enter(leg: .toPickup, carPosition: nil, fitCoords: [car, pickup], bottomInset: 0, viewHeight: 800)
        // Our own settle (matches the entry write) → ours, still following.
        XCTAssertTrue(c.cameraSettled(center: write.region.center, latitudeDelta: write.region.span.latitudeDelta * 1.1))
        XCTAssertEqual(c.phase, .following)
        // A settle far from any write → the user moved the map → stand down.
        let far = CLLocationCoordinate2D(latitude: write.region.center.latitude + 0.05, longitude: write.region.center.longitude + 0.05)
        XCTAssertFalse(c.cameraSettled(center: far, latitudeDelta: write.region.span.latitudeDelta * 1.1))
        XCTAssertEqual(c.phase, .userControlled)
    }

    // MARK: inset fit — respects the unobstructed area above the sheet

    func testBottomInsetShiftsFitSouthAndGrowsSpan() {
        let plain = TrackingCameraController()
            .enter(leg: .inRide, carPosition: nil, fitCoords: [pickup, destination], bottomInset: 0, viewHeight: 800).region
        let inset = TrackingCameraController()
            .enter(leg: .inRide, carPosition: nil, fitCoords: [pickup, destination], bottomInset: 400, viewHeight: 800).region
        XCTAssertGreaterThan(inset.span.latitudeDelta, plain.span.latitudeDelta, "the inset grows the fit so the route clears the sheet")
        XCTAssertLessThan(inset.center.latitude, plain.center.latitude, "and shifts it south, behind the sheet")
    }

    func testTopInsetKeepsRouteBelowNotch() {
        let bottomOnly = TrackingCameraController()
            .enter(leg: .toPickup, carPosition: nil, fitCoords: [car, pickup], bottomInset: 300, viewHeight: 800, topInset: 0).region
        let withTop = TrackingCameraController()
            .enter(leg: .toPickup, carPosition: nil, fitCoords: [car, pickup], bottomInset: 300, viewHeight: 800, topInset: 88).region
        XCTAssertGreaterThan(withTop.center.latitude, bottomOnly.center.latitude, "the top inset pulls the fit north, off the notch")
    }

    func testEqualInsetsCenterOnRouteCenter() {
        let midLat = (pickup.latitude + destination.latitude) / 2
        let write = TrackingCameraController()
            .enter(leg: .inRide, carPosition: nil, fitCoords: [pickup, destination], bottomInset: 200, viewHeight: 800, topInset: 200)
        XCTAssertEqual(write.region.center.latitude, midLat, accuracy: 1e-9)
    }

    func testReframeOnlyWhileFollowing() {
        let c = TrackingCameraController()
        _ = c.enter(leg: .toPickup, carPosition: nil, fitCoords: [car, pickup], bottomInset: 0, viewHeight: 800)
        XCTAssertNotNil(c.reframe(leg: .toPickup, fitCoords: [car, pickup], bottomInset: 0, viewHeight: 800),
                        "a route-geometry change re-fits the LEG while following")
        c.userGestureBegan()
        XCTAssertNil(c.reframe(leg: .toPickup, fitCoords: [car, pickup], bottomInset: 0, viewHeight: 800),
                     "a route update never yanks a camera the rider took over")
    }
}

// MARK: - MYR-460 — the follow camera
//
// The client's ask as a state machine: the camera follows the car by default,
// a gesture stands it down completely, and it comes back either on the recenter
// control or on its own after an idle window measured from the LAST gesture.

@MainActor
final class TrackingFollowCameraTests: XCTestCase {

    private let pickup = CLLocationCoordinate2D(latitude: 37.7899, longitude: -122.3969)
    private let destination = CLLocationCoordinate2D(latitude: 37.6213, longitude: -122.3790)
    private let span = MRTMetrics.trackingFollowSpanDelta

    /// A fix `metres` north of `from` — the unit a driving car moves in.
    private func north(_ from: CLLocationCoordinate2D, metres: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: from.latitude + metres / 111_320.0, longitude: from.longitude)
    }

    private func makeController() -> TrackingCameraController { TrackingCameraController() }

    // MARK: arming

    func testEnterWithAFixFollowsTheCarRatherThanFittingTheLeg() {
        let car = CLLocationCoordinate2D(latitude: 37.7965, longitude: -122.4079)
        let c = makeController()
        let write = c.enter(leg: .toPickup, carPosition: car, fitCoords: [car, pickup], bottomInset: 0, viewHeight: 800)

        XCTAssertEqual(c.phase, .following)
        XCTAssertEqual(c.frame, .follow, "a ride with a known car position rests on the car, not on the whole leg")
        XCTAssertEqual(write.frame, .follow)
        XCTAssertFalse(write.animated, "entry is still un-animated — a fresh appearance, not a camera move")
        XCTAssertEqual(write.region.center.latitude, car.latitude, accuracy: 1e-9)
        XCTAssertEqual(write.region.center.longitude, car.longitude, accuracy: 1e-9)
        XCTAssertEqual(write.region.span.latitudeDelta, span, accuracy: 1e-9,
                       "street level, not the whole-leg span — this is the zoom the tester says is missing")
    }

    func testTheFollowSpanIsFarTighterThanALegFitAcrossTheSameTrip() {
        let legFit = makeController()
            .enter(leg: .inRide, carPosition: nil, fitCoords: [pickup, destination], bottomInset: 0, viewHeight: 800)
        let follow = makeController()
            .enter(leg: .inRide, carPosition: pickup, fitCoords: [pickup, destination], bottomInset: 0, viewHeight: 800)
        XCTAssertLessThan(follow.region.span.latitudeDelta, legFit.region.span.latitudeDelta / 4,
                          "the rider's screenshot is a whole-trip framing with the car off the edge; follow is street scale")
    }

    func testTheFirstFixPromotesALegFitToFollowAndTheFrameNeverGoesBack() {
        let c = makeController()
        _ = c.enter(leg: .toPickup, carPosition: nil, fitCoords: [pickup, destination], bottomInset: 0, viewHeight: 800)
        XCTAssertEqual(c.frame, .legFit)

        let car = CLLocationCoordinate2D(latitude: 37.80, longitude: -122.41)
        let promote = c.update(leg: .toPickup, carPosition: car, fitCoords: [car, pickup], bottomInset: 0, viewHeight: 800)
        XCTAssertNotNil(promote, "the first fix of the ride engages the follow camera")
        XCTAssertEqual(promote?.frame, .follow)
        XCTAssertEqual(promote?.animated, true, "a mid-ride frame change is a camera MOVE and animates")
        XCTAssertEqual(c.frame, .follow)

        // The car goes quiet again: the camera holds where it last saw it rather
        // than snapping back out to the whole leg (MYR-393's rule for the camera).
        XCTAssertNil(c.update(leg: .toPickup, carPosition: nil, fitCoords: [car, pickup], bottomInset: 0, viewHeight: 800))
        XCTAssertEqual(c.frame, .follow, "a car that stops reporting keeps its frame; it does not zoom out")
    }

    // MARK: following, and the anti-loop gate

    func testADrivingCarWritesOncePerFix() {
        let c = makeController()
        var car = CLLocationCoordinate2D(latitude: 37.7871, longitude: -122.3971)
        _ = c.enter(leg: .inRide, carPosition: car, fitCoords: [car, destination], bottomInset: 0, viewHeight: 800)

        var writes = 0
        for _ in 0..<20 {
            car = north(car, metres: 15) // ~34 mph at 1Hz
            if let write = c.update(leg: .inRide, carPosition: car, fitCoords: [car, destination], bottomInset: 0, viewHeight: 800) {
                writes += 1
                XCTAssertEqual(write.region.center.latitude, car.latitude, accuracy: 1e-9,
                               "every follow write is centred on the RAW fix")
                XCTAssertEqual(write.frame, .follow)
            }
        }
        XCTAssertEqual(writes, 20, "a car that is actually driving is followed at fix cadence — that IS the feature")
    }

    func testAParkedCarsJitterWritesNothingAtAnyFixRate() {
        let c = makeController()
        let parked = CLLocationCoordinate2D(latitude: 37.7871, longitude: -122.3971)
        _ = c.enter(leg: .inRide, carPosition: parked, fitCoords: [parked, destination], bottomInset: 0, viewHeight: 800)

        // A metre of GPS noise in each direction, 100 fixes. This is the MYR-222
        // loop class: a camera that answered each of these would write for ever
        // about a car that has not moved.
        for i in 0..<100 {
            let jitter = CLLocationCoordinate2D(
                latitude: parked.latitude + (i % 2 == 0 ? 1.0 : -1.0) / 111_320.0,
                longitude: parked.longitude + (i % 3 == 0 ? 1.0 : -1.0) / 111_320.0
            )
            XCTAssertNil(
                c.update(leg: .inRide, carPosition: jitter, fitCoords: [jitter, destination], bottomInset: 0, viewHeight: 800),
                "a stationary car produces ZERO writes at any fix rate"
            )
        }
    }

    func testALatePolylineCannotReframeAFollowCamera() {
        let c = makeController()
        let car = CLLocationCoordinate2D(latitude: 37.7871, longitude: -122.3971)
        _ = c.enter(leg: .inRide, carPosition: car, fitCoords: [car, destination], bottomInset: 0, viewHeight: 800)
        XCTAssertNil(
            c.reframe(leg: .inRide, fitCoords: [car, pickup, destination], bottomInset: 0, viewHeight: 800),
            "the real road route replacing the straight fallback is a statement about the ROUTE; follow frames the CAR"
        )
    }

    // MARK: the dethrone, and the client's snap-back

    func testAGestureStopsEveryWriteUntilTheCameraIsReArmed() {
        let c = makeController()
        var car = CLLocationCoordinate2D(latitude: 37.7871, longitude: -122.3971)
        _ = c.enter(leg: .inRide, carPosition: car, fitCoords: [car, destination], bottomInset: 0, viewHeight: 800)
        c.userGestureBegan()
        XCTAssertEqual(c.phase, .userControlled)

        for _ in 0..<30 {
            car = north(car, metres: 15)
            XCTAssertNil(
                c.update(leg: .inRide, carPosition: car, fitCoords: [car, destination], bottomInset: 0, viewHeight: 800),
                "MYR-222's law is untouched by follow mode: a dethroned camera writes NOTHING, whatever the car does"
            )
        }
        // Even the leg flipping — the one thing that overrides everything else
        // while armed — may not take the camera back.
        XCTAssertNil(c.update(leg: .toPickup, carPosition: car, fitCoords: [car, pickup], bottomInset: 0, viewHeight: 800))
    }

    func testRecenterReArmsFollowOnTheCar() {
        let c = makeController()
        let car = CLLocationCoordinate2D(latitude: 37.7871, longitude: -122.3971)
        _ = c.enter(leg: .inRide, carPosition: car, fitCoords: [car, destination], bottomInset: 0, viewHeight: 800)
        c.userGestureBegan()

        let moved = north(car, metres: 400)
        let write = c.recenter(leg: .inRide, carPosition: moved, fitCoords: [moved, destination], bottomInset: 0, viewHeight: 800)
        XCTAssertEqual(c.phase, .following)
        XCTAssertEqual(c.frame, .follow)
        XCTAssertEqual(write.frame, .follow)
        XCTAssertEqual(write.animated, true)
        XCTAssertEqual(write.region.center.latitude, moved.latitude, accuracy: 1e-9,
                       "recenter goes to where the car IS now, not where it was when the rider took over")
    }

    /// ⚠️ The regression this exists for: with the token bumped only while the
    /// owner still held the camera, the idle countdown would be started by a
    /// rider's FIRST touch and fire in the middle of their third pan — MYR-222's
    /// complaint, re-entered through this issue's own fix.
    func testEveryGestureBumpsTheReArmToken_IncludingOnesAfterTheDethrone() {
        let c = makeController()
        let car = CLLocationCoordinate2D(latitude: 37.7871, longitude: -122.3971)
        _ = c.enter(leg: .inRide, carPosition: car, fitCoords: [car, destination], bottomInset: 0, viewHeight: 800)

        XCTAssertEqual(c.gestureToken, 0)
        c.userGestureBegan()
        XCTAssertEqual(c.gestureToken, 1, "the dethroning gesture")
        XCTAssertEqual(c.phase, .userControlled)

        c.userGestureBegan()
        c.userGestureBegan()
        XCTAssertEqual(c.gestureToken, 3, "a rider still working the map keeps pushing the deadline out")
        XCTAssertEqual(c.phase, .userControlled, "and the extra gestures change nothing else")
    }

    func testTheIdleWindowIsMeasuredFromTheLastGesture() {
        let delay = MRTMetrics.trackingFollowIdleRearm
        let firstTouch = Date(timeIntervalSince1970: 1_000)
        let stillPanning = firstTouch.addingTimeInterval(delay - 1)

        XCTAssertFalse(
            TrackingCameraController.idleRearmDue(lastGestureAt: stillPanning, now: firstTouch.addingTimeInterval(delay + 0.5), delay: delay),
            "the window restarts on the later gesture — the camera must not return while a finger is still on the map"
        )
        XCTAssertTrue(
            TrackingCameraController.idleRearmDue(lastGestureAt: stillPanning, now: stillPanning.addingTimeInterval(delay), delay: delay),
            "and it does return once the map has been left alone for the whole window"
        )
    }

    func testAnUntouchedCameraNeverReArms() {
        XCTAssertFalse(
            TrackingCameraController.idleRearmDue(lastGestureAt: nil, now: Date(), delay: MRTMetrics.trackingFollowIdleRearm),
            "no gesture means the owner never stood down, so there is nothing to come back from"
        )
    }

    func testTheIdleDelayIsAFewSecondsRatherThanImmediate() {
        // The client asked for "a few seconds". A window near zero would be a
        // camera that fights the rider (MYR-222); a very long one is not a
        // snap-back at all.
        XCTAssertGreaterThanOrEqual(MRTMetrics.trackingFollowIdleRearm, 3)
        XCTAssertLessThanOrEqual(MRTMetrics.trackingFollowIdleRearm, 15)
    }

    // MARK: the pure geometry

    func testFollowRegionCentresTheCarInTheBandTheSheetLeavesVisible() {
        let car = CLLocationCoordinate2D(latitude: 37.7871, longitude: -122.3971)
        let viewHeight: CGFloat = 800, bottomInset: CGFloat = 400, topInset: CGFloat = 88
        let r = TrackingCameraController.followRegion(
            car: car, spanDelta: span, bottomInset: bottomInset, viewHeight: viewHeight, topInset: topInset
        )
        // The visible band runs from `topInset` to `viewHeight - bottomInset`.
        // Its centre, projected back into the written region, must be the car.
        let north = r.center.latitude + r.span.latitudeDelta / 2
        let degreesPerPoint = r.span.latitudeDelta / Double(viewHeight)
        let bandCentreLatitude = north - (Double(topInset) + (Double(viewHeight) - Double(bottomInset) - Double(topInset)) / 2) * degreesPerPoint
        XCTAssertEqual(bandCentreLatitude, car.latitude, accuracy: 1e-9,
                       "the car sits in the middle of what the rider can SEE, not the middle of the map view")
    }

    func testFollowRegionWithNoInsetIsSimplyTheCarAtTheGivenSpan() {
        let car = CLLocationCoordinate2D(latitude: 37.7871, longitude: -122.3971)
        let r = TrackingCameraController.followRegion(car: car, spanDelta: 0.01, bottomInset: 0, viewHeight: 800, topInset: 0)
        XCTAssertEqual(r.center.latitude, car.latitude, accuracy: 1e-12)
        XCTAssertEqual(r.center.longitude, car.longitude, accuracy: 1e-12)
        XCTAssertEqual(r.span.latitudeDelta, 0.01, accuracy: 1e-12)
    }

    func testMaterialMoveIsAboutDistanceAndScalesWithTheSpan() {
        let a = CLLocationCoordinate2D(latitude: 37.7871, longitude: -122.3971)
        let fraction = MRTMetrics.trackingFollowMinMoveFraction

        XCTAssertTrue(TrackingCameraController.carMovedMaterially(from: nil, to: a, spanDelta: span, minMoveFraction: fraction),
                      "nothing written yet is always material")
        XCTAssertFalse(TrackingCameraController.carMovedMaterially(from: a, to: north(a, metres: 1), spanDelta: span, minMoveFraction: fraction),
                       "a metre of GPS noise is not a move")
        XCTAssertTrue(TrackingCameraController.carMovedMaterially(from: a, to: north(a, metres: 15), spanDelta: span, minMoveFraction: fraction),
                      "a car doing 34 mph moves 15m per fix and is followed")
        // The threshold is a fraction of the span, so a wider camera tolerates more.
        XCTAssertFalse(TrackingCameraController.carMovedMaterially(from: a, to: north(a, metres: 15), spanDelta: span * 20, minMoveFraction: fraction),
                       "at a much wider zoom the same 15m is sub-pixel and not worth a write")
    }

    func testMaterialMoveWeightsLongitudeByLatitude() {
        // The same physical distance east and north must read the same, or the
        // threshold would be a different distance in Anchorage than in Miami.
        let a = CLLocationCoordinate2D(latitude: 60, longitude: 10)
        let metres = 12.0
        let northward = CLLocationCoordinate2D(latitude: a.latitude + metres / 111_320.0, longitude: a.longitude)
        let eastward = CLLocationCoordinate2D(
            latitude: a.latitude,
            longitude: a.longitude + metres / (111_320.0 * cos(a.latitude * .pi / 180))
        )
        let fraction = MRTMetrics.trackingFollowMinMoveFraction
        XCTAssertEqual(
            TrackingCameraController.carMovedMaterially(from: a, to: northward, spanDelta: span, minMoveFraction: fraction),
            TrackingCameraController.carMovedMaterially(from: a, to: eastward, spanDelta: span, minMoveFraction: fraction)
        )
    }

    func testNonFiniteFixesNeverProduceAWrite() {
        let a = CLLocationCoordinate2D(latitude: 37.7871, longitude: -122.3971)
        let nonsense = CLLocationCoordinate2D(latitude: .nan, longitude: .nan)
        XCTAssertFalse(TrackingCameraController.carMovedMaterially(
            from: a, to: nonsense, spanDelta: span, minMoveFraction: MRTMetrics.trackingFollowMinMoveFraction
        ))
    }

    // MARK: the settle ledger still recognises follow's own writes

    func testTheLedgerAcceptsAStreamOfFollowWritesAndStillCatchesTheUsersDrag() {
        let c = makeController()
        var car = CLLocationCoordinate2D(latitude: 37.7871, longitude: -122.3971)
        var write = c.enter(leg: .inRide, carPosition: car, fitCoords: [car, destination], bottomInset: 0, viewHeight: 800)

        // Twenty fixes, each write followed by its own settle — the streaming
        // case the wall-clock window could not survive (MYR-222).
        for _ in 0..<20 {
            XCTAssertTrue(c.cameraSettled(center: write.region.center, latitudeDelta: write.region.span.latitudeDelta),
                          "our own settle is never mistaken for a gesture, at any fix rate")
            XCTAssertEqual(c.phase, .following)
            car = north(car, metres: 15)
            write = c.update(leg: .inRide, carPosition: car, fitCoords: [car, destination], bottomInset: 0, viewHeight: 800)!
        }

        let dragged = CLLocationCoordinate2D(latitude: write.region.center.latitude + 0.4, longitude: write.region.center.longitude + 0.4)
        XCTAssertFalse(c.cameraSettled(center: dragged, latitudeDelta: write.region.span.latitudeDelta),
                       "and the rider's drag still dethrones it")
        XCTAssertEqual(c.phase, .userControlled)
    }
}
