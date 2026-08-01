import XCTest

// MARK: - MYR-398 — photographing a surface this app does not draw
//
// The redesigned Live Activity is rendered by the `MyRoboTaxiWidgets` process onto
// the SYSTEM's own surfaces, so booting a screen and screenshotting the app
// captures nothing (MYR-172 established that; the `riderLiveActivity` scene starts
// a real Activity and the picture is of the system).
//
// `simctl` reaches the COMPACT island and no further: backgrounding the app shows
// it, and `simctl io screenshot` takes the whole screen. The EXPANDED island needs
// a long press on a SpringBoard element, which is a gesture headless tooling cannot
// perform — the same `ExpandedRouteUITests` / `DriveSummaryCelebrationUITests`
// situation, and the same answer. This suite synthesizes that press against
// SpringBoard and attaches what comes back.
//
// WHAT THIS SUITE DELIBERATELY DOES NOT CLAIM. The LOCK-SCREEN card still has no
// route: `simctl` has no lock command, XCUITest cannot lock a device, and the
// Simulator's own Device ▸ Lock is a menu a human clicks. That gap is stated in the
// PR rather than papered over — a capture of the expanded island is not a capture
// of the lock screen, and the two lay out differently.
//
// It is also NOT a pass/fail assertion about pixels. What it asserts is that an
// Activity is genuinely RUNNING (so a green run cannot be a photograph of nothing)
// and that the press was delivered; the frames are evidence for the PR, read by a
// person.
final class RideActivityIslandUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// The Dynamic Island's own rectangle on iPhone 17 Pro, in points from the
    /// physical top-left. Re-measured here rather than imported from anywhere: it
    /// is the SYSTEM's geometry, not this app's, and nothing in this repo may
    /// pretend to own it.
    private static let islandCentre = CGVector(dx: 0.5, dy: 0.0)
    private static let islandCentreYOffset: CGFloat = 22

    private func startActivity(state: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MRT_SCENE"] = "riderLiveActivity"
        app.launchEnvironment["MRT_ACTIVITY_STATE"] = state
        app.launch()
        // The scene starts the Activity from `RootView.init`, through the shipping
        // `SystemRideActivityPresenter`. Give it a beat to be requested before the
        // app leaves the foreground — an Activity that has not been granted yet
        // renders nothing at all, and the resulting empty island looks exactly like
        // a layout bug.
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 20),
            "the rider shell should be up before the Activity is photographed"
        )
        // The pre-start sweep costs up to ~1.5s on its own (`RideActivityDebugLauncher`
        // retries until ActivityKit's asynchronously-restored `activities` list is
        // empty), and the FIRST launch in a test method is the slow one. Measured:
        // 2.5s left the first iteration of each method photographing an island that
        // had not appeared yet — which looks exactly like a widget that renders
        // nothing.
        Thread.sleep(forTimeInterval: 5)
        return app
    }

    private func attach(_ screenshot: XCUIScreenshot, named: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.lifetime = .keepAlways
        attachment.name = named
        add(attachment)
    }

    /// COMPACT → EXPANDED, for both legs.
    ///
    /// Leg one is the whole point of the redesign — "Pick up in 6:00", "Meet at
    /// Ferry Building" and a track a third of the way along — and leg two is the
    /// state the client photographed as *"looks terrible"*.
    func testTheIslandExpandsOnEachLeg() throws {
        for state in ["accepted", "enroute"] {
            let app = startActivity(state: state)

            XCUIDevice.shared.press(.home)
            Thread.sleep(forTimeInterval: 3)

            attach(XCUIScreen.main.screenshot(), named: "island-compact-\(state)")

            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let island = springboard
                .coordinate(withNormalizedOffset: Self.islandCentre)
                .withOffset(CGVector(dx: 0, dy: Self.islandCentreYOffset))
            island.press(forDuration: 1.1)
            Thread.sleep(forTimeInterval: 1.5)

            attach(XCUIScreen.main.screenshot(), named: "island-expanded-\(state)")

            // Collapse again so the next iteration starts from a known place.
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
            Thread.sleep(forTimeInterval: 1)
            app.terminate()
        }
    }

    /// The two DEGRADED frames, which are the honesty rules made visible.
    ///
    /// `noProgress` is a car with no active navigation route: §7.21.3 sends neither
    /// `eta` nor `progress`, so the card must read "Heading to pickup" over "Meet at
    /// Ferry Building" with NO track and no invented number. `arrived` is the other
    /// end — no `eta` by construction, and a `progress` of exactly `1`.
    func testTheDegradedFramesRenderWithoutInventingAnything() throws {
        for state in ["noProgress", "arrived"] {
            let app = startActivity(state: state)

            XCUIDevice.shared.press(.home)
            Thread.sleep(forTimeInterval: 3)
            attach(XCUIScreen.main.screenshot(), named: "island-compact-\(state)")

            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            springboard
                .coordinate(withNormalizedOffset: Self.islandCentre)
                .withOffset(CGVector(dx: 0, dy: Self.islandCentreYOffset))
                .press(forDuration: 1.1)
            Thread.sleep(forTimeInterval: 1.5)
            attach(XCUIScreen.main.screenshot(), named: "island-expanded-\(state)")

            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
            Thread.sleep(forTimeInterval: 1)
            app.terminate()
        }
    }
}
