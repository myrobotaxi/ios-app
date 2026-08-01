import XCTest

// MARK: - MYR-395 — the lineless map says which kind of lineless it is
//
// r16, the client, on the Review sheet for a 1,049 mi Grayslake IL → Galleria
// Dallas trip: *"Looks like your route etch update broke the line from being
// drawn: this is a major regression."* The frame: camera fitted across half the
// United States, the pickup's glow head breathing, **no line and no words**.
//
// Nothing had broken. MKDirections had answered with the straight `[from, to]`
// fallback, `RideRoutePolyline.isReal` refused it (MYR-237's rule, correctly), and
// the map drew nothing rather than passing a straight line off as road geometry.
// The defect is that the refusal was silent — a map that DECLINES to draw and a
// map that FAILED to draw are the same picture.
//
// **THIS HAS TO BE A UI TEST.** `RideRouteAvailabilityTests` pins the rule and
// `RouteEtchContinuityTests` pins the presentation; neither can show that the
// SCREEN consults either — which is precisely how MYR-387's defect 2 and MYR-369's
// `VehicleRideShare.display` both survived full green suites. It also cannot be a
// screenshot-only check: what has to be true is that a *sentence* is on screen.
//
// **`MRT_ROUTE_UNAVAILABLE=1` is the only route to the state.** Measured on this
// runner, MKDirections answers the client's own 949-mile pair in ~1.0s with 7,348
// vertices, so the frame he photographed cannot be reached by picking a longer
// trip — the modifier swaps in `StraightLineRideRouteProvider`, which returns
// exactly the two-point pair `AppleRideRouteProvider` returns on a throttle, an
// offline device, or a lost 8s deadline. Everything downstream is the shipping
// store, the shipping predicate and the shipping presentation.
final class RouteAvailabilityUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private static let captionID = "route-availability-caption"
    private static let settledFailure = "Can't find a route right now"

    private func launch(scene: String, routeUnavailable: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MRT_SCENE"] = scene
        if routeUnavailable { app.launchEnvironment["MRT_ROUTE_UNAVAILABLE"] = "1" }
        app.launch()
        return app
    }

    private func attach(_ app: XCUIApplication, named name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        _ = app
    }

    /// **The client's frame, and the sentence that was missing from it.** The
    /// ETCHING surface (Review) with a fetch that came back without road geometry.
    func testTheReviewMapSaysWhyItHasNoLine() {
        let app = launch(scene: "reviewLongDistance", routeUnavailable: true)
        let caption = app.staticTexts[Self.captionID]
        XCTAssertTrue(
            caption.waitForExistence(timeout: 25),
            "a lineless route map must not be silent — this is the r16 frame"
        )
        XCTAssertEqual(caption.label, Self.settledFailure)
        attach(app, named: "MYR-395 review · no road geometry · caption")
    }

    /// The SAME state on the STATIC surface, which had the opposite defect: with
    /// the realness guard below the `etch` guard, Booking took `.settled` and drew
    /// the straight fallback as a 949-mile gold route across five states. It now
    /// draws no line and carries the same one sentence — one grammar, both arms.
    func testTheBookingMapSaysTheSameThingAndDrawsNoStraightLine() {
        let app = launch(scene: "booking", routeUnavailable: true)
        let caption = app.staticTexts[Self.captionID]
        XCTAssertTrue(caption.waitForExistence(timeout: 25))
        XCTAssertEqual(
            caption.label, Self.settledFailure,
            "the static surface must not invent its own wording for one state"
        )
        attach(app, named: "MYR-395 booking · no road geometry · caption")
    }

    /// **The guard on the guard**: a surface that HAS its road geometry says
    /// nothing at all. This is what keeps every existing route capture
    /// byte-identical, and it is the assertion that would fail if the caption were
    /// ever wired to a condition looser than "there is no line".
    func testARealRouteCarriesNoCaptionAtAll() {
        let app = launch(scene: "review", routeUnavailable: false)
        // The etch itself takes 1.6s after MKDirections lands, and the in-flight
        // "Finding route…" is legitimately on screen before that — so this waits
        // out the whole pass rather than sampling the first frame it can.
        XCTAssertTrue(
            app.staticTexts["SFO \u{00B7} Terminal 2"].waitForExistence(timeout: 20),
            "precondition: the Review sheet is up"
        )
        let caption = app.staticTexts[Self.captionID]
        let deadline = Date().addingTimeInterval(25)
        var lastSeen: String?
        while Date() < deadline {
            if caption.exists {
                lastSeen = caption.label
                // Only the IN-FLIGHT line may appear on a trip that resolves.
                XCTAssertEqual(
                    lastSeen, "Finding route\u{2026}",
                    "a route that is arriving may say so; it may never claim to have failed"
                )
            } else if lastSeen != nil {
                break   // it appeared while fetching and then went away — the route landed
            }
            usleep(300_000)
        }
        XCTAssertFalse(
            caption.exists,
            "a drawn route must carry no caption — every existing capture depends on it"
        )
        attach(app, named: "MYR-395 review · real route · no caption")
    }
}
