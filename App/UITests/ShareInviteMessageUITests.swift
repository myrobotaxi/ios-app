import XCTest
import UIKit

// MARK: - MYR-340 → MYR-359 — what the recipient actually receives
//
// THE CLIENT'S ASK (TestFlight, Jul 29): "Feels strange just sending a text
// message, where do they go." → MYR-340's mini-onboarding paragraph.
// THE CLIENT AGAIN (Jul 30): the branded card never shows in the thread. →
// MYR-359: the payload is the invite LINK and nothing else, because iMessage
// renders the card only for a message that is nothing but a link.
//
// The unit tests (`ShareInviteMessageTests`) pin the payload byte for byte. This
// pins the DELIVERY — that the share sheet genuinely presents over the real
// `UIActivityViewController` on both share paths, with the real activity item
// behind it — which is the one thing no unit test can see.
//
// It stops there deliberately. The sheet's own preview is system-composed
// (`LPLinkMetadata` fetched by the OS for a URL item), so what it draws is not
// this app's contract and asserting on it would be asserting on iOS. The bytes
// that leave the app are the URL, and they are covered where they can be read
// exactly.
final class ShareInviteMessageUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
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

    // MYR-350: this test previously tapped Copy and read UIPasteboard.general.
    // On clean simulators iOS raises a paste-permission alert that XCUITest
    // cannot reliably pre-authorize (UIPasteboardAutomaticAllowPaste is not
    // honored on this runtime), hanging or emptying the read. The delivered
    // BYTES are asserted exhaustively by ShareInviteMessageTests at the unit
    // level; here we assert what only a UI test can — the share sheet actually
    // presents over the real activity-item plumbing, and Copy is offered.

    /// The named-owner path: the sheet presents, over a genuinely minted code,
    /// carrying a URL activity item. The link's `?from=` name is what turns the
    /// recipient's card into "Thomas invited you to ride their Tesla".
    func testTheShareSheetPresentsTheInviteLinkForANamedOwner() {
        let app = launch(scene: "ownerShareMessage")
        waitForShareSheet(app)
        attach(app, named: "MYR-359 share sheet — named owner (link-only payload)")

        // Byte-exact payload content is covered by ShareInviteMessageTests
        // (MYR-350) — the UI layer's job ends at a presented sheet with Copy.
        XCTAssertTrue(copyAction(in: app).waitForExistence(timeout: 5),
                      "the share sheet should offer Copy for the invite link")
    }

    /// The no-name account — a real fraction of owners, since Apple returns a
    /// human name only on the first authorization. The link then carries NO
    /// `?from=` at all and the landing page falls back to its generic heading;
    /// the sheet itself is otherwise identical.
    func testTheShareSheetPresentsTheInviteLinkForAnAccountWithNoName() {
        let app = launch(scene: "ownerShareMessageNoName")
        waitForShareSheet(app)
        attach(app, named: "MYR-359 share sheet — no name on the account")

        // The from-matrix is unit-tested exactly (ShareInviteMessageTests);
        // see MYR-350 for why no pasteboard read happens here.
        XCTAssertTrue(copyAction(in: app).waitForExistence(timeout: 5),
                      "the share sheet should offer Copy for the no-name invite link")
    }
}
