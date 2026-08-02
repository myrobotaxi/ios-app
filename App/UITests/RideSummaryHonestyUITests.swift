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
    private static let distanceLabel = "DISTANCE"
    private static let fsdLabel = "FSD MILES"
    private static let autonomyLabel = "AUTONOMOUS"
    private static let tipLabel = "TIP YOUR DRIVER"

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

    private func attach(named name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// **THE CLIENT'S THREE NUMBERS ARE GONE FROM THE LIVE PAGE**, and the two that
    /// replace them are the ones with a datum behind them.
    func testTheLiveSummaryRendersOnlyDerivableStats() {
        let app = launch(scene: "riderSummaryLive")
        // The road route lands in ~1s and the distance tile appears with it.
        XCTAssertTrue(app.staticTexts[Self.distanceLabel].waitForExistence(timeout: 25),
                      "the leg-2 road route resolved, so its length is a real trip distance")
        XCTAssertTrue(app.staticTexts[Self.tripLabel].exists,
                      "the trip span was observed end to end, so it is derivable")
        XCTAssertFalse(app.staticTexts[Self.fsdLabel].exists,
                       "no drive record joins this ride, so no FSD claim may be made")
        XCTAssertFalse(app.staticTexts[Self.autonomyLabel].exists,
                       "a human/FSD-supervised owner drove; 100% autonomous was a literal")
        attach(named: "myr414-live-summary-road-route")
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
        XCTAssertFalse(app.staticTexts[Self.distanceLabel].exists,
                       "a great-circle guess is not the trip's distance — this is the 14.2 mi defect")
        attach(named: "myr414-live-summary-pins-only")
    }

    /// **THE SIM PAGE IS UNTOUCHED.** Everything the live arm drops is still here,
    /// which is what the `summary` drift-gate capture depends on.
    func testTheSimulatedSummaryKeepsThePrototypesIllustration() {
        let app = launch(scene: "summary")
        XCTAssertTrue(app.staticTexts[Self.tripLabel].exists)
        XCTAssertTrue(app.staticTexts[Self.fsdLabel].exists)
        XCTAssertTrue(app.staticTexts[Self.autonomyLabel].exists)
        XCTAssertTrue(app.staticTexts[Self.tipLabel].exists)
        XCTAssertFalse(app.staticTexts[Self.distanceLabel].exists,
                       "the live-only tile must not leak onto the fixture page")
        attach(named: "myr414-sim-summary")
    }
}
