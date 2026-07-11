import CoreLocation
import DesignSystem
import MapKit
@testable import MyRoboTaxi
import XCTest

// MARK: - MYR-177 — leg-fit camera: fit math, re-fit policy, ownership
//
// The regression this pins (four camera rounds deep): the tracking camera must
// frame the ACTIVE leg (car→pickup / pickup→destination) and re-fit ONLY on a
// leg flip or when the car leaves the frame — never per fix (the anti-loop
// guarantee the streaming probe verifies), with the same single-owner /
// gesture-dethrone / recenter discipline as the pin-drop owner.

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

    // MARK: fit-region membership (pure)

    func testCarWithinRegionCenterIsInside() {
        let r = MKCoordinateRegion(center: pickup, span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))
        XCTAssertTrue(TrackingCameraController.carWithinRegion(pickup, region: r, marginFraction: 0.14))
    }

    func testCarBeyondInnerMarginIsOutside() {
        let r = MKCoordinateRegion(center: pickup, span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))
        // Inner half-span with 0.14 margin = 0.01 * 0.86 = 0.0086. Put the car
        // at 0.0095 north — inside the region but past the re-fit margin.
        let nearEdge = CLLocationCoordinate2D(latitude: pickup.latitude + 0.0095, longitude: pickup.longitude)
        XCTAssertFalse(TrackingCameraController.carWithinRegion(nearEdge, region: r, marginFraction: 0.14))
    }

    // MARK: enter frames the active leg

    func testEnterFitsLegEndpointsAndSetsFollowing() {
        let c = TrackingCameraController()
        let write = c.enter(leg: .toPickup, fitCoords: [car, pickup], bottomInset: 0, viewHeight: 800)
        XCTAssertEqual(c.phase, .following)
        XCTAssertEqual(c.currentLeg, .toPickup)
        XCTAssertFalse(write.animated, "entry is un-animated (fresh appearance)")
        region(containing: [car, pickup], write.region)
    }

    // MARK: the anti-loop guarantee — no write while the car stays framed

    func testUpdateWritesNothingWhileCarStaysInFrame() {
        let c = TrackingCameraController()
        let write = c.enter(leg: .toPickup, fitCoords: [car, pickup], bottomInset: 0, viewHeight: 800)
        // A tiny nudge (a streaming fix) that keeps the car well inside the frame.
        let nudged = CLLocationCoordinate2D(latitude: write.region.center.latitude, longitude: write.region.center.longitude)
        for _ in 0..<50 {
            XCTAssertNil(c.update(leg: .toPickup, carPosition: nudged, fitCoords: [nudged, pickup], bottomInset: 0, viewHeight: 800),
                         "a framed car produces ZERO writes at any fix rate")
        }
    }

    func testUpdateRefitsWhenCarLeavesFrame() {
        let c = TrackingCameraController()
        let write = c.enter(leg: .toPickup, fitCoords: [car, pickup], bottomInset: 0, viewHeight: 800)
        let outside = CLLocationCoordinate2D(latitude: write.region.center.latitude + write.region.span.latitudeDelta,
                                             longitude: write.region.center.longitude)
        let refit = c.update(leg: .toPickup, carPosition: outside, fitCoords: [outside, pickup], bottomInset: 0, viewHeight: 800)
        XCTAssertNotNil(refit, "a car that left the frame re-fits")
        XCTAssertEqual(refit?.animated, true)
    }

    func testLegFlipRefits() {
        let c = TrackingCameraController()
        _ = c.enter(leg: .toPickup, fitCoords: [car, pickup], bottomInset: 0, viewHeight: 800)
        let refit = c.update(leg: .inRide, carPosition: pickup, fitCoords: [pickup, destination], bottomInset: 0, viewHeight: 800)
        XCTAssertNotNil(refit, "the leg flip re-fits to pickup → destination")
        XCTAssertEqual(c.currentLeg, .inRide)
        region(containing: [pickup, destination], refit!.region)
    }

    // MARK: ownership — gesture dethrones, recenter re-engages

    func testUserGestureStandsTheOwnerDown() {
        let c = TrackingCameraController()
        _ = c.enter(leg: .toPickup, fitCoords: [car, pickup], bottomInset: 0, viewHeight: 800)
        c.userGestureBegan()
        XCTAssertEqual(c.phase, .userControlled)
        let outside = CLLocationCoordinate2D(latitude: car.latitude + 1, longitude: car.longitude)
        XCTAssertNil(c.update(leg: .toPickup, carPosition: outside, fitCoords: [outside, pickup], bottomInset: 0, viewHeight: 800),
                     "the owner never fights the user's manual zoom-out")
    }

    func testRecenterReEngagesLegFit() {
        let c = TrackingCameraController()
        _ = c.enter(leg: .toPickup, fitCoords: [car, pickup], bottomInset: 0, viewHeight: 800)
        c.userGestureBegan()
        let write = c.recenter(leg: .toPickup, fitCoords: [car, pickup], bottomInset: 0, viewHeight: 800)
        XCTAssertEqual(c.phase, .following)
        region(containing: [car, pickup], write.region)
    }

    // MARK: settle classification (token ledger)

    func testOwnSettleClassifiesAsOursUserSettleDethrones() {
        let c = TrackingCameraController()
        let write = c.enter(leg: .toPickup, fitCoords: [car, pickup], bottomInset: 0, viewHeight: 800)
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
        let c = TrackingCameraController()
        let plain = c.enter(leg: .inRide, fitCoords: [pickup, destination], bottomInset: 0, viewHeight: 800).region
        let c2 = TrackingCameraController()
        let inset = c2.enter(leg: .inRide, fitCoords: [pickup, destination], bottomInset: 400, viewHeight: 800).region
        XCTAssertGreaterThan(inset.span.latitudeDelta, plain.span.latitudeDelta, "the inset grows the fit so the route clears the sheet")
        XCTAssertLessThan(inset.center.latitude, plain.center.latitude, "and shifts it south, behind the sheet")
    }

    func testTopInsetKeepsRouteBelowNotch() {
        // A top inset shifts the fit NORTH relative to a bottom-only inset (the
        // route no longer rides up under the notch — client fix).
        let bottomOnly = TrackingCameraController().enter(leg: .toPickup, fitCoords: [car, pickup], bottomInset: 300, viewHeight: 800, topInset: 0).region
        let withTop = TrackingCameraController().enter(leg: .toPickup, fitCoords: [car, pickup], bottomInset: 300, viewHeight: 800, topInset: 88).region
        XCTAssertGreaterThan(withTop.center.latitude, bottomOnly.center.latitude, "the top inset pulls the fit north, off the notch")
    }

    func testEqualInsetsCenterOnRouteCenter() {
        // Symmetric insets → no shift: the region center is the route's own center.
        let midLat = (pickup.latitude + destination.latitude) / 2
        let write = TrackingCameraController().enter(leg: .inRide, fitCoords: [pickup, destination], bottomInset: 200, viewHeight: 800, topInset: 200)
        XCTAssertEqual(write.region.center.latitude, midLat, accuracy: 1e-9)
    }

    func testReframeOnlyWhileFollowing() {
        let c = TrackingCameraController()
        _ = c.enter(leg: .toPickup, fitCoords: [car, pickup], bottomInset: 0, viewHeight: 800)
        XCTAssertNotNil(c.reframe(leg: .toPickup, fitCoords: [car, pickup], bottomInset: 0, viewHeight: 800),
                        "a route-geometry change re-fits while following")
        c.userGestureBegan()
        XCTAssertNil(c.reframe(leg: .toPickup, fitCoords: [car, pickup], bottomInset: 0, viewHeight: 800),
                     "a route update never yanks a camera the rider took over")
    }
}
