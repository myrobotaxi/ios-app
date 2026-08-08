import XCTest

// MARK: - MYR-465 — the screen has to SAY the code was refused
//
// External beta, build `202608030843`, James Guan (rider): *"When code expired,
// there is no response or notification on UI side telling me the info"*.
//
// `InviteCodeRefusalTests` pins the RULE — every §7.5.5 refusal resolves to a
// headline and an action line. **A pure test cannot show the SCREEN consults it**,
// which is how MYR-387's defect 2 and MYR-369's `VehicleRideShare.display` both
// survived green suites, and it is the exact shape of this defect: the rule's
// input existed (`ShareRedemptionFailure.riderMessage` has been there since
// MYR-184) and the view threw it away with `refusal = nil` on the one branch the
// 404 takes.
//
// So this drives a real launch. Scene `riderInviteExpired` injects the §7.5.5
// **404** into `DebugShareEndpoint` and auto-submits the sample code, so the
// sentence on screen came through the production `LiveSharedVehicleCatalog.redeem`
// → `RestError.shareRedemptionFailure` → `InviteCodeRefusal` path, not from a
// hand-set message.
//
// **Failing-first, measured.** With the one MYR-184 line restored (`refusal` set
// only when the failure does NOT clear the entry) and nothing else changed, the
// two positive tests below fail on this scene: the app reaches `.entry` with the
// cells emptied and no refusal element in the tree at all. The third — the
// resting screen — passes either way, which is the point of having it.
final class InviteCodeRefusalUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ scene: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MRT_SCENE"] = scene
        app.launch()
        return app
    }

    private func attach(_ app: XCUIApplication, named: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = named
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The element the fix adds. Combined into ONE accessibility element, so its
    /// label carries both lines — which is also what VoiceOver reads.
    ///
    /// Queried across every element type rather than as `otherElements`: a
    /// `.combine` over two `Text`s is surfaced by SwiftUI as a static text, not a
    /// container, and pinning the wrong type here would make the test assert
    /// "SwiftUI still classifies this the way it did in this SDK" instead of "the
    /// screen says something".
    private func refusal(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["mrt.invite.refusal"]
    }

    /// THE CAPTURE THE PR CARRIES, and the regression guard: an expired code
    /// leaves words on screen, under the boxes, where the rider is looking.
    ///
    /// The wait is generous on purpose — the screen runs a deliberate ~1.3s
    /// "Verifying code…" beat before any verdict (jsx:420-423).
    func testAnExpiredCodeLeavesAnInlineRefusalOnScreen() {
        let app = launch("riderInviteExpired")
        XCTAssertTrue(
            app.staticTexts["Enter invite code"].waitForExistence(timeout: 20),
            "the invite-code entry screen"
        )

        let notice = refusal(in: app)
        XCTAssertTrue(
            notice.waitForExistence(timeout: 20),
            "a refused code must leave an inline notice under the cells"
        )
        attach(app, named: "MYR-465-riderInviteExpired-refused")

        let text = notice.label
        XCTAssertTrue(text.contains("That code"), "it says what happened: \(text)")
        XCTAssertTrue(text.lowercased().contains("owner"), "and what to do about it: \(text)")
    }

    /// **IT PERSISTS.** The whole complaint was that whatever happened was over
    /// before it could be read: the shake is 0.4s and is absent entirely under
    /// Reduce Motion. An inline state is not a toast, so it is still there seconds
    /// later, and it is still there after the screen has settled.
    func testTheRefusalIsNotTransient() {
        let app = launch("riderInviteExpired")
        let notice = refusal(in: app)
        XCTAssertTrue(notice.waitForExistence(timeout: 20))

        Thread.sleep(forTimeInterval: 4)
        XCTAssertTrue(notice.exists, "an inline error state does not time out the way a toast does")
        attach(app, named: "MYR-465-riderInviteExpired-persists")
    }

    /// **AND IT IS NOT ON THE RESTING SCREEN.** The pair's other half: with nothing
    /// submitted there is no notice, so the element's presence genuinely means "a
    /// code was refused" rather than "this screen always says something".
    func testTheRestingEntryScreenCarriesNoRefusal() {
        let app = launch("riderInviteEntry")
        XCTAssertTrue(
            app.staticTexts["Enter invite code"].waitForExistence(timeout: 20),
            "the invite-code entry screen"
        )
        // A negative needs a real wait, or it only proves the screen is slow.
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(refusal(in: app).exists, "nothing was submitted, so nothing was refused")
        attach(app, named: "MYR-465-riderInviteEntry-resting")
    }
}
