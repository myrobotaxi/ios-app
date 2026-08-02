import XCTest

// MARK: - MYR-414 — the post-ride summary, on the surface rather than in the rule
//
// r17, the client: *"this screen at the end is not connected to real data."*
//
// **A PURE TEST CANNOT SHOW THAT THE SCREEN CONSULTS ANY OF THIS**, which is how
// MYR-387's defect 2 and MYR-369's `VehicleRideShare.display` both survived full
// green suites: a correct rule with the wrong consumer, or no consumer at all.
// `RideSummaryHonestyTests` proves what `RideSummaryPresentation` decides; this
// proves the summary takeover renders that decision — on both paths, since the SIM
// arm is a promise about the drift gate and is worth as much as the live one.
//
// The two scenes are a one-branch diff: `summary` and `riderSummaryLive` seed the
// same page, and only `debugResolvesLiveRideSummary` (plus the live-shaped record
// behind it) differs.
final class RideSummaryHonestyUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    // The stat labels and the tip kicker are `RideEyebrowText`, which UPPERCASES.
    private static let tripLabel = "TRIP"
    /// MYR-422 — the measured distance is no longer a TILE (a fourth tile does not
    /// fit the page: `RideSummaryStripLayoutTests`); it is a suffix on the hero's
    /// "from {pickup}" caption, under the route it measures.
    private static let distanceSuffix = " mi"
    private static let fsdLabel = "FSD MILES"
    private static let autonomyLabel = "AUTONOMOUS"
    private static let tipLabel = "TIP YOUR DRIVER"
    /// MYR-422 — the placeholder value, `BatteryReadout.dash` (an em dash).
    private static let dash = "\u{2014}"

    private func launch(scene: String, routeUnavailable: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MRT_SCENE"] = scene
        if routeUnavailable { app.launchEnvironment["MRT_ROUTE_UNAVAILABLE"] = "1" }
        app.launch()
        // The page is a full-screen takeover with a fixed CTA; waiting on it means
        // waiting for the summary itself rather than for a timer.
        XCTAssertTrue(app.buttons["See you soon"].waitForExistence(timeout: 20),
                      "the summary takeover never mounted")
        return app
    }

    /// The hero caption once it carries a measurement — "from {pickup} · 12.8 mi".
    /// Matched on the SUFFIX rather than on a literal, because the number is the
    /// route's own length and the pickup label is the scene's.
    private func measuredDistance(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'from ' AND label ENDSWITH %@", Self.distanceSuffix)
        ).firstMatch
    }

    private func attach(named name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// **THE CLIENT'S THREE NUMBERS ARE GONE FROM THE LIVE PAGE**, and what stands in
    /// their place is either a datum or a dash.
    ///
    /// MYR-422 changes the second half of this: the FSD MILES and AUTONOMOUS tiles
    /// are BACK (the row keeps its shape) and they carry the em dash, so the check
    /// is no longer "the label is absent" but "the label is present and the number
    /// is not". This scene is the MKDirections rung — its drives read is refused
    /// 403, exactly as a viewer-tier rider's is.
    func testTheLiveSummaryRendersDerivableStatsAndDashesForTheRest() {
        let app = launch(scene: "riderSummaryLive")
        // The road route lands in ~1s (after the 403 settles the drive join) and the
        // hero caption gains its measured distance with it.
        XCTAssertTrue(measuredDistance(app).waitForExistence(timeout: 25),
                      "the drives read was refused, so the MKDirections rung answered")
        XCTAssertTrue(app.staticTexts[Self.tripLabel].exists,
                      "the trip span was observed end to end, so it is derivable")
        XCTAssertTrue(app.staticTexts[Self.fsdLabel].exists,
                      "MYR-422: the tile returns as a placeholder rather than being omitted")
        XCTAssertTrue(app.staticTexts[Self.autonomyLabel].exists)
        XCTAssertTrue(app.staticTexts[Self.dash].exists,
                      "and what it carries is the BatteryReadout dash, not a number")
        attach(named: "myr422-live-summary-apple-rung")
    }

    /// **RUNG 1: THE CAR'S OWN DRIVEN TRACK.** The same page for a self-riding owner
    /// whose §7.2 list carries a drive covering the trip — the client's own case, and
    /// the source he asked for first. The two placeholders are unchanged by which
    /// rung drew the line: a drive record exists, but its FSD figures describe the
    /// whole drive (approach leg included) and cannot be cut to the trip.
    func testTheDriveBackedSummaryDrawsTheDrivenRoute() {
        let app = launch(scene: "riderSummaryDriveRoute")
        XCTAssertTrue(measuredDistance(app).waitForExistence(timeout: 25),
                      "the joined drive's trimmed track is real geometry, so it is drawn and measured")
        XCTAssertTrue(app.staticTexts[Self.tripLabel].exists)
        XCTAssertTrue(app.staticTexts[Self.fsdLabel].exists)
        XCTAssertTrue(app.staticTexts[Self.dash].exists)
        attach(named: "myr422-live-summary-tesla-rung")
    }

    /// The dead affordance is off the live page. It goes nowhere (no tipping
    /// backend), and it names a role this product does not have.
    func testTheTipSectionIsHiddenOnLive() {
        let app = launch(scene: "riderSummaryLive")
        XCTAssertFalse(app.staticTexts[Self.tipLabel].exists)
        for amount in ["$3", "$5", "$8", "Custom"] {
            XCTAssertFalse(app.buttons[amount].exists, "\(amount) opens a joke card and takes no payment")
        }
    }

    /// **THE STRAIGHT LINE IS NEVER DRAWN ON LIVE.** With the provider returning its
    /// documented two-point degradation (`MRT_ROUTE_UNAVAILABLE=1` — exactly what
    /// MKDirections throttled/offline produces), the hero keeps its endpoint pins
    /// and draws no route, and the distance tile goes with it: both are refused by
    /// the same fact, so the page cannot measure a line it will not draw.
    func testAStraightFallbackIsNeitherDrawnNorMeasured() {
        let app = launch(scene: "riderSummaryLive", routeUnavailable: true)
        XCTAssertTrue(app.staticTexts[Self.tripLabel].exists,
                      "the trip span does not depend on the route")
        XCTAssertFalse(measuredDistance(app).exists,
                       "a great-circle guess is not the trip's distance — this is the 14.2 mi defect")
        // MYR-422 — and this scene is now the whole ladder failing: rung 1 refused by
        // the server (403), rung 2 refused by the predicate. The row still stands,
        // carrying the trip tile and two dashes.
        XCTAssertTrue(app.staticTexts[Self.fsdLabel].exists)
        XCTAssertTrue(app.staticTexts[Self.dash].exists)
        attach(named: "myr422-live-summary-pins-only")
    }

    /// **THE SIM PAGE IS UNTOUCHED.** Everything the live arm drops is still here,
    /// which is what the `summary` drift-gate capture depends on.
    func testTheSimulatedSummaryKeepsThePrototypesIllustration() {
        let app = launch(scene: "summary")
        XCTAssertTrue(app.staticTexts[Self.tripLabel].exists)
        XCTAssertTrue(app.staticTexts[Self.fsdLabel].exists)
        XCTAssertTrue(app.staticTexts[Self.autonomyLabel].exists)
        XCTAssertTrue(app.staticTexts[Self.tipLabel].exists)
        XCTAssertFalse(measuredDistance(app).exists,
                       "the live-only measurement must not leak onto the fixture page")
        attach(named: "myr414-sim-summary")
    }
}
