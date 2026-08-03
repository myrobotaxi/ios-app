import XCTest

// MARK: - MYR-379 — type a pickup, fine-tune it on the map, ride from it
//
// The client, r18: *"No option to type in pick up location and then fine set up
// exact spot to pick up on map. It locks to current location."*
//
// THIS IS A UI TEST BECAUSE THE FEATURE IS A SEQUENCE, and the repo has been
// bitten twice by the alternative (MYR-387 defect 2, MYR-369's
// `VehicleRideShare.display`): a pure suite proves the RULE, and only a real
// launch proves the rule is what the SCREEN consults. `RiderPickupSelectionTests`
// pins the state machine — the entry ladder, the seed's lifetime, the coordinate
// that reaches the wire. What it cannot show is that tapping a row while the
// pickup field holds first responder commits to the PICKUP rather than the
// destination, because that decision lives in a `@State` the pure suite has no
// access to (`RideRequestSearchContent.searchTarget`).
//
// ⚠️ ONE ADAPTATION, STATED RATHER THAN GLOSSED. The issue asks for "Review
// showing the adjusted pickup label". **Review has no pickup-label element to
// assert on** — `RideRequestReviewContent:223` renders the pickup as a
// `statPair(label: "Pick-up", …)`, i.e. a CLOCK and an "N min away" sub, and the
// pickup's PLACE only reappears on Booking's and Tracking's itineraries. So the
// label assertion lands on the surface that does render it (the search sheet's
// own pickup row, carrying the labeler's output after the confirm) and Review is
// asserted for the thing it can actually prove: that it is reached DIRECTLY,
// with no second pin-drop, which is only true when the pickup is genuinely
// committed.
final class RiderPickupSearchUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private enum Labels {
        /// `RideRequestPinDropContent`'s commit CTA (ride-request.jsx:735).
        static let confirmPin = "Confirm pickup here"
        /// The pin-drop's back chevron — the exit that commits nothing.
        static let changeTrip = "Change trip"
        /// The search sheet's advance CTA (MYR-215 deliverable 3).
        static let cont = "Continue"
        /// Review's instant CTA — the fixture owner is `RideRequestFixtures.fleet[0]`.
        static let reviewCTA = "Request from Alex"
        /// What `SimulatedPinLabeler` resolves every pin to
        /// (`RideRequestFixtures.pinSpots[0]`), so the confirmed pickup's label is
        /// deterministic in sim.
        static let simPinLabel = "Folsom & 2nd St"
        /// The pickup field's placeholder — `SharedViewerState.pickupFallbackLabel`,
        /// i.e. the untouched "Current location" default made visible.
        static let pickupPlaceholder = "Current location"
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

    private func pickupField(_ app: XCUIApplication) -> XCUIElement {
        app.textFields["mrt.search.pickupField"]
    }

    /// ⚠️ MEASURED, NOT ASSUMED: on this runtime the keyboard covers the ENTIRE
    /// search sheet below the Now/Schedule chips — the route card and every result
    /// row. The first run of this file found `mrt.search.pickup.ferry` present at
    /// y=702 and reported "not hittable", and full-frame captures of
    /// `searchFiltered` and `riderPickupSearch` with the keyboard up are
    /// pixel-identical pictures of a keyboard. It is PRE-EXISTING (the destination
    /// field behaves the same, and MYR-356 hit it first — that is why
    /// `suppressesSearchAutoFocus` exists), so this is not something the pickup
    /// field introduced.
    ///
    /// Dismissing does NOT weaken what follows: `searchTarget` is set on focus
    /// GAIN and is not reset by resigning, so the list still belongs to the pickup
    /// — which the `mrt.search.pickup.*` identifier then proves on the very next
    /// line rather than assuming.
    private func dismissKeyboard(_ app: XCUIApplication) {
        if app.keyboards.buttons["return"].exists {
            app.keyboards.buttons["return"].tap()
        } else {
            app.keyboards.firstMatch.swipeDown()
        }
    }

    /// A pickup result row. The identifier carries the TARGET (MYR-379), so this
    /// query fails rather than silently tapping a destination row if the sheet
    /// ever stops routing the list to the pickup.
    private func pickupRow(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.buttons["mrt.search.pickup.\(id)"]
    }

    // MARK: The client's sequence

    /// Type a pickup → tap it → land in the pin-drop → confirm → the pickup row
    /// carries it → choose a destination → Review, directly.
    func testTypingAPickupChainsIntoThePinDropAndCommitsAPickup() {
        let app = launch("search")

        let pickup = pickupField(app)
        XCTAssertTrue(pickup.waitForExistence(timeout: 10), "the pickup row is a FIELD now, not a label")
        // The empty state is drawn as our own full-strength `Text`, not as the
        // system's muted placeholder — see the overlay's note in `routeCard`.
        XCTAssertTrue(
            app.staticTexts[Labels.pickupPlaceholder].exists,
            "and its empty state still says exactly what it said before"
        )

        pickup.tap()
        pickup.typeText("fer")
        dismissKeyboard(app)
        attach(app, named: "01-pickup-field-typing")

        // The results list belongs to the pickup now — the identifier proves it.
        let ferry = pickupRow(app, "ferry")
        XCTAssertTrue(
            ferry.waitForExistence(timeout: 10),
            "the results list must serve the field that holds first responder"
        )
        ferry.tap()

        // THE CHAIN. This is the half the client said was missing: a typed pickup
        // does not just fill a field, it opens the map so the exact spot can be set.
        let confirm = app.buttons[Labels.confirmPin]
        XCTAssertTrue(
            confirm.waitForExistence(timeout: 10),
            "selecting a searched pickup must chain into the pin-drop"
        )
        attach(app, named: "02-seeded-pin-drop")

        confirm.tap()

        // Back on the search sheet, with the pin's own label in the pickup row —
        // one representation, resolved by the same labeler a map-led pickup uses.
        XCTAssertTrue(
            pickupField(app).waitForExistence(timeout: 10),
            "confirming returns to the search sheet"
        )
        XCTAssertEqual(
            pickupField(app).value as? String, Labels.simPinLabel,
            "the pickup row carries the CONFIRMED pin, not the typed query"
        )
        attach(app, named: "03-pickup-committed")

        // And the pickup is genuinely committed: choosing a destination now goes
        // STRAIGHT to Review. Before a pickup exists, `selectDestination` routes
        // through a pin-drop instead — so reaching Review in one step is the
        // assertion that the chain produced a real `draftPickup`.
        let sfo = app.buttons["mrt.search.dest.sfo"]
        XCTAssertTrue(sfo.waitForExistence(timeout: 10), "the list is back on the destination")
        dismissKeyboard(app) // MYR-250's auto-focus, back up on this arrival
        sfo.tap()

        let cont = app.buttons[Labels.cont]
        XCTAssertTrue(cont.waitForExistence(timeout: 10), "the destination step's CTA")
        cont.tap()

        XCTAssertTrue(
            app.buttons[Labels.reviewCTA].waitForExistence(timeout: 10),
            "Review is reached directly — no second pin-drop, because the pickup is set"
        )
        XCTAssertFalse(
            app.buttons[Labels.confirmPin].exists,
            "and emphatically NOT the pin-drop again"
        )
        attach(app, named: "04-review-reached")
    }

    /// The abandoned chain. Backing out of the seeded pin-drop commits nothing, so
    /// the row has to say so — a field still holding "Ferry Building" over a draft
    /// with no pickup is MYR-248's stale dead "Continue" wearing a pickup's name.
    func testBackingOutOfTheChainLeavesTheRowOnCurrentLocation() {
        let app = launch("search")

        let pickup = pickupField(app)
        XCTAssertTrue(pickup.waitForExistence(timeout: 10))
        pickup.tap()
        pickup.typeText("fer")
        dismissKeyboard(app)

        let ferry = pickupRow(app, "ferry")
        XCTAssertTrue(ferry.waitForExistence(timeout: 10))
        ferry.tap()

        XCTAssertTrue(app.buttons[Labels.confirmPin].waitForExistence(timeout: 10))
        app.buttons[Labels.changeTrip].tap()

        let returned = pickupField(app)
        XCTAssertTrue(returned.waitForExistence(timeout: 10), "back on the search sheet")
        XCTAssertTrue(
            app.staticTexts[Labels.pickupPlaceholder].exists,
            "nothing was confirmed, so the row is back on the default"
        )
        // ⚠️ Asserted on the FIELD, not on the screen. A first cut checked that
        // `app.staticTexts["Ferry Building"]` was gone and failed — correctly:
        // the list is back on the destination's pre-typing sections and "Ferry
        // Building" is one of its RECENT rows. A row offering a place is not the
        // row CLAIMING one, and only the field can tell the two apart.
        XCTAssertTrue(
            (returned.value as? String ?? "").isEmpty,
            "and the abandoned pickup's name is not left standing in the field"
        )
        attach(app, named: "05-abandoned-chain-clears")
    }

    // MARK: The guarantee — "Current location" is untouched

    /// The regression guard for every rider who never touches the pickup row. The
    /// destination flow still routes through the pin-drop, because there is still
    /// no pickup — which is the pre-MYR-379 behaviour, reached by the
    /// pre-MYR-379 taps.
    func testARiderWhoNeverTouchesThePickupGetsTheUnchangedFlow() {
        let app = launch("search")

        let sfo = app.buttons["mrt.search.dest.sfo"]
        XCTAssertTrue(sfo.waitForExistence(timeout: 10), "the list starts on the DESTINATION")
        // MYR-250's auto-focus raises the keyboard 450ms after the sheet settles,
        // and it covers the list — see `dismissKeyboard`. Pre-existing, and the
        // reason this scene's own rows are out of a test's reach either way.
        dismissKeyboard(app)
        sfo.tap()

        let cont = app.buttons[Labels.cont]
        XCTAssertTrue(cont.waitForExistence(timeout: 10))
        cont.tap()

        XCTAssertTrue(
            app.buttons[Labels.confirmPin].waitForExistence(timeout: 10),
            "with no pickup set, the destination still routes through the pin-drop"
        )
        attach(app, named: "06-untouched-default-flow")
    }
}
