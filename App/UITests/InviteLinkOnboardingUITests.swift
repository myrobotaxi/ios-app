import XCTest

// MARK: - MYR-426 — the invite link through sign-in and rider setup
//
// THE CLIENT'S SPEC, verbatim (2026-08-02, external-beta launch set): *"upon
// logging with apple their code should auto fill in the rider setup flow if new
// account and of course they are coming from clicking the link. if they didnt
// click the link then they can just enter their code. if they already signed up
// they could just click on the link and we'll automatically fill the code and
// add the vehicle or they can manually enter it in the app."*
//
// Three paths, and this file is one test per path plus the negative that keeps
// the first two from being reached by accident.
//
// WHY A UI TEST AND NOT ONLY `InviteLinkRoutingTests`. That suite is the pure
// matrix and it is the right guard for the DECISION. It cannot show that the
// SCREEN consults it — the repo's own lesson from MYR-387 defect 2 and
// MYR-369's `VehicleRideShare.display`, a pure rule with good tests and no
// consumer. Everything asserted here is a real launch: the mailbox holding a
// URL delivered before `RootView` exists, `RootView` draining it, the routing
// matrix answering, `InviteCodeFlow` seating the code in its six cells and the
// EXISTING `onChange` auto-submitting on the sixth character.
//
// WHAT THIS FILE CANNOT PROVE, and no test in this repo can: that iOS hands the
// app the `NSUserActivity` at all. That is a property of the AASA, the
// entitlement and the provisioning profile — three things that must agree
// (MYR-346) — and it needs a physical device. `MRT_JOIN_LINK` stands in for the
// system's delivery and NOTHING else: it posts to `InviteLinkBridge` from
// `RootView.init`, i.e. in the same before-the-view-exists window a real
// activation lands in, so the held-then-drained path is the real one.
final class InviteLinkOnboardingUITests: XCTestCase {

    private let code = "RBO246"

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(scene: String, joinLink: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MRT_SCENE"] = scene
        if let joinLink { app.launchEnvironment["MRT_JOIN_LINK"] = joinLink }
        app.launch()
        return app
    }

    private func attach(_ app: XCUIApplication, named: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = named
        shot.lifetime = .keepAlways
        add(shot)
    }

    private var chooserHeadline: String { "How do you want to use MyRoboTaxi today?" }

    // MARK: 1 — NEW ACCOUNT via link

    /// THE MAIN GAP. A fresh account's first screen after Apple sign-in is the
    /// mode chooser (`PostAuthRouter`: a real user with no stored `ViewMode`),
    /// and on the live path it is the ONLY first-run screen — `.emptyState` is
    /// that router's SIM/static-token arm and a real new tester never sees it.
    ///
    /// Before MYR-426 the held code sat in `.awaitIdle` behind that chooser: the
    /// tester was asked a question they could answer wrong, and the code arrived
    /// afterwards as a sheet over whichever shell they had picked. Now the join
    /// step opens carrying the code and redeems itself.
    ///
    /// ⚠️ **WHAT THIS TEST CAN AND CANNOT SEE.** The join step is TRANSIENT here
    /// — the prefill submits on the sixth character and the simulated redeem
    /// answers immediately, so "Enter invite code" is gone before XCUITest's
    /// first poll (a first cut asserted on it and failed for that reason, on a
    /// build where the frame it was looking for was correct). The evidence that
    /// the code was CARRIED rather than typed is that the success screen is
    /// reached with **no interaction at all** on a scene whose only input is the
    /// link: `autoSubmitsSampleCode` is false for `modeChooser` (it is set on
    /// `riderInviteRateLimited` / `riderInviteJoined` only), so `prefilledCode`
    /// is the only thing on this path that can have submitted anything.
    ///
    /// The NO-FLASH property is likewise not this test's to prove. A DEBUG scene
    /// enters the chooser by seeding `initialScreen`, so the drain happens on
    /// `onAppear`, one frame later; on the real path `routeAfterAuth` drains in
    /// the SAME state update it routes in, which is a property of that function
    /// and of the matrix, not of a frame a simulator can hand back.
    func testAFreshAccountsLinkAutoSubmitsAndTakesTheFirstRunGrammar() {
        let app = launch(scene: "modeChooser", joinLink: code)

        XCTAssertTrue(
            app.staticTexts["You're in"].waitForExistence(timeout: 25),
            "a code held through sign-in must open the join step and submit itself"
        )
        XCTAssertFalse(
            app.staticTexts[chooserHeadline].exists,
            "the link already answers the chooser's question; it must not still be asking"
        )
        // The CTA is the receipt for the ORIGIN. A fresh account gets
        // `.onboarding` — MYR-346's own treatment of a link on the first-run
        // choice screen — because a rider who has never seen this app wants the
        // walkthrough and has no shell to be returned to. `.deepLink` would read
        // "Done" here.
        XCTAssertTrue(
            app.buttons["Continue"].waitForExistence(timeout: 10),
            "first-run grammar: Continue into the rider tutorial, not the returning Done"
        )
        attach(app, named: "MYR-426 fresh account — joined, first-run CTA")
    }

    /// …and the sequence ENDS on the rider Live Map, which is the issue's own
    /// acceptance. Joined → RiderTutorial → the rider shell, watching the car
    /// the code just granted. Driven with real taps because the landing is three
    /// screens past the redeem and no single mounted view holds that.
    func testTheFreshAccountSequenceEndsOnTheRiderLiveMap() {
        let app = launch(scene: "modeChooser", joinLink: code)

        let cont = app.buttons["Continue"]
        XCTAssertTrue(cont.waitForExistence(timeout: 25), "the joined screen's CTA")
        cont.tap()

        let skip = app.buttons["Skip"]
        XCTAssertTrue(
            skip.waitForExistence(timeout: 20),
            "a fresh account gets the rider walkthrough before the map"
        )
        attach(app, named: "MYR-426 fresh account — rider tutorial")
        skip.tap()

        XCTAssertTrue(
            app.buttons["Live Map"].waitForExistence(timeout: 20),
            "the tester lands on the rider shell, where the joined vehicle is"
        )
        attach(app, named: "MYR-426 fresh account — rider Live Map")
    }

    // MARK: 2 — EXISTING ACCOUNT via link

    /// Tap → open → auto-fill → auto-submit → vehicle added → rider Live Map.
    ///
    /// This path already worked (MYR-346) and the test is the regression guard
    /// for it, because MYR-426 changes the screen set the matrix accepts on. The
    /// CTA reads "Done" here — `.deepLink`, a rider already past onboarding —
    /// and completing routes to the rider shell rather than the tutorial,
    /// because the car they just joined is on that map.
    func testAnExistingAccountsLinkAutoAddsTheVehicleAndLandsOnTheRiderMap() {
        let app = launch(scene: "ownerHome", joinLink: "https://myrobotaxi.app/join/\(code)")

        XCTAssertTrue(
            app.staticTexts["You're in"].waitForExistence(timeout: 25),
            "an existing account's link should redeem without a single tap"
        )
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "returning grammar: Done, not Continue")
        attach(app, named: "MYR-426 existing account — joined")

        done.tap()
        XCTAssertTrue(
            app.buttons["Live Map"].waitForExistence(timeout: 20),
            "completing a link-opened join lands on the rider shell, where the joined car is"
        )
        XCTAssertFalse(app.staticTexts["Enter invite code"].exists)
        attach(app, named: "MYR-426 existing account — rider Live Map")
    }

    // MARK: 3 — NO LINK (manual entry, unchanged)

    /// *"if they didnt click the link then they can just enter their code."*
    ///
    /// The pin is that MYR-426 added no automatic behaviour to the screen
    /// itself. With no link the six cells are EMPTY and nothing submits — the
    /// auto-submit belongs to `prefilledCode`, which is `nil` on every
    /// tap-reached presentation, and this is the assertion that would fail if a
    /// future change moved it onto the screen's appearance.
    func testWithNoLinkTheJoinStepOpensEmptyAndSubmitsNothing() {
        let app = launch(scene: "riderInviteEntry")

        XCTAssertTrue(
            app.staticTexts["Enter invite code"].waitForExistence(timeout: 20),
            "the manual-entry screen"
        )
        // Long enough to cover the prefill's `.task` and the 1.3s verifying beat
        // several times over. A negative needs a wait, or it proves only that the
        // screen is slow.
        XCTAssertFalse(
            app.staticTexts["You're in"].waitForExistence(timeout: 6),
            "nothing may redeem on its own when no code was handed in"
        )
        XCTAssertTrue(app.staticTexts["Enter invite code"].exists, "still on entry, waiting for a thumb")
        attach(app, named: "MYR-426 manual entry — empty, waiting")
    }

    /// The negative that keeps path 1 honest: WITHOUT a held code the chooser
    /// still asks its question. `.modeChooser` accepting an invite must not have
    /// become "the chooser is skipped", which would be a change to what every
    /// new account without a link is asked.
    func testTheModeChooserStillAsksWhenNoCodeIsHeld() {
        let app = launch(scene: "modeChooser")

        XCTAssertTrue(
            app.staticTexts[chooserHeadline].waitForExistence(timeout: 20),
            "a new account with no invite still chooses a shell"
        )
        XCTAssertFalse(app.staticTexts["Enter invite code"].exists)
        attach(app, named: "MYR-426 chooser — unchanged with no link")
    }
}
