import XCTest

// MARK: - MYR-352 — the banner brings its own room
//
// The copy matrix is asserted in `RiderIdleAvailabilityTests`; this is the
// LAYOUT half, and it exists because the first implementation got it wrong in a
// way no unit test could see. The rider idle card was a FIXED 286pt frame with a
// trailing `Spacer` absorbing the slack, and the banner is the first element that
// can exceed it — its headline wraps to two lines for the longer reasons even at
// 393pt. Dropped into the fixed frame, it pushed the Home/Work chips down
// underneath the floating nav.
//
// So the idle detent now grows by exactly what the banner measures
// (`RiderIdleBannerHeightKey` + `MRTMetrics.riderIdleBannerGap`), which is
// MYR-345's per-line-reserve rule. These tests are the structural guard that no
// future copy change may quietly eat the band again: the search bar the banner
// sits above, and the quick chips below it, must stay clear of the nav in EVERY
// variant — including the two-line one.
//
// The defect these guard is not hypothetical: it was the FIRST implementation of
// this issue, and its full-frame captures (attached to the PR) show the Home/Work
// chips sitting on top of the floating nav in all five variants — worst in
// `paused`, whose headline is the one that wraps.
final class RiderIdleBannerUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(reason: String?) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MRT_SCENE"] = reason == nil ? "riderNoRidesFleet" : "riderNoRides"
        if let reason { app.launchEnvironment["MRT_BUSY_REASON"] = reason }
        app.launch()
        return app
    }

    /// Matched across element types: `.accessibilityElement(children: .combine)`
    /// over a text row resolves to a static text on some runtimes and a container
    /// on others, and which one is not this test's business.
    private func banner(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "mrt.rider.noRidesBanner").firstMatch
    }

    /// Every variant the scene pair can produce: the four single-vehicle reasons
    /// (`paused` is the two-line one AND the one with no second line) plus the
    /// multi-vehicle generic.
    private static let variants: [String?] = ["busy", "inService", "offline", "paused", nil]

    // MARK: The banner exists and says what the predicate decided

    func testTheBannerRendersOnEveryVariant() {
        for variant in Self.variants {
            let app = launch(reason: variant)
            XCTAssertTrue(
                banner(app).waitForExistence(timeout: 20),
                "the banner should render for \(variant ?? "fleet")"
            )
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "MYR-352 idle banner \(variant ?? "fleet")"
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
        }
    }

    // MARK: The banner brings its own room

    /// The search bar is what the banner sits ABOVE — it must still be there, in
    /// full, and tappable. A banner that pushed it anywhere would have taken away
    /// the affordance the whole screen is for.
    func testTheSearchBarStaysBelowTheBannerAndRemainsTappable() {
        for variant in Self.variants {
            let app = launch(reason: variant)
            let bannerEl = banner(app)
            XCTAssertTrue(bannerEl.waitForExistence(timeout: 20))

            let search = app.buttons["Where to?"]
            XCTAssertTrue(search.waitForExistence(timeout: 5), "the search bar, \(variant ?? "fleet")")
            XCTAssertTrue(search.isHittable, "the search bar must stay tappable, \(variant ?? "fleet")")
            XCTAssertGreaterThan(
                search.frame.minY, bannerEl.frame.maxY - 1,
                "the banner sits ABOVE the search bar (client's ask), \(variant ?? "fleet")"
            )
            app.terminate()
        }
    }

    /// The bug the fixed frame produced. The quick chips are the LAST row in the
    /// card, so they are what a card that outgrew its band pushes into the
    /// floating nav.
    func testTheQuickChipsStayClearOfTheFloatingNav() {
        for variant in Self.variants {
            let app = launch(reason: variant)
            XCTAssertTrue(banner(app).waitForExistence(timeout: 20))

            let home = app.buttons["Home"]
            XCTAssertTrue(home.waitForExistence(timeout: 5), "the Home quick chip, \(variant ?? "fleet")")
            let nav = app.buttons["Live Map"]
            XCTAssertTrue(nav.waitForExistence(timeout: 5), "the floating nav, \(variant ?? "fleet")")
            XCTAssertLessThanOrEqual(
                home.frame.maxY, nav.frame.minY,
                "the quick chips must clear the floating nav — chip \(home.frame) vs nav \(nav.frame), \(variant ?? "fleet")"
            )
            XCTAssertTrue(home.isHittable, "and stay tappable, \(variant ?? "fleet")")
            app.terminate()
        }
    }
}
