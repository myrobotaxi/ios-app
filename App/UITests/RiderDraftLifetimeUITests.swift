import XCTest

// MARK: - MYR-389 — "Where to?" must open a CLEAN search, not the last trip
//
// r15 screen recording (build 202607311129, 2026-07-31 12:47 CT), client's own
// words: *"when I tried to search it pulled up a prev route, the state wasn't
// reset to a clean search."* What he tapped was the idle map's "Where to?"; what
// opened was his 12:46 booking attempt — destination already filled, "Pickup
// Tomorrow · 12:00 PM" still latched, the old route drawing itself in behind the
// sheet.
//
// THIS IS A UI TEST BECAUSE THE DEFECT IS A SEQUENCE, and every step of it is a
// tap. The draft that leaks is created by one screen, abandoned by a second, and
// resurrected by a third; no single mounted view holds enough of that to prove
// it, and a cold scene cannot reach the state at all — cold-launching `search`
// starts from an in-memory blank, which is exactly why the client's own workaround
// (force-quit) worked and why this class of bug survives a screenshot suite.
//
// FAILING-FIRST, and genuinely so: this file and its `riderScheduledReview` scene
// were written and RUN before a line of the fix existed. The run failed on the
// first assertion after the tap —
//
//     XCTAssertFalse failed - the previous trip's destination must not be in the
//     field — it read SFO · Terminal 2
//
// — with the "Pickup Tomorrow · 6:30 AM" row still on screen beneath it. That is
// the client's frame, reproduced from taps rather than described.
//
// `testTheReservationItselfSurvivesTheDraftReset` PASSED before the fix and passes
// after it, which is the point of it: it is the scope guard, and a guard that only
// starts passing once you fix something is not guarding the thing you broke.
final class RiderDraftLifetimeUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private enum Labels {
        /// The idle greeting card's search affordance (`SharedViewerScreen.searchBar`).
        static let whereTo = "Where to?"
        /// Review's scheduled CTA — the fixture owner is `RideRequestFixtures.fleet[0]`.
        static let scheduleCTA = "Schedule with Alex"
        /// The seeded draft's destination (`DebugScene.sampleDestination`).
        static let seededDestination = "SFO"
        /// The pre-typing list's first section header.
        static let savedSection = "SAVED"
    }

    private func attach(_ app: XCUIApplication, named: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = named
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func launch(_ scene: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MRT_SCENE"] = scene
        app.launch()
        return app
    }

    /// The destination field — the one element that says out loud what the sheet
    /// thinks the rider is going to.
    private func destinationField(_ app: XCUIApplication) -> XCUIElement {
        app.textFields.firstMatch
    }

    /// The "Pickup {day} · {time}" summary row: the schedule LATCH, made visible.
    private func pickupSummaryRow(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Pickup ")).firstMatch
    }

    // MARK: The client's sequence, end to end

    /// Review (schedule committed) → "Schedule with Alex" → back on the idle map →
    /// the reservation is accepted, so the pending pill gives the greeting card
    /// back → "Where to?" → **a clean search**.
    ///
    /// The wait for the greeting is the honest part of this test rather than a
    /// convenience: while the request is still `pending` the idle sheet renders the
    /// status pill and there is no "Where to?" to tap. The simulated service
    /// auto-accepts on its own timers (~13.6s), the reservation is dormant, and the
    /// greeting comes back — which is precisely the window the client tapped in.
    func testTappingWhereToAfterAScheduledRideOpensACleanSearch() {
        let app = launch("riderScheduledReview")

        let cta = app.buttons[Labels.scheduleCTA]
        XCTAssertTrue(cta.waitForExistence(timeout: 20), "the Review sheet's scheduled CTA")
        attach(app, named: "MYR-389 1 review with a committed schedule")
        cta.tap()

        let whereTo = app.buttons[Labels.whereTo]
        XCTAssertTrue(
            whereTo.waitForExistence(timeout: 40),
            "the greeting card's search affordance must come back once the reservation is accepted"
        )
        attach(app, named: "MYR-389 2 back on the idle map")
        whereTo.tap()

        let field = destinationField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the search sheet's destination field")
        attach(app, named: "MYR-389 3 the search that opened")

        // The client's three symptoms, asserted one at a time so a failure names
        // which half of the draft survived.
        let text = (field.value as? String) ?? ""
        XCTAssertFalse(
            text.contains(Labels.seededDestination),
            "the previous trip's destination must not be in the field — it read \(text)"
        )
        XCTAssertFalse(
            pickupSummaryRow(app).exists,
            "the schedule latch must not survive: the sheet still shows a committed pickup time"
        )
        // Stated in the POSITIVE — "the pre-typing list is showing" — rather than
        // as the absence of the "Continue" CTA, because iOS's own QuickPath
        // keyboard tutorial puts a button with that exact label on screen and
        // `app.buttons["Continue"]` finds it first. The two are mutually exclusive
        // in the app (`belowHeaderRegion`: a chosen destination REPLACES the list
        // with the CTA), so the list being up is the same fact, asserted on an
        // element the system cannot impersonate.
        XCTAssertTrue(
            app.staticTexts[Labels.savedSection].waitForExistence(timeout: 5),
            "a clean search shows its pre-typing list; a resurrected draft replaces it with Continue"
        )
    }

    /// The scope guard, on the same scene: submitting the scheduled ride must still
    /// LEAVE A RESERVATION. A reset that also cleared the rider's active slot would
    /// pass the test above and lose the ride — the failure mode this issue is one
    /// wrong line away from.
    func testTheReservationItselfSurvivesTheDraftReset() {
        let app = launch("riderScheduledReview")

        let cta = app.buttons[Labels.scheduleCTA]
        XCTAssertTrue(cta.waitForExistence(timeout: 20))
        cta.tap()

        // The pending pill IS the active slot, rendered.
        let pill = app.staticTexts["Request sent"]
        XCTAssertTrue(pill.waitForExistence(timeout: 10), "the submitted reservation must hold the rider's slot")
        attach(app, named: "MYR-389 4 the reservation still exists")
    }
}
