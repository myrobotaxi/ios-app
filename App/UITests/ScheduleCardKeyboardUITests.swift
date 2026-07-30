import XCTest

// MARK: - MYR-353 — the schedule card opens over a settled layout
//
// THE CLIENT'S ASK (TestFlight, Jul 30, AA_L1-KR… in feedback_shots9): *"When I
// tap on schedule it pops up behind the keyboard. Needs to be fixed."*
//
// This is the MYR-239/344 class exactly. The rider arrives on the Search sheet
// and `scheduleSearchFocus()` deliberately raises the destination keyboard 450ms
// after the settle — so keyboard-up is the DEFAULT state in which the Schedule
// chip is tapped, not an edge case. The card itself is bottom-flush and
// `ignoresSafeArea(edges: .bottom)`, so it lays out UNDER the keyboard window:
// its day/time chip rows and its "Set pickup" CTA are covered by the keyboard,
// which is the client's screenshot.
//
// It has to be a UI test. Nothing the app COMPUTES is wrong — the card's frame is
// the frame it always had. What is wrong is that a real first responder was still
// up over it, and only a real keyboard can see that.
//
// Failing-first, verified against the pre-fix `RideRequestSearchContent`
// (origin/main faebe12): both tests fail on `isHittable` for the card's CTA with
// the keyboard occupying the bottom 336pt of the screen — the attached
// screenshots are the client's photograph.
final class ScheduleCardKeyboardUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private enum Labels {
        static let scheduleChip = "Schedule"
        static let cardTitle = "Schedule pickup"
    }

    /// The rider Search sheet. `MRT_SCENE=search` boots straight into it, and the
    /// shipping `scheduleSearchFocus()` then raises the keyboard on its own — the
    /// same 450ms auto-focus a tap-open from idle gets.
    private func launchSearch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MRT_SCENE"] = "search"
        app.launch()
        return app
    }

    private func attach(_ app: XCUIApplication, named: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = named
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Poll for the keyboard to be GONE — a one-shot read races the dismissal
    /// animation and `waitForExistence` cannot express absence (the
    /// `ShareComposerKeyboardUITests` helper, verbatim).
    private func waitForKeyboardToGo(_ app: XCUIApplication, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.keyboards.count == 0 { return true }
            usleep(100_000)
        }
        return app.keyboards.count == 0
    }

    /// The precondition that IS the client's state: the destination keyboard up.
    private func waitForTheKeyboardTheClientHadUp(_ app: XCUIApplication) {
        XCTAssertTrue(
            app.keyboards.element.waitForExistence(timeout: 20),
            "precondition: the search sheet auto-focuses the destination field, so the keyboard is up when Schedule is tapped — that IS the client's state"
        )
    }

    /// The card's own CTA — the LAST element in it, and therefore the one a
    /// keyboard sitting over a bottom-flush card covers first.
    private func setPickupCTA(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Set pickup")).firstMatch
    }

    // MARK: The client's literal sequence

    func testTappingScheduleWithTheKeyboardUpOpensTheCardOverASettledLayout() {
        let app = launchSearch()
        waitForTheKeyboardTheClientHadUp(app)

        app.buttons[Labels.scheduleChip].tap()

        XCTAssertTrue(
            app.staticTexts[Labels.cardTitle].waitForExistence(timeout: 10),
            "the schedule card should open"
        )
        attach(app, named: "MYR-353 schedule card after tapping Schedule")

        // Half one: the keyboard is gone.
        XCTAssertTrue(
            waitForKeyboardToGo(app),
            "the keyboard must be dismissed before the schedule card presents"
        )

        // Half two: the card's CTA is reachable — the direct contradiction of
        // "it pops up behind the keyboard".
        let cta = setPickupCTA(app)
        XCTAssertTrue(cta.waitForExistence(timeout: 5), "the card's Set pickup CTA should exist")
        XCTAssertTrue(cta.isHittable, "the card's CTA must not be behind the keyboard")

        // Half three: the card lays out at its INTENDED height — bottom-flush to
        // the physical edge, so the CTA rests inside `RideSlideUpCard`'s own 26pt
        // bottom padding and nothing else. A card that had measured a
        // keyboard-shrunk container (or that had been lifted by the keyboard's
        // safe-area inset) lands nowhere near this band.
        let screen = app.windows.firstMatch.frame
        let gap = screen.maxY - cta.frame.maxY
        XCTAssertTrue(
            (18...42).contains(gap),
            "the card must sit bottom-flush at its intended height — CTA bottom is \(gap)pt from the screen edge (expected RideSlideUpCard's 26pt padding), CTA \(cta.frame) vs screen \(screen)"
        )
    }

    /// The SECOND entry point on the same sheet, and the one a rider reaches
    /// after they have already picked a time: the "Pickup {day} · {time}" summary
    /// row's Edit. Same sheet, same keyboard, same hazard — it had the same
    /// bare `scheduleSheetOpen = true`.
    func testEditingAnExistingScheduleWithTheKeyboardUpOpensTheCardOverASettledLayout() {
        let app = launchSearch()
        waitForTheKeyboardTheClientHadUp(app)

        // Commit a schedule through the real card so the summary row exists.
        app.buttons[Labels.scheduleChip].tap()
        let cta = setPickupCTA(app)
        XCTAssertTrue(cta.waitForExistence(timeout: 10))
        XCTAssertTrue(cta.isHittable, "precondition: the first open must already be usable")
        cta.tap()
        XCTAssertFalse(
            app.staticTexts[Labels.cardTitle].waitForExistence(timeout: 2),
            "committing a pickup closes the card"
        )

        // Put the keyboard back up, exactly as a rider returning to the field does.
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the destination field")
        field.tap()
        waitForTheKeyboardTheClientHadUp(app)

        // The summary row is one composite button ("Pickup {day} · {time}" + Edit),
        // so it is addressed by its leading copy rather than by "Edit" alone.
        let editRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Pickup ")).firstMatch
        XCTAssertTrue(editRow.waitForExistence(timeout: 5), "the schedule summary row")
        editRow.tap()

        XCTAssertTrue(
            app.staticTexts[Labels.cardTitle].waitForExistence(timeout: 10),
            "the schedule card should reopen from the summary row"
        )
        attach(app, named: "MYR-353 schedule card reopened from the Edit row")

        XCTAssertTrue(
            waitForKeyboardToGo(app),
            "the keyboard must be dismissed before the schedule card re-presents"
        )
        let reopened = setPickupCTA(app)
        XCTAssertTrue(reopened.waitForExistence(timeout: 5))
        XCTAssertTrue(reopened.isHittable, "the reopened card's CTA must not be behind the keyboard")
    }

    /// The THIRD entry point — `opensScheduleOnSearch`, the one-shot Review
    /// hands over when the vehicle is unavailable ("Schedule with … instead").
    /// It has its own hazard, and it points the OTHER way: no keyboard is up when
    /// the card opens, but `scheduleSearchFocus()` runs in the very same
    /// `onChange` and would raise one 450ms LATER, UNDER the open card. The
    /// `riderScheduleFloored` scene arms exactly this path.
    func testTheReviewRoutedCardIsNotUnderminedByTheDelayedAutoFocus() {
        let app = XCUIApplication()
        app.launchEnvironment["MRT_SCENE"] = "riderScheduleFloored"
        app.launch()

        XCTAssertTrue(
            app.staticTexts[Labels.cardTitle].waitForExistence(timeout: 20),
            "the routed schedule card should open on arrival at Search"
        )
        // Past the 450ms auto-focus window with room to spare.
        Thread.sleep(forTimeInterval: 2.0)
        attach(app, named: "MYR-353 routed schedule card, past the auto-focus window")

        XCTAssertEqual(
            app.keyboards.count, 0,
            "the deferred auto-focus must not raise a keyboard underneath an open schedule card"
        )
        let cta = setPickupCTA(app)
        XCTAssertTrue(cta.waitForExistence(timeout: 5))
        XCTAssertTrue(cta.isHittable, "the routed card's CTA must stay reachable")
    }
}
