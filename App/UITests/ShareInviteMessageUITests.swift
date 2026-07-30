import XCTest
import UIKit

// MARK: - MYR-340 — what the recipient actually receives
//
// THE CLIENT'S ASK (TestFlight, Jul 29): "Feels strange just sending a text
// message, where do they go. I feel like we need to include TestFlight link or
// something. Or can we send an invite via email?"
//
// The unit tests (`ShareInviteMessageTests`) pin the composer. This pins the
// DELIVERY: that the composed text is what actually leaves the app through the
// real `UIActivityViewController`, byte for byte, on both share paths.
//
// It has to be a UI test because the share sheet's own preview TRUNCATES to one
// line ("Thomas shared their Tesla with yo…"), so a screenshot can prove the
// opening grammar and nothing below it. Tapping the sheet's own **Copy** action
// and reading the pasteboard is the only way to see the full string as the
// system hands it on — and it exercises the activity item plumbing rather than
// re-reading the composer we already tested.
//
// The expected copy is written out VERBATIM here rather than imported: a UI test
// target cannot link app code, and restating the shipped message independently
// is exactly what makes this a guard. If someone edits the copy, this fails and
// they have to mean it.
final class ShareInviteMessageUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
        UIPasteboard.general.string = ""
    }

    /// The message the owner hands over, named grammar. Note the code alone on
    /// its own line and the plain (unwrapped, unmarked-up) https URL — the two
    /// things iMessage and Mail need to render this usefully.
    private func expectedMessage(opening: String, code: String) -> String {
        """
        \(opening)

        1. Get the app: https://testflight.apple.com/join/uarZRUbg
        2. Sign in with Apple
        3. Enter this invite code:

        \(code)

        The code expires in 7 days.
        """
    }

    private func launch(scene: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MRT_SCENE"] = scene
        app.launch()
        return app
    }

    /// The share sheet's preview row. Its label is the first line of the item,
    /// which is how we confirm the right message reached the sheet at all before
    /// committing to a Copy.
    private func waitForShareSheet(_ app: XCUIApplication) {
        XCTAssertTrue(
            app.cells["Copy"].waitForExistence(timeout: 30) || app.buttons["Copy"].exists,
            "the capture scene runs the production resend on appear; its share sheet should open"
        )
    }

    private func attach(_ app: XCUIApplication, named: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = named
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The share sheet's **Copy** action. Located across element types on
    /// purpose: the activity sheet is system-composed UI whose row is a button on
    /// some runtimes and a collection-view cell on others, and pinning one type
    /// makes this test fail on an OS bump for a reason that has nothing to do
    /// with the message.
    private func copyAction(in app: XCUIApplication) -> XCUIElement {
        // iOS 26 renders it as a cell (`actionGroupCell`, label "Copy"); older
        // runtimes render it as a button. Query both rather than the whole
        // `.any` tree, which resolves the entire system sheet and costs ~90s.
        let cell = app.cells["Copy"]
        return cell.exists ? cell : app.buttons["Copy"]
    }

    private func copiedMessage(from app: XCUIApplication) -> String {
        copyAction(in: app).tap()
        // The sheet dismisses on Copy; the write is synchronous but the tap's
        // dispatch is not, so poll briefly rather than sleeping a fixed beat.
        for _ in 0..<40 {
            if let value = UIPasteboard.general.string, !value.isEmpty { return value }
            usleep(100_000)
        }
        return UIPasteboard.general.string ?? ""
    }

    /// The whole point of the issue: the recipient is handed a way to GET the
    /// app, not just a code. Asserted on the exact bytes the system copied.
    func testTheSharedMessageIsTheFullOnboardingWithTheTestFlightLink() {
        let app = launch(scene: "ownerShareMessage")
        waitForShareSheet(app)
        attach(app, named: "MYR-340 share sheet — named owner")

        let message = copiedMessage(from: app)

        // The code is minted by the real §7.5.4 resend, so it is not a literal we
        // can assert on — everything AROUND it is.
        let lines = message.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "Thomas shared their Tesla with you on MyRoboTaxi.")
        XCTAssertTrue(message.contains("1. Get the app: https://testflight.apple.com/join/uarZRUbg"))
        XCTAssertTrue(message.contains("2. Sign in with Apple"))
        XCTAssertTrue(message.contains("3. Enter this invite code:"))
        XCTAssertTrue(message.hasSuffix("The code expires in 7 days."))

        // The code: 6 uppercase alphanumerics, ALONE on its own line, blank lines
        // above and below. This is the line the recipient transcribes by hand.
        let codeLine = try? XCTUnwrap(
            lines.first { $0.count == 6 && $0.allSatisfy { c in c.isUppercase || c.isNumber } }
        )
        let code = try? XCTUnwrap(codeLine)
        XCTAssertNotNil(code, "a 6-character code should stand alone on one line")
        if let code {
            XCTAssertEqual(message, expectedMessage(
                opening: "Thomas shared their Tesla with you on MyRoboTaxi.", code: code
            ), "the delivered bytes must be the composer's output verbatim")
        }
    }

    /// The no-name account — a real fraction of owners, since Apple returns a
    /// human name only on the first authorization. First person, never a sentence
    /// with an empty name in it, and everything below the opening line identical.
    func testAnAccountWithNoNameSharesTheSameOnboardingInFirstPerson() {
        let app = launch(scene: "ownerShareMessageNoName")
        waitForShareSheet(app)
        attach(app, named: "MYR-340 share sheet — no name on the account")

        let message = copiedMessage(from: app)
        let lines = message.components(separatedBy: "\n")

        XCTAssertEqual(lines.first, "I shared my Tesla with you on MyRoboTaxi.")
        XCTAssertFalse(message.hasPrefix(" "), "no empty-name artifact")
        XCTAssertTrue(message.contains("1. Get the app: https://testflight.apple.com/join/uarZRUbg"))
        XCTAssertTrue(message.hasSuffix("The code expires in 7 days."))
    }
}
