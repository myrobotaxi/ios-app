import XCTest

// MARK: - MYR-344 defect 1 — the composer opens over a settled layout
//
// THE CLIENT'S ASK (TestFlight, Jul 29, AKR8XUmU2L6Z0t65YdyxLDw): *"After I
// select send keyboard is still open and bottom sheet is cut off with the share
// details."* His screenshot is the whole bug: the composer up, the QuickType bar
// and the full keyboard on top of it, and the sheet ending mid-summary-card with
// its "Send invite" CTA nowhere on screen.
//
// This has to be a UI test. The defect is not in any value the app computes — it
// is that a REAL first responder was still up while a REAL presentation measured
// its container, so nothing short of driving the actual keyboard can see it. The
// two assertions are the two halves of the client's sentence: the keyboard is
// gone, and the sheet's own CTA is on screen and hittable.
//
// Failing-first, verified against the pre-fix `InvitesScreen` (origin/main
// 4b98d6a) with everything else on this branch in place — BOTH fail:
//   • testTheComposerOpensWithNoKeyboardAndItsCTAOnScreen fails on the keyboard
//     assertion; its attached screenshot is the client's photograph, down to the
//     summary card ending mid-list and the composer's title scrolled off the top.
//   • testTheSystemShareSheetPresentsWithNoKeyboard fails one step LATER, on the
//     share sheet never arriving — because "Send invite" is off the bottom of the
//     screen, so the tap that should send lands on the keyboard instead. That is
//     the client's bug stated as a consequence: the send cannot be completed.
final class ShareComposerKeyboardUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchShareTab() -> XCUIApplication {
        let app = XCUIApplication()
        // The LIVE share tab: the only path that mints a code and therefore the
        // only one that reaches the system share sheet at the end of a send.
        app.launchEnvironment["MRT_SCENE"] = "ownerShareLive"
        app.launch()
        return app
    }

    private func attach(_ app: XCUIApplication, named: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = named
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Poll for the keyboard to be GONE. A one-shot read races the dismissal
    /// animation; a `waitForExistence` cannot express absence.
    private func waitForKeyboardToGo(_ app: XCUIApplication, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.keyboards.count == 0 { return true }
            usleep(100_000)
        }
        return app.keyboards.count == 0
    }

    /// Type a recipient into the share tab's field, leaving the keyboard UP —
    /// which is the state the client was in when he tapped Send.
    private func typeRecipientLeavingTheKeyboardUp(_ app: XCUIApplication) {
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the share tab's recipient field")
        field.tap()
        field.typeText("Mira")
        XCTAssertTrue(
            app.keyboards.element.waitForExistence(timeout: 5),
            "precondition: the keyboard is up when Send is tapped — that IS the client's state"
        )
    }

    /// The client's exact sequence, and both halves of his sentence.
    func testTheComposerOpensWithNoKeyboardAndItsCTAOnScreen() {
        let app = launchShareTab()
        typeRecipientLeavingTheKeyboardUp(app)

        app.buttons["Send"].tap()

        XCTAssertTrue(
            app.staticTexts["Invite to your Tesla"].waitForExistence(timeout: 10),
            "the composer should open"
        )
        attach(app, named: "MYR-344 composer after Send")

        // Half one: "keyboard is still open".
        XCTAssertTrue(
            waitForKeyboardToGo(app),
            "the keyboard must be dismissed before the composer presents"
        )

        // Half two: "bottom sheet is cut off with the share details". The CTA is
        // the LAST thing in the sheet, so it is the thing a keyboard-shrunk layout
        // pushes off the bottom — and the sheet does not scroll.
        let cta = app.buttons["Send invite"]
        XCTAssertTrue(cta.waitForExistence(timeout: 5), "the composer's CTA should exist")
        XCTAssertTrue(cta.isHittable, "the composer's CTA must not be behind the keyboard")
        let screen = app.windows.firstMatch.frame
        XCTAssertLessThanOrEqual(
            cta.frame.maxY, screen.maxY,
            "the whole sheet must fit on screen — CTA \(cta.frame) vs screen \(screen)"
        )
    }

    /// The end of the same flow: the send completes and the SYSTEM share sheet —
    /// the thing that actually carries the code out of the app — comes up over a
    /// settled layout too, with no keyboard anywhere near it.
    func testTheSystemShareSheetPresentsWithNoKeyboard() {
        let app = launchShareTab()
        typeRecipientLeavingTheKeyboardUp(app)
        app.buttons["Send"].tap()

        let cta = app.buttons["Send invite"]
        XCTAssertTrue(cta.waitForExistence(timeout: 10))
        cta.tap()

        // The share sheet's Copy action, located across element types for the same
        // reason `ShareInviteMessageUITests` does: it is a cell on iOS 26 and a
        // button on older runtimes.
        let copy = app.cells["Copy"]
        XCTAssertTrue(
            copy.waitForExistence(timeout: 30) || app.buttons["Copy"].exists,
            "the minted code should reach the system share sheet"
        )
        attach(app, named: "MYR-344 system share sheet after Send invite")
        XCTAssertEqual(app.keyboards.count, 0, "no keyboard under the share sheet")
    }
}
