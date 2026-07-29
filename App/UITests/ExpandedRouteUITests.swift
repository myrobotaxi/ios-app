import XCTest

// MARK: - MYR-327 — "click into the map" end to end
//
// The client's ask is an INTERACTION ("click into the map and interact with the
// route by zoom in and out"), and the two things that can silently break it are
// invisible to a unit test and to a static screenshot:
//
//   1. the tap never reaches the map (SwiftUI/MapKit gesture arbitration), so
//      nothing opens;
//   2. the pan/pinch is swallowed, or the camera owner snaps back over it.
//
// So this target synthesizes real touches on both host surfaces and asserts the
// observable outcomes. It also emits the drift-gate captures for the states that
// only exist mid-interaction (a panned/zoomed route with the recenter affordance
// up), which headless `simctl` tooling cannot reach.
final class ExpandedRouteUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private enum Labels {
        static let expand = "Expand the route"
        static let close = "Close route view"
        static let recenter = "Fit the whole route"
    }

    private func launchDriveSummary(expanded: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MRT_SCENE"] = "ownerDrives"
        app.launchEnvironment["MRT_OPEN_FIRST_DRIVE"] = "1"
        if expanded { app.launchEnvironment["MRT_EXPAND_ROUTE"] = "1" }
        app.launch()
        return app
    }

    private func launchTracking(expanded: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MRT_SCENE"] = "trackingLeg2"
        if expanded { app.launchEnvironment["MRT_EXPAND_ROUTE"] = "1" }
        app.launch()
        return app
    }

    private func attach(_ app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: The client's literal ask — tapping the map opens the route

    func testTappingTheDriveSummaryHeroOpensTheExpandedRoute() {
        let app = launchDriveSummary()
        let close = app.buttons[Labels.close]
        XCTAssertFalse(close.exists, "the viewer must not be up before anything is tapped")

        // Tap the middle of the hero band (268pt tall, at the top of the screen)
        // — the map itself, not the floating nav buttons.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.11)).tap()

        XCTAssertTrue(close.waitForExistence(timeout: 6), "a tap on the hero map must open the expanded route")
        attach(app, named: "driveSummary-expanded-by-tap")
    }

    func testTheExpandChipOpensAndClosesTheExpandedRoute() {
        let app = launchDriveSummary()
        let expand = app.buttons[Labels.expand]
        XCTAssertTrue(expand.waitForExistence(timeout: 12), "the hero must offer a visible expand affordance")

        expand.tap()
        let close = app.buttons[Labels.close]
        XCTAssertTrue(close.waitForExistence(timeout: 6))

        close.tap()
        XCTAssertTrue(expand.waitForExistence(timeout: 6), "closing must return to the drive summary")
        XCTAssertFalse(app.buttons[Labels.close].exists)
    }

    func testTappingTheTrackingMapOpensTheExpandedRoute() {
        let app = launchTracking()
        let close = app.buttons[Labels.close]
        XCTAssertFalse(close.exists)

        // The upper third of the rider tracking screen is map; the sheet covers
        // the bottom ~312pt.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()

        XCTAssertTrue(close.waitForExistence(timeout: 6), "a tap on the tracking map must open the expanded route")
        attach(app, named: "tracking-expanded-by-tap")
    }

    // MARK: The interaction itself — pan/zoom, and the recenter that follows

    func testPanningTheExpandedRouteSurfacesRecenterAndRecenterRestoresTheFit() {
        let app = launchDriveSummary(expanded: true)
        XCTAssertTrue(app.buttons[Labels.close].waitForExistence(timeout: 12))

        let recenter = app.buttons[Labels.recenter]
        XCTAssertFalse(recenter.isHittable, "nothing to recenter to while the route fit still holds")
        attach(app, named: "driveSummary-expanded-fitted")

        // A real drag across the map — the gesture the client asked for.
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.28))
        from.press(forDuration: 0.05, thenDragTo: to)

        XCTAssertTrue(
            recenter.waitForHittable(timeout: 6),
            "a pan must dethrone the fit and offer the recenter affordance"
        )
        attach(app, named: "driveSummary-expanded-panned-recenter-offered")

        // Tapped by COORDINATE, not `recenter.tap()`: XCUITest's element tap
        // resolves its own hit point for this fading `FloatingMapButton` and
        // lands off the control (verified — the action never fires, while a
        // touch at the element's own centre does). The product is fine; this is
        // the harness being clever.
        recenter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        // The fit is back, so the affordance retires again — proof the camera
        // owner re-seated rather than the button merely being cosmetic.
        XCTAssertTrue(
            recenter.waitForNotHittable(timeout: 6),
            "recentering must re-seat the route fit and retire the affordance"
        )
        attach(app, named: "driveSummary-expanded-recentered")
    }

    func testPinchZoomIsAcceptedByTheExpandedRoute() {
        let app = launchDriveSummary(expanded: true)
        XCTAssertTrue(app.buttons[Labels.close].waitForExistence(timeout: 12))

        let recenter = app.buttons[Labels.recenter]
        XCTAssertFalse(recenter.isHittable)

        // "zoom in and out to look at it" — the ask, literally.
        app.pinch(withScale: 2.4, velocity: 1.4)

        XCTAssertTrue(
            recenter.waitForHittable(timeout: 6),
            "a pinch must reach the map and take the camera"
        )
        attach(app, named: "driveSummary-expanded-zoomed")
    }

    func testPanningTheExpandedTrackingRouteSurfacesRecenter() {
        let app = launchTracking(expanded: true)
        XCTAssertTrue(app.buttons[Labels.close].waitForExistence(timeout: 12))

        let recenter = app.buttons[Labels.recenter]
        XCTAssertFalse(recenter.isHittable)
        attach(app, named: "tracking-expanded-fitted")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.3)))

        XCTAssertTrue(recenter.waitForHittable(timeout: 6))
        attach(app, named: "tracking-expanded-panned-recenter-offered")
    }
}

private extension XCUIElement {
    /// `waitForExistence` is not enough here: the recenter button is always in
    /// the hierarchy and merely fades in/out (`FloatingMapButton.hidden`), so
    /// HITTABILITY is the observable that tracks the camera owner's phase.
    func waitForHittable(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isHittable { return true }
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "poll")], timeout: 0.25)
        }
        return isHittable
    }

    func waitForNotHittable(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isHittable { return true }
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "poll")], timeout: 0.25)
        }
        return !isHittable
    }
}
