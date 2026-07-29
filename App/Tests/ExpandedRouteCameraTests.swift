import CoreLocation
import DesignSystem
import MapKit
@testable import MyRoboTaxi
import XCTest

// MARK: - MYR-327 — the expanded route viewer's camera contract
//
// The one rule that makes this surface safe from the MYR-222 loop class is
// structural, not tuned: on the expanded viewer the USER owns the camera, and
// exactly TWO programmatic writes exist — the initial fit (once, ever) and an
// explicit recenter tap. These tests pin that arithmetic, because it is what the
// streaming-fix probe is checking for in the log and what a future edit could
// silently break by adding a "keep the car framed" re-fit.

@MainActor
final class ExpandedRouteCameraTests: XCTestCase {

    /// A representative full-bleed phone height — the fit reserves the floating
    /// chrome bands against it (`expandedRouteFitTopInset`/`…BottomInset`).
    private let viewHeight: CGFloat = 852

    private let route = [
        CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
        CLLocationCoordinate2D(latitude: 37.7849, longitude: -122.4094),
        CLLocationCoordinate2D(latitude: 37.7949, longitude: -122.3994),
    ]

    // MARK: The initial fit

    func testSeatWritesOnceAndFitsTheRoute() {
        let camera = ExpandedRouteCamera()
        XCTAssertEqual(camera.phase, .unseated)

        let write = camera.seat(fitCoords: route, viewHeight: viewHeight)
        XCTAssertNotNil(write, "the first appearance must fit the route")
        XCTAssertEqual(camera.phase, .fitted)
        XCTAssertEqual(write?.animated, false, "a fresh appearance is not a camera move")

        // The fit frames the route's bounding box.
        let region = try! XCTUnwrap(write?.region)
        XCTAssertEqual(region.center.latitude, 37.7849, accuracy: 1e-6)
        XCTAssertEqual(region.center.longitude, -122.4094, accuracy: 1e-6)
        XCTAssertGreaterThan(region.span.latitudeDelta, 0.02 - 1e-9)
    }

    func testSeatIsIdempotentSoStreamingFixesCanNeverRefit() {
        let camera = ExpandedRouteCamera()
        var writes = 0
        if camera.seat(fitCoords: route, viewHeight: viewHeight) != nil { writes += 1 }

        // 1000 subsequent updates — a car streaming a fix a second for ~17
        // minutes, or the real polyline replacing a fallback repeatedly.
        for _ in 0..<1000 where camera.seat(fitCoords: route, viewHeight: viewHeight) != nil { writes += 1 }

        XCTAssertEqual(writes, 1, "the expanded viewer must write the camera exactly once automatically")
    }

    func testSeatRefusesARoutelessInput() {
        let camera = ExpandedRouteCamera()
        XCTAssertNil(camera.seat(fitCoords: [], viewHeight: viewHeight), "nothing honest to frame")
        XCTAssertEqual(camera.phase, .unseated, "and the fit is still owed once a route arrives")
        XCTAssertNotNil(camera.seat(fitCoords: route, viewHeight: viewHeight))
    }

    // MARK: Recenter — the ONLY other programmatic write

    func testRecenterAlwaysWritesAndReclaimsTheFit() {
        let camera = ExpandedRouteCamera()
        _ = camera.seat(fitCoords: route, viewHeight: viewHeight)
        camera.userGestureBegan()
        XCTAssertEqual(camera.phase, .userControlled)

        let write = camera.recenter(fitCoords: route, viewHeight: viewHeight)
        XCTAssertNotNil(write)
        XCTAssertEqual(write?.animated, true, "a recenter is a visible camera move")
        XCTAssertEqual(camera.phase, .fitted)
        XCTAssertFalse(camera.showsRecenter, "the affordance retires once the fit is back")
    }

    func testRecenterRefusesARoutelessInput() {
        let camera = ExpandedRouteCamera()
        XCTAssertNil(camera.recenter(fitCoords: [], viewHeight: viewHeight))
    }

    // MARK: Gesture dethrones the fit

    func testUserGestureTakesTheCameraAndSurfacesRecenter() {
        let camera = ExpandedRouteCamera()
        _ = camera.seat(fitCoords: route, viewHeight: viewHeight)
        XCTAssertFalse(camera.showsRecenter, "nothing to recenter to while the fit still holds")

        camera.userGestureBegan()
        XCTAssertEqual(camera.phase, .userControlled)
        XCTAssertTrue(camera.showsRecenter)

        // Repeat gestures are a no-op, not a re-entry.
        camera.userGestureBegan()
        XCTAssertEqual(camera.phase, .userControlled)
    }

    // MARK: Settle classification (the shared ledger)

    func testOurOwnSettleIsClassifiedProgrammatic() {
        let camera = ExpandedRouteCamera()
        let write = camera.seat(fitCoords: route, viewHeight: viewHeight)!
        let ours = camera.cameraSettled(
            center: write.region.center,
            latitudeDelta: write.region.span.latitudeDelta
        )
        XCTAssertTrue(ours, "the fit's own settle must not read as a gesture")
        XCTAssertEqual(camera.phase, .fitted)
        XCTAssertFalse(camera.showsRecenter)
    }

    func testAnUnexpectedSettleHandsTheCameraToTheUser() {
        let camera = ExpandedRouteCamera()
        let write = camera.seat(fitCoords: route, viewHeight: viewHeight)!
        // Our own fit settle matches its expectation.
        XCTAssertTrue(camera.cameraSettled(center: write.region.center, latitudeDelta: write.region.span.latitudeDelta))

        // `seat` grants ONE free pass for MapKit's un-predictable mount/layout
        // settle (the same mercy every camera owner uses), so the first stray
        // settle is excused …
        let elsewhere = CLLocationCoordinate2D(latitude: 40.0, longitude: -74.0)
        XCTAssertTrue(camera.cameraSettled(center: elsewhere, latitudeDelta: 0.9))
        XCTAssertEqual(camera.phase, .fitted)

        // … and the next one is unambiguously the user. (In practice the drag /
        // magnify recognizers dethrone the fit before any settle arrives — this
        // path is the backstop, which is why one excused settle costs nothing.)
        let further = CLLocationCoordinate2D(latitude: 41.5, longitude: -73.0)
        XCTAssertFalse(camera.cameraSettled(center: further, latitudeDelta: 1.4))
        XCTAssertEqual(camera.phase, .userControlled)
        XCTAssertTrue(camera.showsRecenter)
    }

    /// REGRESSION (found on the simulator during the MYR-327 camera probe):
    /// MapKit settles its own `.automatic` content framing BEFORE SwiftUI runs
    /// `onAppear`, so settles arrive while the initial fit is still owed. Reading
    /// those as a gesture stood the owner down before it ever wrote — the map
    /// stayed at `.automatic`'s tight content fit (route touching both screen
    /// edges) and offered a recenter button on a camera nobody had touched.
    func testSettlesBeforeTheFitIsWrittenAreLayoutNotGestures() {
        let camera = ExpandedRouteCamera()
        let automaticFraming = CLLocationCoordinate2D(latitude: 37.7914, longitude: -122.3954)

        XCTAssertTrue(camera.cameraSettled(center: automaticFraming, latitudeDelta: 0.0094))
        XCTAssertTrue(camera.cameraSettled(center: automaticFraming, latitudeDelta: 0.0104))
        XCTAssertEqual(camera.phase, .unseated, "the fit is still owed")
        XCTAssertFalse(camera.showsRecenter, "and no recenter is offered for a camera nobody moved")

        // …so the fit still lands when `onAppear` finally runs.
        XCTAssertNotNil(camera.seat(fitCoords: route, viewHeight: viewHeight))
        XCTAssertEqual(camera.phase, .fitted)
    }

    func testSettlesWhileUserControlledNeverReclaimTheCamera() {
        let camera = ExpandedRouteCamera()
        let write = camera.seat(fitCoords: route, viewHeight: viewHeight)!
        camera.userGestureBegan()

        // Even a settle that lands exactly on our old fit must not re-seat the
        // owner — only the recenter tap does that.
        XCTAssertFalse(camera.cameraSettled(
            center: write.region.center,
            latitudeDelta: write.region.span.latitudeDelta
        ))
        XCTAssertEqual(camera.phase, .userControlled)
    }

    func testRecenterSettleIsClassifiedProgrammatic() {
        let camera = ExpandedRouteCamera()
        _ = camera.seat(fitCoords: route, viewHeight: viewHeight)
        camera.userGestureBegan()
        let write = camera.recenter(fitCoords: route, viewHeight: viewHeight)!

        XCTAssertTrue(camera.cameraSettled(
            center: write.region.center,
            latitudeDelta: write.region.span.latitudeDelta
        ))
        XCTAssertEqual(camera.phase, .fitted)
    }
}

// MARK: - Shared tracking map content (MYR-327 — one recipe, two cameras)
//
// The expanded viewer draws through the SAME builder as the inline tracking map,
// so these pin the derivations both now share — a drift here would mean the
// expanded route showed different endpoints than the map it expanded from.

final class TrackingRouteMapContentTests: XCTestCase {
    private let car = CLLocationCoordinate2D(latitude: 37.80, longitude: -122.42)
    private let pickupCoord = CLLocationCoordinate2D(latitude: 37.78, longitude: -122.41)
    private let dropCoord = CLLocationCoordinate2D(latitude: 37.76, longitude: -122.39)

    func testPickupIsTheEndOfLegOneWhenItExists() {
        let pickup = TrackingRouteMapContent.pickup(
            leg1Route: [car, pickupCoord],
            leg2Route: [pickupCoord, dropCoord],
            carCoordinate: car
        )
        XCTAssertEqual(pickup.latitude, pickupCoord.latitude, accuracy: 1e-9)
        XCTAssertEqual(pickup.longitude, pickupCoord.longitude, accuracy: 1e-9)
    }

    func testPickupFallsBackToLegTwoStartThenTheCar() {
        let fromLeg2 = TrackingRouteMapContent.pickup(
            leg1Route: [], leg2Route: [pickupCoord, dropCoord], carCoordinate: car
        )
        XCTAssertEqual(fromLeg2.latitude, pickupCoord.latitude, accuracy: 1e-9)

        let fromCar = TrackingRouteMapContent.pickup(leg1Route: [], leg2Route: [], carCoordinate: car)
        XCTAssertEqual(fromCar.latitude, car.latitude, accuracy: 1e-9)
    }

    func testDestinationIsNilUntilLegTwoHasGeometry() {
        XCTAssertNil(TrackingRouteMapContent.destination(leg2Route: []))
        let destination = TrackingRouteMapContent.destination(leg2Route: [pickupCoord, dropCoord])
        XCTAssertEqual(destination?.latitude ?? 0, dropCoord.latitude, accuracy: 1e-9)
    }
}
