import XCTest

// MARK: - MYR-398 v2 — photographing a surface this app does not draw
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
// v2 SWEEPS THE WHOLE TWELVE-ROW MATRIX rather than four frames, because the
// redesign changed what every one of them renders and six had no capture route at
// all before this round. The rows are `design/la/la-data.jsx`'s, in its order, so
// the attachments can be read straight against the board.
//
// WHAT THIS SUITE DELIBERATELY DOES NOT CLAIM. The LOCK-SCREEN card still has no
// route: `simctl` has no lock command, XCUITest cannot lock a device, and the
// Simulator's own Device ▸ Lock is a menu a human clicks. That gap is stated in the
// PR rather than papered over — a capture of the expanded island is not a capture
// of the lock screen, and the two lay out differently (different tile size,
// different chip placement, a ground we draw versus one the hardware owns).
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

    /// la-data rows 1-6 — everything that is still happening.
    ///
    /// The set is chosen so the island's two trailing vocabularies are both covered
    /// and can be told apart at a glance: `accepted` / `enroute` carry the FIGURE
    /// (15/600 tabular), and `requested` / `noProgress` / `arrived` / `enrouteNoETA`
    /// carry the four status strings (14.5/500) from the client's own compact table
    /// — Requested / On the way / Arrived / Arriving. v1 rendered the chip's long
    /// word in that slot.
    func testTheIslandRendersEveryLiveState() throws {
        for state in ["requested", "accepted", "noProgress", "arrived", "enroute", "enrouteNoETA"] {
            captureBothIslandStates(state)
        }
    }

    /// la-data rows 8-12 — the endings.
    ///
    /// All five collapse to `Done` / `Ended` / `Ride` on the island while keeping
    /// five different chips on the card, which is the pair the frames are read for.
    /// `expired` is the width case: "Reservation expired" is the widest chip in the
    /// set and is what the brand row has to hold without reflowing.
    func testTheIslandRendersEveryEnding() throws {
        for state in ["completed", "declined", "cancelled", "expired", "unknown"] {
            captureBothIslandStates(state)
        }
    }

    /// la-data row 7 — staleness, which cannot be seeded and has to be WAITED FOR.
    ///
    /// ActivityKit offers no way to force `isStale`, and a stale-date already in the
    /// past at `request` time is ignored or clamped (established by capture in
    /// MYR-172, not by reading), so the scene hands it a date ~8s out and this test
    /// waits for the deadline to pass. Both sides are photographed from ONE
    /// Activity, which is what makes the pair a before/after of exactly staleness:
    /// the fresh frame carries the confident figure, and the stale one should keep
    /// that figure at 45% while the chip becomes "Not updating".
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

    /// **DO THE TWO LONGEST COMPACT STRINGS FIT?**
    ///
    /// The board's rule was "one word, never truncates" — and the first half was
    /// how the second half was guaranteed. The client's 2026-07-31 compact table
    /// breaks it repeatedly: **"Dropped off"** (11), **"Ride ended"** (10), **"On
    /// the way"** (10) and **"Requested"** (9). So the guarantee has to come from a
    /// measurement instead — a character count cannot answer whether a string fits a
    /// system-sized region at 14.5/500 beside a 16pt arrow, and the compact pill's
    /// own width grows only until the leading region's budget runs out.
    ///
    /// ⚠️ **THIS TEST ALREADY EARNED ITS KEEP.** The client's directed phrase for
    /// the three unhappy endings was **"Ride cancelled"** (14), and the first run of
    /// this method photographed it rendering as **"Ride cancell…"** with the pill
    /// grown wide enough to evict the status bar's wifi and battery glyphs. Measured
    /// in that capture: 91.3pt of text where the slot's ceiling is ~91pt. The
    /// shipped phrase is the widest passing alternative — see
    /// `RideActivityCopy.compactWord` for the full ladder and the reasoning.
    ///
    /// All four are captured. A truncation shows as an ellipsis in the trailing
    /// slot, and the finding goes in the PR **with the capture and the widest
    /// passing alternative** rather than the copy being quietly shortened.
    func testTheLongestCompactWordsFitTheSlot() throws {
        // cancelled → "Ride ended"  · completed → "Dropped off"
        // noProgress → "On the way" · requested → "Requested"
        for state in ["cancelled", "completed", "noProgress", "requested"] {
            let app = startActivity(state: state)
            XCUIDevice.shared.press(.home)
            Thread.sleep(forTimeInterval: 3)
            attach(XCUIScreen.main.screenshot(), named: "island-compact-width-\(state)")
            app.terminate()
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
    /// It is also the regression guard for the mechanism: this test FAILED to hold
    /// still on the first implementation of this branch, which followed the
    /// handoff's SwiftUI note 1 and put a 1s `TimelineView(.periodic)` in the
    /// headline. (In the event it held still there too — ActivityKit does not tick a
    /// periodic timeline between content updates — so the ruling and the platform
    /// agree, and this build now has no clock in the widget process at all.)
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
