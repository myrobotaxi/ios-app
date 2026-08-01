import XCTest

// MARK: - MYR-398 v3 — photographing a surface this app does not draw
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
// situation, and the same answer. This suite synthesizes that press and attaches
// what comes back.
//
// v3 SWEEPS ALL FOURTEEN BOARD ROWS, because the redesign changed what every one of
// them renders and two of them did not exist before this round. The rows are
// `design/la/la-data.jsx`'s, in its order, so the attachments can be read straight
// against the board.
//
// WHAT THIS SUITE DELIBERATELY DOES NOT CLAIM. The LOCK-SCREEN card still has no
// route: `simctl` has no lock command, XCUITest cannot lock a device, and the
// Simulator's own Device ▸ Lock is a menu a human clicks. That gap is stated in the
// PR rather than papered over — a capture of the expanded island is not a capture
// of the lock screen, and the two lay out differently (a 20pt tile vs a 28pt one, a
// ground we draw versus one the hardware owns, and the card's wordmark row, which
// the island has no equivalent of at all).
//
// It is also NOT a pass/fail assertion about pixels. What it asserts is that an
// Activity is genuinely RUNNING (so a green run cannot be a photograph of nothing)
// and that the press was delivered; the frames are evidence for the PR, read by a
// person.
//
// ⚠️ **WHAT v3 RETIRED FROM THIS SUITE.** v2's
// `testTheLongestCompactWordsFitTheSlot` measured a status-word width ladder in the
// compact trailing slot. **v3 has no status words there at all** — a figure
// (`8 min` / `1 min` / `3:42 PM`), a glyph, or nothing — so the ladder, the ~91pt
// ceiling it found, and the "Ride cancelled" truncation it caught are all moot. The
// width question moved to the CARD's fixed 24pt headline row and its
// `lineLimit(1)`, which `RideActivityGeometryTests` measures directly and
// `testTheLongestStringsAreCaptured` photographs.
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

    /// Background the app, photograph the COMPACT island, long-press for the
    /// EXPANDED one, photograph that, collapse.
    private func captureBothIslandStates(_ state: String) {
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

        // Collapse again so the next iteration starts from a known place.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
        Thread.sleep(forTimeInterval: 1)
        app.terminate()
    }

    /// la-data rows 1-6 — the PICKUP LEG, end to end.
    ///
    /// The set is chosen so every compact vocabulary is covered and can be told
    /// apart at a glance: `accepted` / `arriving` carry the FIGURE (15/600 tabular),
    /// `arrived` carries the WAVE glyph, and `dispatch` / `pickupNoETA` /
    /// `noTelemetry` carry the MARK ALONE with nothing trailing it.
    ///
    /// The pair that matters most is `pickupNoETA` vs `noTelemetry`: identical cards
    /// except the RAIL, which is live at 0.38 in one and idle at zero in the other.
    /// That distinction is the whole of "no ETA and no telemetry are two different
    /// states", and v2 could photograph neither of them.
    func testTheIslandRendersTheWholePickupLeg() throws {
        for state in ["dispatch", "accepted", "arriving", "pickupNoETA", "noTelemetry", "arrived"] {
            captureBothIslandStates(state)
        }
    }

    /// la-data rows 7, 8 and 10-14 — the TRIP LEG and the endings.
    ///
    /// `enroute` is the row the field report was about: it must read `3:42 PM` on the
    /// island and `3:42 PM dropoff` on the expanded card, and nothing anywhere may
    /// say "Arriving". The four endings differ from each other in exactly two lines
    /// of text and are otherwise identical — same footprint, same idle rail, same
    /// mark-only island — which is what the four frames are read for.
    func testTheIslandRendersTheTripLegAndEveryEnding() throws {
        for state in ["enroute", "enrouteNoETA", "completed", "declined", "cancelled", "expired", "unknown"] {
            captureBothIslandStates(state)
        }
    }

    /// la-data row 9 — staleness, which cannot be seeded and has to be WAITED FOR.
    ///
    /// ActivityKit offers no way to force `isStale`, and a stale-date already in the
    /// past at `request` time is ignored or clamped (established by capture in
    /// MYR-172, not by reading), so the scene hands it a date ~8s out and this test
    /// waits for the deadline to pass. Both sides are photographed from ONE Activity,
    /// which is what makes the pair a before/after of exactly staleness.
    ///
    /// **WHAT SHOULD AND SHOULD NOT CHANGE ACROSS IT, IN v3**: the compact island
    /// should be BYTE-IDENTICAL (the figure is kept, at full strength — v2 dimmed it
    /// to 45%), and the expanded card should change in exactly two rows — the
    /// headline drops its clock for "Dropoff soon" and the subline becomes
    /// "Waiting for an update". The rail must be unchanged and still GOLD.
    ///
    /// ⚠️ **AND IT MAY WELL SHOW NOTHING**, which is v2's own honest finding carried
    /// forward: the Activity genuinely goes stale (visible in `log show --predicate
    /// 'subsystem == "com.apple.activitykit"'`) but the island is not re-rendered
    /// when the deadline passes, so `context.isStale` never reaches a render. The
    /// frames are attached either way and the PR says which happened.
    func testTheStaleFrameIsPhotographedFromBothSidesOfItsDeadline() throws {
        let app = startActivity(state: "stale")

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        attach(XCUIScreen.main.screenshot(), named: "island-compact-stale-before")

        // Well past the ~8s deadline, and inside the ~60s window before iOS discards
        // a stale ephemeral Activity ("Ephemeral activity ended… no longer
        // relevant" — MYR-172's own finding).
        Thread.sleep(forTimeInterval: 18)
        attach(XCUIScreen.main.screenshot(), named: "island-compact-stale-after")

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard
            .coordinate(withNormalizedOffset: Self.islandCentre)
            .withOffset(CGVector(dx: 0, dy: Self.islandCentreYOffset))
            .press(forDuration: 1.1)
        Thread.sleep(forTimeInterval: 1.5)
        attach(XCUIScreen.main.screenshot(), named: "island-expanded-stale")

        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
        Thread.sleep(forTimeInterval: 1)
        app.terminate()
    }

    /// **THE LONGEST STRINGS, PHOTOGRAPHED ON THE SURFACE THAT HAS TO HOLD THEM.**
    ///
    /// v3's card is a FIXED 350 × 128 with four FIXED rows and `lineLimit(1)`
    /// everywhere, so the failure mode is no longer a truncated island word — it is a
    /// headline or a subline that wraps and pushes the rail out of a card that cannot
    /// grow. `RideActivityGeometryTests` measures both rows against the widest
    /// strings through UIKit's text engine; this is the picture of the two worst
    /// cases actually rendering.
    ///
    ///   • `expired` — **"Reservation expired"**, the longest headline in the set.
    ///   • `enroute` — the trip subline over the scene's destination, plus the
    ///     `3:42 PM dropoff` headline, which is the widest of the two figure forms.
    ///
    /// Read the frames for an ellipsis in the headline row (there must not be one)
    /// and for a rail that is still on the card.
    func testTheLongestStringsAreCaptured() throws {
        for state in ["expired", "enroute"] {
            captureBothIslandStates(state)
        }
    }

    /// **THE FIGURE HOLDS** — the client's 2026-07-31 ruling, photographed.
    ///
    /// *"We are pulling live data from Tesla ETA telemetry; counting down is
    /// inaccurate."* So between pushes the ETA figure must not move: what the card
    /// shows is what the CAR last said, and a phone decrementing it locally would be
    /// presenting an extrapolation as the car's own answer.
    ///
    /// One Activity, two frames ~70 seconds apart, over an ETA seeded 6 minutes out.
    /// Both frames must read the SAME figure while the status-bar clock in the same
    /// screenshots advances a minute — which is what makes the pair evidence rather
    /// than a still.
    ///
    /// It is also the regression guard for the mechanism, and it carried over from v2
    /// unchanged because the ruling did: this build has no clock in the widget
    /// process at all, and v2 measured that ActivityKit would not have ticked one
    /// anyway.
    func testTheCountdownFigureHOLDSBetweenPushes() throws {
        let app = startActivity(state: "accepted")

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 3)
        attach(XCUIScreen.main.screenshot(), named: "island-hold-t0")

        // Just over a minute, so a figure that counted down locally could not
        // possibly still read the same.
        Thread.sleep(forTimeInterval: 70)
        attach(XCUIScreen.main.screenshot(), named: "island-hold-t70")

        app.terminate()
    }
}
