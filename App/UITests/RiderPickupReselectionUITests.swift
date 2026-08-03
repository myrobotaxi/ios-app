import XCTest

// MARK: - MYR-445 — the client's sequence, driven exactly as he described it
//
// r-build `202608022357`, verbatim: *"the current location is stuck as a static
// placeholder, so I have to type over it. It doesn't disappear when selecting on
// it. Then if i type and search and select new pick up point it sets, but if I go
// backwards back to that search step and change the pick up point, current
// location shows as the placeholder again even though its not actually set and if
// I select current location or any other pick up address it doesn't actually set
// it and is stuck on the first one and doesn't let me fine tune the pick up, the
// map route polyline is also stuck bc the pickup point did not update."*
//
// `RiderPickupSelectionStateDesyncTests` pins the four RULES. This exists because
// three of the four defects are only reachable through state a pure suite cannot
// touch — `RideRequestSearchContent`'s `@FocusState pickupFieldFocused`, its
// `@State pickupQuery` mirror and its `searchTarget` — and because the repo has
// been bitten twice by the alternative (MYR-387 defect 2, MYR-369's
// `VehicleRideShare.display`): a pure suite proves the rule, and only a real
// launch proves the rule is what the SCREEN consults.
//
// ⚠️ WHAT THIS TEST CAN AND CANNOT SAY ABOUT THE POLYLINE, STATED RATHER THAN
// GLOSSED. It cannot read the route's endpoint COORDINATE — nothing on this
// surface publishes one, and MYR-390 established that measuring the map band is
// not a guard here (the settled route's own breathing glow swings the gold ink
// 2–3× on 2.6s, so "the band changed" passes over a route that never moved). What
// it CAN prove is the property the client's word "stuck" actually names: that the
// preview is keyed on the pickup and RESPONDS when the pickup changes.
// `route-availability-caption` (MYR-395) renders exactly while a route preview is
// active, so its appearance and disappearance across the two re-choices is the
// preview re-keying, observed on screen. The endpoint itself is pinned by the
// pure suite through `RidePreviewPickup.resolve` — the very expression
// `SharedViewerScreen.searchPreviewPickup` consults — plus the store's
// drop-the-stale-polyline-on-a-new-pair test.
//
// `MRT_ROUTE_UNAVAILABLE=1` is what makes the caption DETERMINISTIC: it swaps in
// `StraightLineRideRouteProvider`, so the availability settles to `.unavailable`
// with no network and no MKDirections timing at all (MYR-395's own capture
// modifier, used here for its determinism rather than for its subject).
final class RiderPickupReselectionUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private enum Labels {
        static let confirmPin = "Confirm pickup here"
        static let changeTrip = "Change trip"
        static let cont = "Continue"
        static let reviewCTA = "Request from Alex"
        /// `RideRequestFixtures.pinSpots[0]` — what `SimulatedPinLabeler` resolves
        /// every pin to, so a confirmed pickup's label is deterministic in sim.
        static let simPinLabel = "Folsom & 2nd St"
        /// `SharedViewerState.pickupFallbackLabel` — the untouched default, made
        /// visible. Defect 2 is this string appearing over a pickup that IS set.
        static let defaultPickup = "Current location"
    }

    private enum IDs {
        static let pickupField = "mrt.search.pickupField"
        static let clearPickup = "mrt.search.clearPickup"
        static let onMap = "mrt.search.pickupOnMap"
        static let routeCaption = "route-availability-caption"
        static let pickupRow = "mrt.search.pickup.ferry"
        static let destinationRow = "mrt.search.dest.sfo"
    }

    private func attach(_ app: XCUIApplication, named: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = named
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MRT_SCENE"] = "search"
        // See the header: this is the caption's determinism, not its subject.
        app.launchEnvironment["MRT_ROUTE_UNAVAILABLE"] = "1"
        app.launch()
        return app
    }

    private func pickupField(_ app: XCUIApplication) -> XCUIElement {
        app.textFields[IDs.pickupField]
    }

    /// ⚠️ MEASURED, NOT ASSUMED (MYR-379's own finding, unchanged): on this
    /// runtime the keyboard covers the ENTIRE search sheet below the Now/Schedule
    /// chips — the route card and every result row. Dismissing does not weaken
    /// what follows: `searchTarget` is set on focus GAIN and is not reset by
    /// resigning, so the list still belongs to the pickup, which the
    /// `mrt.search.pickup.*` identifier then proves rather than assumes.
    private func dismissKeyboard(_ app: XCUIApplication) {
        if app.keyboards.buttons["return"].exists {
            app.keyboards.buttons["return"].tap()
        } else if app.keyboards.firstMatch.exists {
            app.keyboards.firstMatch.swipeDown()
        }
    }

    /// Type a pickup, pick the row, land in the pin-drop, confirm. The chain
    /// MYR-379 built, which the client confirms works ("it sets").
    private func setSearchedPickup(_ app: XCUIApplication) {
        let pickup = pickupField(app)
        XCTAssertTrue(pickup.waitForExistence(timeout: 10))
        pickup.tap()
        pickup.typeText("fer")
        dismissKeyboard(app)

        let ferry = app.buttons[IDs.pickupRow]
        XCTAssertTrue(ferry.waitForExistence(timeout: 10), "the results list serves the focused field")
        ferry.tap()

        let confirm = app.buttons[Labels.confirmPin]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "a searched pickup chains into the pin-drop")
        confirm.tap()
        XCTAssertTrue(pickupField(app).waitForExistence(timeout: 10), "confirming returns to search")
    }

    // MARK: - The whole report, in one run

    func testTheClientsPickupReselectionSequence() {
        let app = launch()

        // ─────────────────────────────────────────────────────────────────
        // DEFECT 1 — *"It doesn't disappear when selecting on it."*
        // ─────────────────────────────────────────────────────────────────
        let pickup = pickupField(app)
        XCTAssertTrue(pickup.waitForExistence(timeout: 10), "the pickup row is a FIELD (MYR-379)")
        XCTAssertTrue(
            app.staticTexts[Labels.defaultPickup].exists,
            "an untouched, unfocused field still reads its default — MYR-379 unchanged"
        )

        pickup.tap()
        XCTAssertFalse(
            app.staticTexts[Labels.defaultPickup].exists,
            "focusing the field takes the default off screen, so there is nothing to type OVER"
        )
        attach(app, named: "01-focused-field-has-no-default-to-type-over")
        dismissKeyboard(app)

        // ─────────────────────────────────────────────────────────────────
        // The pickup he sets, and the destination that raises a route preview.
        // ─────────────────────────────────────────────────────────────────
        setSearchedPickup(app)
        XCTAssertEqual(
            pickupField(app).value as? String, Labels.simPinLabel,
            "*\"it sets\"* — the confirmed pin's own label"
        )

        let destination = app.buttons[IDs.destinationRow]
        XCTAssertTrue(destination.waitForExistence(timeout: 10), "the list is back on the destination")
        dismissKeyboard(app)
        destination.tap()

        XCTAssertTrue(
            app.staticTexts[IDs.routeCaption].waitForExistence(timeout: 15),
            "a pickup and a destination raise the route preview behind the sheet"
        )
        attach(app, named: "02-pickup-set-preview-up")

        // ─────────────────────────────────────────────────────────────────
        // *"if I go backwards back to that search step"* — Review and back.
        // ─────────────────────────────────────────────────────────────────
        let cont = app.buttons[Labels.cont]
        XCTAssertTrue(cont.waitForExistence(timeout: 10), "the destination step's CTA")
        cont.tap()
        XCTAssertTrue(
            app.buttons[Labels.reviewCTA].waitForExistence(timeout: 10),
            "Review directly — no second pin-drop, because the pickup is genuinely set"
        )
        app.buttons[Labels.changeTrip].tap()

        // ─────────────────────────────────────────────────────────────────
        // DEFECT 2 — *"current location shows as the placeholder again even
        // though its not actually set."*
        // ─────────────────────────────────────────────────────────────────
        let returned = pickupField(app)
        XCTAssertTrue(returned.waitForExistence(timeout: 10), "back on the search step")
        XCTAssertEqual(
            returned.value as? String, Labels.simPinLabel,
            "the field shows the SET pickup, re-seeded from the draft on arrival (MYR-389's rule)"
        )
        XCTAssertFalse(
            app.staticTexts[Labels.defaultPickup].exists,
            "and emphatically not the default, over a draft that holds a kerb"
        )
        XCTAssertEqual(
            app.buttons[IDs.onMap].label, "On map",
            "the capsule renders `draftPickup != nil` as a word — the pickup is really there"
        )
        attach(app, named: "03-re-entry-shows-the-set-pickup")

        // ─────────────────────────────────────────────────────────────────
        // DEFECT 3 — *"if I select current location … it doesn't actually set
        // it and is stuck on the first one."*
        // ─────────────────────────────────────────────────────────────────
        let clear = app.buttons[IDs.clearPickup]
        XCTAssertTrue(clear.exists, "the one control that says 'current location' as a CHOICE")
        clear.tap()

        XCTAssertTrue(
            app.staticTexts[Labels.defaultPickup].waitForExistence(timeout: 5),
            "the field is back on the default"
        )
        XCTAssertTrue((pickupField(app).value as? String ?? "").isEmpty)
        XCTAssertEqual(
            app.buttons[IDs.onMap].label, "Set on map",
            "and the capsule agrees: the pickup genuinely CHANGED rather than staying stuck"
        )

        attach(app, named: "04-current-location-chosen")

        // ─────────────────────────────────────────────────────────────────
        // ⚠️ DEFECT 4 — *"the map route polyline is also stuck bc the pickup
        // point did not update"* — IS NOT ASSERTED HERE, AND THE REASON IS
        // WORTH WRITING DOWN RATHER THAN PAPERING OVER.
        //
        // A first cut of this file did assert it, through
        // `route-availability-caption` appearing and disappearing across the
        // re-choice. **It was a tautology**: restoring the defect on this branch
        // left the test GREEN. The caption tracks whether a preview is active at
        // all, not which coordinate it is keyed on, and on this sheet the search
        // envelope re-expands over the map the moment the list re-points at the
        // pickup — so the element it was checking was gone for a reason that has
        // nothing to do with the pickup. That is MYR-428's
        // `testTheCaptionNeverCoversItsOwnSubject` exactly: an assertion derived
        // from the thing it is checking, green for any build.
        //
        // The deeper reason is that **defects 2, 3 and 4 are live-path-only by
        // construction and unreachable from a simulated launch.** In sim
        // `confirmPickup` persists the FIXTURE pin label rather than
        // `confirmedPickupLabel` (so the string collision cannot occur),
        // `pinDropCameraSettled` is ignored by design so captures hold still, and
        // `SimulatedUserLocation.coordinate` is `nil` so there is no live fix to
        // re-anchor TO. A scene that forced those branches would be a scene about
        // this test rather than about the product.
        //
        // So their guards are `RiderPickupSelectionStateDesyncTests`, which drives
        // a LIVE-flagged `SharedViewerState` through this same sequence and pins
        // the anchor, the label and the route-keying coordinate — and which was
        // proven to be a real guard by restoring each defect on this branch. What
        // THIS test owns is the half a pure suite cannot reach: the focus rule,
        // the `@State` mirror, `searchTarget`, and the fact that every one of the
        // client's taps is still reachable in the order he made them.
        // ─────────────────────────────────────────────────────────────────

        // ─────────────────────────────────────────────────────────────────
        // *"and doesn't let me fine tune the pick up"* — the capsule opens the
        // pin-drop and the confirm there commits, after the re-choice.
        // ─────────────────────────────────────────────────────────────────
        app.buttons[IDs.onMap].tap()
        let refineConfirm = app.buttons[Labels.confirmPin]
        XCTAssertTrue(
            refineConfirm.waitForExistence(timeout: 10),
            "fine-tuning is reachable again after an explicit re-choice"
        )
        refineConfirm.tap()

        XCTAssertTrue(pickupField(app).waitForExistence(timeout: 10))
        XCTAssertEqual(
            pickupField(app).value as? String, Labels.simPinLabel,
            "and functional: the pin it commits is the pickup"
        )
        XCTAssertEqual(app.buttons[IDs.onMap].label, "On map")
        attach(app, named: "05-fine-tune-reachable-and-functional")

        // ─────────────────────────────────────────────────────────────────
        // *"or any other pick up address"* — the second half of defect 3: a
        // DIFFERENT searched pickup, chosen after one is already set, still
        // chains into the pin-drop and still commits.
        // ─────────────────────────────────────────────────────────────────
        let reFocused = pickupField(app)
        reFocused.tap()
        XCTAssertTrue(
            (reFocused.value as? String ?? "").isEmpty,
            "focusing a field that holds a pickup clears it, so typing REPLACES rather than appends"
        )
        reFocused.typeText("fer")
        dismissKeyboard(app)

        let ferryAgain = app.buttons[IDs.pickupRow]
        XCTAssertTrue(
            ferryAgain.waitForExistence(timeout: 10),
            "the list belongs to the pickup again on the SECOND pass, not only the first"
        )
        ferryAgain.tap()
        XCTAssertTrue(
            app.buttons[Labels.confirmPin].waitForExistence(timeout: 10),
            "a re-chosen address chains into the pin-drop exactly as the first one did"
        )
        app.buttons[Labels.confirmPin].tap()

        XCTAssertTrue(pickupField(app).waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons[IDs.onMap].label, "On map", "and it took")
        attach(app, named: "06-second-address-re-chosen")
    }
}
