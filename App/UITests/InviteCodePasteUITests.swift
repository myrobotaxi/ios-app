import XCTest
import UIKit

// MARK: - MYR-344 defect 2 — pasting the invite code
//
// THE CLIENT'S ASK (TestFlight, Jul 29, AOM__3UE6am8U1rF5iWTcdI): *"No option
// for me to paste the code here."* The six cells are backed by a 1×1 invisible
// text field, so iOS's own edit menu could never be summoned on them: there was
// no paste route on the screen at all.
//
// `InviteCodePasteTests` pins the sanitizing rule. This pins the two things only
// a running app can show: that the affordance is ON SCREEN when the pasteboard
// holds text (and absent when it does not), and that a pasted COMPLETE code
// submits itself exactly as the sixth keystroke does — no extra button, no
// waiting.
//
// Failing-first, verified on the pre-fix build (commit 4b98d6a): the scene does
// not exist and no paste element is found on the invite screen.
final class InviteCodePasteUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchInviteEntry(pasteboard: String) -> XCUIApplication {
        // The simulator's pasteboard is system-wide, so what this process copies
        // is what the app under test is offered — the same mechanism
        // `ShareInviteMessageUITests` reads back through.
        UIPasteboard.general.string = pasteboard
        let app = XCUIApplication()
        app.launchEnvironment["MRT_SCENE"] = "riderInviteEntry"
        app.launch()
        XCTAssertTrue(
            app.staticTexts["Enter invite code"].waitForExistence(timeout: 20),
            "the invite-code entry screen"
        )
        return app
    }

    private func attach(_ app: XCUIApplication, named: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = named
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The affordance is a system `UIPasteControl`, which XCUITest sees as a
    /// button labelled "Paste".
    private func pasteControl(in app: XCUIApplication) -> XCUIElement {
        app.buttons["Paste"]
    }

    /// The capture the PR carries: the screen the client photographed, with a way
    /// to paste on it.
    func testThePasteAffordanceIsOnScreenInEntry() {
        let app = launchInviteEntry(pasteboard: "code: rbo246!")
        XCTAssertTrue(
            pasteControl(in: app).waitForExistence(timeout: 10),
            "a paste affordance should be offered next to the cells"
        )
        attach(app, named: "MYR-344 invite entry — paste affordance")
    }

    /// Tap the paste control until the payload actually lands.
    ///
    /// `UIPasteControl` is a system PRIVACY control: it decides for itself whether
    /// a touch is trustworthy enough to hand the pasteboard over without a prompt,
    /// and a SYNTHESIZED tap does not reliably clear that bar — identical taps
    /// delivered on one run and were ignored on the next, with the control drawn,
    /// hittable, and the cells left empty. A real finger has no such problem
    /// (that is the control's entire purpose), so this retries instead of
    /// asserting on the first tap: what is under test is what the app does WITH
    /// the payload, not Apple's decision to release it.
    @discardableResult
    private func pasteUntilItLands(_ app: XCUIApplication, attempts: Int = 4) -> Bool {
        let paste = pasteControl(in: app)
        XCTAssertTrue(paste.waitForExistence(timeout: 10), "the paste affordance")
        for _ in 0..<attempts {
            if paste.exists, paste.isHittable { paste.tap() }
            if app.staticTexts["You're in"].waitForExistence(timeout: 8) { return true }
        }
        return false
    }

    /// The affordance belongs to ENTRY and nothing else: once a code is in flight
    /// there is nothing to paste into, and a paste control left over a spinner
    /// would invite a second submission of a code already being checked.
    func testTheAffordanceGoesAwayOnceTheCodeIsSubmitted() {
        let app = launchInviteEntry(pasteboard: "code: rbo246!")
        XCTAssertTrue(pasteUntilItLands(app), "the paste should reach the app")
        XCTAssertFalse(pasteControl(in: app).exists, "no paste control outside .entry")
    }

    /// The client's own junk shape, end to end: paste "code: rbo246!", get RBO246
    /// in the cells, and have it submit itself. A plain character strip would put
    /// "CODERB" in those cells and submit THAT — six characters, so it would
    /// auto-submit too, and the rider would watch their correct code be rejected.
    ///
    /// Six characters is the submit trigger, so the flow runs straight through the
    /// ~1.3s "Verifying code…" beat into the success screen with no further
    /// interaction. Arriving there IS the proof the paste was complete and clean.
    func testPastingMixedJunkFillsTheCodeAndSubmitsItself() {
        let app = launchInviteEntry(pasteboard: "code: rbo246!")
        XCTAssertTrue(
            pasteUntilItLands(app),
            "a pasted complete code should submit exactly like the 6th keystroke"
        )
        attach(app, named: "MYR-344 paste → auto-submit → joined")
    }
}
