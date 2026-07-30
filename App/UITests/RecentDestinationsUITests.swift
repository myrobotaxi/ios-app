import XCTest

// MARK: - MYR-356 / MYR-363b — the two things only a running app can show
//
// Both need a real app for the same reason: the search sheet AUTO-FOCUSES its
// destination field 450ms after it settles (MYR-250), so the keyboard is up by
// design and the pre-typing list lives below its fold. A headless
// `simctl io screenshot` cannot scroll to it, and neither the recents rows nor a
// card that opens itself in response to a TAP has any cold-scene route at all —
// the same `ExpandedRouteUITests` / `DriveSummaryCelebrationUITests` precedent.
//
// FAILING-FIRST against origin/main (7faf34b):
//
//  • every recents test fails at launch — `riderRecentDestinations` is not a scene,
//    and `mrt.search.dest.*` identifiers did not exist;
//  • `testPickingADestinationOpensTheSchedulePickerWhenTheSegmentDefaulted` fails
//    on the card's title never appearing: MYR-361 moved the SELECTION to Schedule
//    and nothing ever opened the picker, so the rider's next stop was a Review with
//    a gated CTA.

final class RecentDestinationsUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private func attach(_ app: XCUIApplication, named: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = named
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func launch(_ scene: String, reason: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MRT_SCENE"] = scene
        if let reason { app.launchEnvironment["MRT_BUSY_REASON"] = reason }
        app.launch()
        return app
    }

    private func row(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.buttons["mrt.search.dest.\(id)"]
    }

    /// The five the scene seeds six for. Most-recent-first, and `rec-pier39` — the
    /// sixth, oldest — must NOT be among them.
    private let expected = ["rec-ferry", "rec-sfo", "live-unresolved|tartine", "rec-crissy", "rec-sfmoma"]

    // MARK: MYR-356

    func testTheSearchSheetShowsTheRidersFiveMostRecentDestinations() {
        let app = launch("riderRecentDestinations")
        for id in expected {
            XCTAssertTrue(
                row(app, id).waitForExistence(timeout: 6),
                "\(id) must be listed — the store seeded it"
            )
        }
        attach(app, named: "riderRecentDestinations-list")
    }

    /// The CAP, proven on the running app rather than only in the list rule: the
    /// scene seeds SIX and the oldest is not rendered.
    func testTheSixthOldestDestinationIsNotShown() {
        let app = launch("riderRecentDestinations")
        XCTAssertTrue(row(app, expected[0]).waitForExistence(timeout: 6), "precondition: the list rendered")
        XCTAssertFalse(row(app, "rec-pier39").exists, "the list is capped at five")
    }

    /// The ORDER, read off the rendered frames rather than the array — most-recent
    /// at the top.
    func testTheRowsAreOrderedMostRecentFirst() {
        let app = launch("riderRecentDestinations")
        XCTAssertTrue(row(app, expected[0]).waitForExistence(timeout: 6))
        let tops = expected.map { row(app, $0).frame.minY }
        XCTAssertEqual(tops, tops.sorted(), "the rows must descend in recency: \(tops)")
    }

    /// THE DELIVERABLE: selecting a recent behaves exactly like choosing that
    /// destination from search — the field fills with its label and the explicit
    /// "Continue" step-CTA (MYR-215 deliverable 3) takes the results list's place.
    func testSelectingARecentBehavesLikeChoosingItFromSearch() {
        let app = launch("riderRecentDestinations")
        let ferry = row(app, "rec-ferry")
        XCTAssertTrue(ferry.waitForExistence(timeout: 6))
        XCTAssertTrue(ferry.isHittable, "a rider must be able to reach their own recents")
        ferry.tap()

        let cta = app.buttons["Continue"]
        XCTAssertTrue(cta.waitForExistence(timeout: 4), "a chosen recent must produce the Continue step")
        XCTAssertTrue(
            app.staticTexts["Ferry Building"].exists || app.textFields["Ferry Building"].exists,
            "and must fill the destination field with its label"
        )
        attach(app, named: "riderRecentDestinations-chosen")
    }

    /// `search` must be untouched — the fixture Recent list still stands in until a
    /// real history exists, which is the whole drift-gate guarantee.
    func testTheOrdinarySearchSceneStillCarriesNoRecents() {
        let app = launch("search")
        XCTAssertTrue(row(app, "home").waitForExistence(timeout: 6), "precondition: the SAVED fixtures render")
        for id in expected {
            XCTAssertFalse(row(app, id).exists, "\(id) must not appear on a scene with an empty store")
        }
        XCTAssertTrue(row(app, "tartine").exists, "the prototype's fixture Recent row is still what stands there")
    }

    // MARK: MYR-363b — the prompt

    /// The client's state, completed. The segment DEFAULTED to Schedule (nothing in
    /// the fleet can take an instant request), the rider picks a destination, and
    /// the picker opens itself — instead of a "Continue" that leads to a gated
    /// Review.
    func testPickingADestinationOpensTheSchedulePickerWhenTheSegmentDefaulted() {
        let app = launch("riderScheduleDefault", reason: "inService")
        let home = row(app, "home")
        XCTAssertTrue(home.waitForExistence(timeout: 6))
        home.tap()

        let card = app.staticTexts["Schedule pickup"]
        XCTAssertTrue(card.waitForExistence(timeout: 5), "the defaulted segment must ask for the time it needs")
        attach(app, named: "riderScheduleDefault-autoPrompt")
    }

    /// ONE SHOT PER DRAFT. Dismissing the card is final: picking a different
    /// destination does not raise it again.
    func testTheAutoPromptDoesNotReturnAfterAnExplicitDismiss() {
        let app = launch("riderScheduleDefault", reason: "inService")
        let home = row(app, "home")
        XCTAssertTrue(home.waitForExistence(timeout: 6))
        home.tap()

        let card = app.staticTexts["Schedule pickup"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        app.buttons["Close"].firstMatch.tap() // the EXPLICIT dismiss — "no thanks"
        XCTAssertTrue(app.buttons["mrt.search.changeTrip"].waitForExistence(timeout: 4))
        app.buttons["mrt.search.changeTrip"].tap() // back to search-as-you-type

        // Choose a DIFFERENT destination. ("Change trip" keeps the typed text by
        // design — MYR-250 item 3 — so clear it to get the pre-typing list back.)
        app.buttons["mrt.search.clearDestination"].tap()
        let work = row(app, "work")
        XCTAssertTrue(work.waitForExistence(timeout: 5))
        work.tap()

        XCTAssertFalse(
            app.staticTexts["Schedule pickup"].waitForExistence(timeout: 2.5),
            "the rider already answered this once for this draft"
        )
    }

    /// An AVAILABLE fleet is untouched — the picker only ever opens on a tap there,
    /// which is what `search` proves.
    func testAnAvailableFleetNeverOpensThePickerByItself() {
        let app = launch("search")
        let home = row(app, "home")
        XCTAssertTrue(home.waitForExistence(timeout: 6))
        home.tap()
        XCTAssertFalse(
            app.staticTexts["Schedule pickup"].waitForExistence(timeout: 2.5),
            "nobody asked to schedule"
        )
    }
}
