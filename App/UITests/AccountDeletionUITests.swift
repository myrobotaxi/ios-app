import XCTest

// MARK: - MYR-355 — the Account section, on the running app
//
// App Store Guideline 5.1.1(v) is a requirement about what a REVIEWER can find
// and tap, so the assertions that matter are about the running screen: the
// section exists on both shells, its two rows say what they should, and the
// destructive row is a real 44pt target.
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

    /// The DIALOG's button with this label, never the settings row behind it —
    /// "Delete account" is deliberately the same words in both places (the tap that
    /// opens the dialog and the tap that advances it are one action), so a
    /// `firstMatch` here would be a coin toss decided by traversal order.
    private func dialogButton(_ label: String, in app: XCUIApplication) -> XCUIElement {
        let matches = app.buttons.matching(NSPredicate(format: "label == %@", label))
        for index in 0..<matches.count {
            let candidate = matches.element(boundBy: index)
            if candidate.identifier != "mrt.deleteAccountRow" && candidate.isHittable { return candidate }
        }
        XCTFail("no hittable dialog button labelled \"\(label)\"")
        return matches.firstMatch
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

    /// The section's three parts, on the shell whose list is longest.
    func testTheOwnerSettingsScreenCarriesAnAccountSectionWithTheNameAndTheDelete() {
        assertAccountSection(in: launch(scene: "ownerSettings"), named: "owner-account-section")
    }

    /// And on the rider shell — the guideline is about the ACCOUNT, and both
    /// shells are the same account.
    func testTheRiderSettingsScreenCarriesTheSameAccountSection() {
        assertAccountSection(in: launch(scene: "riderSettings"), named: "rider-account-section")
    }

    private func assertAccountSection(in app: XCUIApplication, named: String) {
        revealDeleteRow(in: app)
        XCTAssertTrue(app.staticTexts["Account"].exists, "no Account header — 5.1.1(v) needs it discoverable")
        XCTAssertTrue(app.staticTexts["Delete account"].exists)

        // The DISPLAY-ONLY name row. It is ONE combined accessibility element (a
        // name and its provenance are one fact, not two stops for a screen
        // reader), so both halves are asserted on that element's label — which is
        // also what proves the caption is attached to THIS name rather than
        // floating somewhere else on the screen.
        let nameRow = app.descendants(matching: .any)["mrt.accountNameRow"]
        XCTAssertTrue(nameRow.waitForExistence(timeout: 10))
        XCTAssertTrue(nameRow.label.contains("Thomas Nandola"), "label was \"\(nameRow.label)\"")
        XCTAssertTrue(nameRow.label.contains("Set by Apple when you signed in"), "label was \"\(nameRow.label)\"")
        attach(app, named: named)
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

    // MARK: The real two-step path, driven by real taps

    /// The whole interaction as a thumb performs it: the row opens the first
    /// dialog, its confirm opens the SECOND, and "Keep my account" backs out
    /// leaving the user exactly where they were. Nothing here is seeded — the
    /// DEBUG scenes stand in for these taps only for the headless captures.
    func testTappingDeleteAccountOpensBothDialogsInOrderAndKeepMyAccountBacksOut() {
        let app = launch(scene: "ownerSettings")
        let row = revealDeleteRow(in: app)

        row.tap()
        XCTAssertTrue(app.staticTexts["Delete your account?"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["This can’t be undone"].exists, "the second dialog must not arrive first")
        attach(app, named: "owner-first-dialog-by-tap")

        dialogButton("Delete account", in: app).tap()
        XCTAssertTrue(app.staticTexts["This can’t be undone"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Delete permanently"].exists)
        attach(app, named: "owner-second-dialog-by-tap")

        app.buttons["Keep my account"].firstMatch.tap()
        XCTAssertFalse(app.staticTexts["This can’t be undone"].waitForExistence(timeout: 2))
        // Still signed in, still on Settings, and the row is still there.
        XCTAssertTrue(app.staticTexts["Delete account"].exists)
    }
}
