import XCTest

// MARK: - MYR-355 / MYR-366 — the Account section and the offboarding flow, on the
// running app
//
// App Store Guideline 5.1.1(v) is a requirement about what a REVIEWER can find and
// tap, so the assertions that matter are about the running screen: the section
// exists on both shells, its row says what it should, the destructive row is a
// real 44pt target, and one tap on it walks the real flow.
//
// It is a UI test rather than a unit test for two measured reasons. A SwiftUI
// hierarchy hosted in a `UIHostingController` inside a unit test publishes NO
// accessibility tree at all (the walk returns zero elements, so any "contains"
// assertion over it is vacuous either way). And MYR-345's lesson is that a tap
// target has to be asserted on the frame the SYSTEM reports — a `contentShape`
// inset shipped 43⅓pt while every test that read the inset was green.
final class AccountDeletionUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// The 44pt hard rule (CLAUDE.md). Re-stated rather than imported: a UI test
    /// that could read `MRTMetrics.minTapTarget` would prove nothing about what
    /// landed on screen.
    private static let minTapTarget: CGFloat = 44

    private func launch(scene: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MRT_SCENE"] = scene
        app.launch()
        return app
    }

    /// A stepper ROW is ONE accessibility element — the step and its status are
    /// one fact, not two stops for a screen reader — so its label is
    /// "{step}. {status}." and an exact `staticTexts[...]` lookup would never
    /// match. This finds the row by its step text, whatever status it currently
    /// carries.
    private func stepperRow(_ step: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", step))
            .firstMatch
    }

    private func attach(_ app: XCUIApplication, named: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        shot.name = named
        add(shot)
    }

    /// Scroll the settings list until the delete row is on screen, or give up.
    /// The owner scene starts at the bottom anchor already; the rider's does not,
    /// which is exactly why this walks rather than assumes.
    @discardableResult
    private func revealDeleteRow(in app: XCUIApplication) -> XCUIElement {
        let row = app.descendants(matching: .any)["mrt.deleteAccountRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the Delete account row should exist in Settings")
        var swipes = 0
        while !row.isHittable && swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(row.isHittable, "the Delete account row should be reachable by scrolling Settings")
        return row
    }

    // MARK: Presence

    func testTheOwnerSettingsScreenCarriesAnAccountSectionWithTheDeleteRow() {
        assertAccountSection(in: launch(scene: "ownerSettings"), named: "owner-account-section")
    }

    /// And on the rider shell — the guideline is about the ACCOUNT, and both shells
    /// are the same account.
    func testTheRiderSettingsScreenCarriesTheSameAccountSection() {
        assertAccountSection(in: launch(scene: "riderSettings"), named: "rider-account-section")
    }

    private func assertAccountSection(in app: XCUIApplication, named: String) {
        revealDeleteRow(in: app)
        XCTAssertTrue(app.staticTexts["Account"].exists, "no Account header — 5.1.1(v) needs it discoverable")
        XCTAssertTrue(app.staticTexts["Delete account"].exists)
        attach(app, named: named)
    }

    // MARK: The identity is NOT repeated here (MYR-366)
    //
    // The client's report: *"It shows the email again even though its displayed at
    // the top of the settings."* `UserProfile.settingsDisplayName` is
    // `name ?? email ?? "Your account"` and Apple hands the NAME over only on the
    // FIRST authorization, so for his account the display name IS the email — shown
    // as the profile card's name, as its email, and then a third time by the
    // Account section's own row. The row is gone; this is the guard that it stays
    // gone.

    func testTheAccountSectionNoLongerRepeatsTheIdentity() {
        for scene in ["ownerSettings", "riderSettings"] {
            let app = launch(scene: scene)
            revealDeleteRow(in: app)
            XCTAssertFalse(
                app.descendants(matching: .any)["mrt.accountNameRow"].exists,
                "\(scene) still carries the duplicate identity row"
            )
            XCTAssertFalse(
                app.staticTexts["Set by Apple when you signed in"].exists,
                "\(scene) still carries the removed provenance caption"
            )
            app.terminate()
        }
    }

    // MARK: The tap target

    func testBothDeleteRowsMeetTheMinimumTapTarget() {
        for scene in ["ownerSettings", "riderSettings"] {
            let app = launch(scene: scene)
            let row = revealDeleteRow(in: app)
            XCTAssertGreaterThanOrEqual(
                row.frame.height, Self.minTapTarget,
                "\(scene): the Delete account row is \(row.frame.height)pt tall"
            )
            app.terminate()
        }
    }

    // MARK: No rename affordance
    //
    // Asserted rather than merely intended: there is no profile-update endpoint on
    // the backend, so an Edit / Rename control here would be an affordance that
    // cannot reach a server — the MYR-342 gate lesson in miniature.

    func testNeitherSettingsScreenOffersARenameAffordance() {
        for scene in ["ownerSettings", "riderSettings"] {
            let app = launch(scene: scene)
            revealDeleteRow(in: app)
            for forbidden in ["Edit name", "Change name", "Rename", "Edit profile"] {
                XCTAssertFalse(
                    app.buttons[forbidden].exists || app.staticTexts[forbidden].exists,
                    "\(scene) offers \"\(forbidden)\", which no endpoint can satisfy"
                )
            }
            app.terminate()
        }
    }

    // MARK: The real path, driven by real taps

    /// "Keep my account" backs out leaving the user exactly where they were, and —
    /// the part that matters — NOTHING has started. The offboarding screen must not
    /// be reachable from a dialog the reader declined.
    func testKeepMyAccountBacksOutWithoutStartingTheOffboarding() {
        let app = launch(scene: "ownerSettings")
        let row = revealDeleteRow(in: app)

        row.tap()
        XCTAssertTrue(app.staticTexts["Delete your account?"].waitForExistence(timeout: 5))
        attach(app, named: "owner-confirm-dialog-by-tap")

        app.buttons["Keep my account"].firstMatch.tap()
        XCTAssertFalse(
            app.descendants(matching: .any)["mrt.offboardingScreen"].waitForExistence(timeout: 2),
            "declining the dialog must not open the offboarding screen"
        )
        XCTAssertTrue(app.staticTexts["Delete account"].exists, "still signed in, still on Settings")
    }

    /// MYR-366 — the whole flow as a thumb performs it, on the OWNER shell: one
    /// dialog, then the stepper, then the two-manual-steps ending. Nothing is
    /// seeded; the DEBUG scenes stand in for these taps only for the headless
    /// captures.
    ///
    /// **The delete succeeds here** (the simulated path has no server account, so
    /// the absent endpoint IS the `204` — see `AccountDeletionFlow.performDelete`),
    /// which is what makes the ending reachable at all. Done is deliberately NOT
    /// tapped: it would wipe the session, and this test's subject ends at the
    /// ending.
    func testTappingDeleteAccountWalksTheStepperToTheOwnerEnding() {
        let app = launch(scene: "ownerSettings")
        revealDeleteRow(in: app).tap()

        XCTAssertTrue(app.staticTexts["Delete your account?"].waitForExistence(timeout: 5))
        app.buttons["Delete permanently"].firstMatch.tap()

        let screen = app.descendants(matching: .any)["mrt.offboardingScreen"]
        XCTAssertTrue(screen.waitForExistence(timeout: 5), "the confirm opens the offboarding flow")
        XCTAssertTrue(app.staticTexts["Deleting your account"].exists)
        // Every owner step is on screen from the first frame — the stepper shows
        // the WHOLE sequence and checks it off, rather than revealing it a line at
        // a time.
        XCTAssertTrue(stepperRow("Rides closed out", in: app).exists)
        XCTAssertTrue(stepperRow("Account deleted", in: app).exists)
        attach(app, named: "owner-stepper-by-tap")

        let ending = app.staticTexts["Two steps only you can do"]
        XCTAssertTrue(ending.waitForExistence(timeout: 15), "the completed stepper transitions to the ending")
        // The two manual steps, by their literal menu paths — restated here rather
        // than imported, because a UI test that read the app's own constant would
        // prove the constant equals itself.
        XCTAssertTrue(app.staticTexts["Remove the MyRoboTaxi key"].exists)
        XCTAssertTrue(app.staticTexts["Revoke app access"].exists)
        XCTAssertTrue(
            app.staticTexts["Car touchscreen → Controls → Locks → tap the MyRoboTaxi key → Remove"].exists
        )
        XCTAssertTrue(
            app.staticTexts["Tesla app → Profile → Third-Party Apps → MyRoboTaxi → Remove Access"].exists
        )
        XCTAssertTrue(app.buttons["Done"].exists)
        attach(app, named: "owner-ending-by-tap")
    }

    /// The RIDER's flow ends on the check-hero, and must NOT offer the owner's two
    /// Tesla steps — a rider never enrolled a key and never authorized Tesla.
    func testTheRiderFlowEndsOnTheCheckHeroWithNoManualSteps() {
        let app = launch(scene: "riderSettings")
        revealDeleteRow(in: app).tap()

        XCTAssertTrue(app.staticTexts["Delete your account?"].waitForExistence(timeout: 5))
        app.buttons["Delete permanently"].firstMatch.tap()

        let screen = app.descendants(matching: .any)["mrt.offboardingScreen"]
        XCTAssertTrue(screen.waitForExistence(timeout: 5))
        XCTAssertTrue(stepperRow("Ride requests cancelled", in: app).exists)
        XCTAssertFalse(
            stepperRow("Vehicle removed from MyRoboTaxi", in: app).exists,
            "the rider sequence must not claim a vehicle"
        )

        let ending = app.staticTexts["Your account is deleted."]
        XCTAssertTrue(ending.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Nothing remains."].exists)
        XCTAssertFalse(
            app.staticTexts["Two steps only you can do"].exists,
            "a rider has no manual Tesla steps to be shown"
        )
        attach(app, named: "rider-ending-by-tap")
    }

    /// THE HONESTY GATE, on the running app. `ownerOffboarding` injects a `DELETE`
    /// that never answers, so the narration finishes and the flow must sit there:
    /// no ending, and the last step never checked.
    func testWithNoServerAnswerTheFlowNeverReachesAnEnding() {
        let app = launch(scene: "ownerOffboarding")
        let screen = app.descendants(matching: .any)["mrt.offboardingScreen"]
        XCTAssertTrue(screen.waitForExistence(timeout: 20))

        // Well past the narration's own ~3.2s.
        XCTAssertFalse(
            app.staticTexts["Two steps only you can do"].waitForExistence(timeout: 8),
            "an ending rendered without a 204 is the failure this whole design exists to prevent"
        )
        XCTAssertFalse(
            stepperRow("Account deleted. Done.", in: app).exists,
            "the last step is the 204's to check, and no 204 has arrived"
        )
        XCTAssertTrue(app.staticTexts["Deleting your account"].exists, "it is still deleting, and still says so")
        attach(app, named: "owner-stepper-held-at-gate")
    }

    /// The FAILURE treatment, on the running app: the notice, a retry, and a way
    /// back to a Settings screen the user is STILL SIGNED IN to.
    func testAFailedDeleteOffersARetryAndLeavesTheUserSignedIn() {
        let app = launch(scene: "offboardingFailed")
        XCTAssertTrue(app.descendants(matching: .any)["mrt.offboardingScreen"].waitForExistence(timeout: 20))

        let notice = app.staticTexts["Couldn’t delete your account."]
        XCTAssertTrue(notice.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Nothing was lost — try again."].exists)
        XCTAssertTrue(app.buttons["Try again"].exists)
        XCTAssertFalse(
            app.staticTexts["Two steps only you can do"].exists,
            "a failed delete must never show an ending"
        )
        XCTAssertFalse(
            stepperRow("Account deleted. Done.", in: app).exists,
            "and the server-gated last step must not be checked"
        )
        attach(app, named: "owner-stepper-failed")

        app.buttons["Not now"].firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts["Delete account"].waitForExistence(timeout: 5),
            "\"Not now\" returns to Settings, still signed in, with the row still there"
        )
    }
}
