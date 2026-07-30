import XCTest

// MARK: - MYR-361 — the schedule card, the segment, and the sheet that hosts them
//
// Three TestFlight items on build 202607300926, all one flow, all needing a real
// running app:
//
//  1. AKwpPQIV — *"Even though no car is available right now it's still allowing
//     me to request a ride right now. Vs defaulting to scheduling."*
//  2. AFYmN2g8 — *"When I select on schedule it feels weird with the bottom sheet
//     appearing over another bottom sheet. Additionally, scheduled should be
//     selected instead of now."*
//  3. *"Just set the time and it didn't stick or update on the sheet."*
//
// FAILING-FIRST, verified against origin/main (06f4627):
//
//  • The default tests fail at `Schedule.isSelected` — before this issue the
//    segment read `draftSchedule == nil`, i.e. "Now", with the whole fleet in a
//    service bay. (They ALSO fail earlier, on the `riderScheduleDefault` scene not
//    existing.)
//  • `testTheSegmentFollowsTheOpenCard` fails on `Schedule.isSelected`: the chips
//    carried no `.isSelected` trait at all before this issue, so the state was
//    invisible to VoiceOver AND unassertable — which is a large part of why it
//    could drift unnoticed.
//  • `testTheCardNeverCoversTheSegmentThatHostsIt` fails on measured geometry.
//    On `riderScheduleFloored` (the collapsed, destination-chosen sheet the client
//    photographed) the segment sits at y=550.2…581.8 and the card's top edge lands
//    at y≈570 — **~12pt of overlap**, the sliced chip row in AFYmN2g8. Measured on
//    the card's TITLE, which is the stable queryable anchor, that is 8.33pt of
//    clearance before the fix against the 40pt this test requires; after the fix
//    the same measurement is 314pt (the chips move to y=224 as the sheet takes the
//    prototype's own 712 search envelope).
final class ScheduleSegmentAndCardUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private enum Labels {
        static let cardTitle = "Schedule pickup"
        static let now = "Now"
        static let schedule = "Schedule"
        static let reasonCaption = "mrt.search.nowUnavailableReason"
    }

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

    private func setPickupCTA(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Set pickup")).firstMatch
    }

    /// The "Pickup {day} · {time}" summary row — the ONE thing on the sheet that
    /// proves a chosen time landed in the draft.
    private func pickupSummaryRow(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Pickup ")).firstMatch
    }

    // MARK: 1 — the default (the client's AKwpPQIV)

    /// The three reasons that leave scheduling open: the sheet OPENS on Schedule,
    /// "Now" is dimmed, untappable and announced as disabled, and the caption under
    /// it is the same sentence the idle banner just showed.
    func testTheSegmentDefaultsToScheduleWhenNothingIsInstantlyRequestable() {
        for reason in ["inService", "offline", "busy"] {
            let app = launch("riderScheduleDefault", reason: reason)
            let schedule = app.buttons[Labels.schedule]
            XCTAssertTrue(schedule.waitForExistence(timeout: 20), "\(reason): the search sheet")
            attach(app, named: "MYR-361 default-to-schedule (\(reason))")

            XCTAssertTrue(schedule.isSelected, "\(reason): the segment must open on Schedule")

            let now = app.buttons[Labels.now]
            XCTAssertTrue(now.exists, "\(reason): 'Now' stays VISIBLE and dimmed — a vanished half is worse than a disabled one")
            XCTAssertFalse(now.isSelected, "\(reason): 'Now' must not be the selected half")
            XCTAssertFalse(now.isEnabled, "\(reason): 'Now' must announce as disabled, not just look it")

            let caption = app.staticTexts[Labels.reasonCaption]
            XCTAssertTrue(caption.waitForExistence(timeout: 5), "\(reason): a disabled 'Now' must say why")
            XCTAssertFalse(caption.label.isEmpty)
            app.terminate()
        }
    }

    /// PAUSED changes nothing, and this is the assertion that keeps the carve-out
    /// honest: the server refuses reservations against a paused car too, so a
    /// Schedule default here would be a longer walk to the same `409`.
    func testAPausedFleetLeavesTheSegmentExactlyAsItWas() {
        let app = launch("riderScheduleDefault", reason: "paused")
        let now = app.buttons[Labels.now]
        XCTAssertTrue(now.waitForExistence(timeout: 20))
        attach(app, named: "MYR-361 paused fleet leaves the segment alone")

        XCTAssertTrue(now.isSelected, "a paused fleet must not be pointed at a picker that will also refuse")
        XCTAssertTrue(now.isEnabled, "and must not be dimmed with nowhere to go")
        XCTAssertFalse(app.buttons[Labels.schedule].isSelected)
        XCTAssertFalse(
            app.staticTexts[Labels.reasonCaption].exists,
            "no caption: the segment is making no claim here at all"
        )
    }

    // MARK: 2 — the segment follows the card

    /// *"scheduled should be selected instead of now"*, in the client's literal
    /// order: open the picker → Schedule lights immediately; commit → it stays and
    /// the summary row appears; clear with "Now" → back to Now.
    func testTheSegmentFollowsTheOpenCardAndTheCommittedDraft() {
        let app = launch("search")
        let schedule = app.buttons[Labels.schedule]
        XCTAssertTrue(schedule.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons[Labels.now].isSelected, "precondition: an available fleet opens on Now")

        schedule.tap()
        XCTAssertTrue(app.staticTexts[Labels.cardTitle].waitForExistence(timeout: 10))
        attach(app, named: "MYR-361 segment while the picker is open")
        XCTAssertTrue(
            app.buttons[Labels.schedule].isSelected,
            "a rider standing in the picker is scheduling — 'Now' must not stay lit underneath it"
        )
        XCTAssertFalse(app.buttons[Labels.now].isSelected)

        let cta = setPickupCTA(app)
        XCTAssertTrue(cta.waitForExistence(timeout: 10))
        cta.tap()
        XCTAssertTrue(pickupSummaryRow(app).waitForExistence(timeout: 10), "committing writes the summary row")
        XCTAssertTrue(app.buttons[Labels.schedule].isSelected, "and the segment stays on Schedule")
        XCTAssertFalse(app.buttons[Labels.now].isSelected)

        app.buttons[Labels.now].tap()
        XCTAssertTrue(app.buttons[Labels.now].isSelected, "clearing returns to Now on an available fleet")
        XCTAssertFalse(app.buttons[Labels.schedule].isSelected)
        XCTAssertFalse(pickupSummaryRow(app).exists, "and takes the summary row with it")
    }

    /// CANCELLING the picker commits nothing, so the segment falls straight back —
    /// there is no third store remembering that the card was once up.
    func testCancellingThePickerRestoresNow() {
        let app = launch("search")
        XCTAssertTrue(app.buttons[Labels.schedule].waitForExistence(timeout: 20))
        app.buttons[Labels.schedule].tap()
        XCTAssertTrue(app.staticTexts[Labels.cardTitle].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons[Labels.schedule].isSelected)

        app.buttons["Close"].tap()
        XCTAssertFalse(app.staticTexts[Labels.cardTitle].waitForExistence(timeout: 2))
        attach(app, named: "MYR-361 segment after cancelling the picker")
        XCTAssertTrue(app.buttons[Labels.now].isSelected, "cancelling with nothing committed restores Now")
        XCTAssertFalse(pickupSummaryRow(app).exists)
    }

    // MARK: 3 — the chosen time reaches the sheet, and is VISIBLE there

    /// The client's *"just set the time and it didn't stick or update on the
    /// sheet"*, in the state his screenshot was taken in: a destination already
    /// chosen, so the sheet is COLLAPSED (MYR-216).
    ///
    /// THIS TEST PASSES ON origin/main, AND THAT IS THE FINDING. Traced end to end,
    /// the card's confirm → draft → sheet path is ONE seam with no second copy:
    /// `MRTButton`'s action writes `viewerState.draftSchedule` and every reader
    /// (`chipRow`, `scheduleRow`, `RideRequestCTAGate.isScheduled`,
    /// `RideRequestContractMapping.scheduledFor`) reads that one `@Observable`
    /// property. The commit sticks on the first write, on a second write through
    /// the Edit row, and clears through "Now" — all three asserted here and all
    /// three green before the fix.
    ///
    /// What the rider could not SEE is a different thing, and it is real: on this
    /// same collapsed sheet the card overlapped the segment (and the band the
    /// summary row is written into) by 12pt — see
    /// `testTheCardNeverCoversTheSegmentThatHostsIt`, which is the failing-first
    /// half of item 3. This test is the regression guard that the seam itself
    /// stays sound.
    func testTheChosenTimeLandsOnTheSheetAndIsVisibleThere() {
        let app = launch("riderScheduleFloored")
        XCTAssertTrue(app.staticTexts[Labels.cardTitle].waitForExistence(timeout: 20))
        let cta = setPickupCTA(app)
        XCTAssertTrue(cta.waitForExistence(timeout: 10))
        let chosen = cta.label // "Set pickup · Thu 7:00 AM"
        cta.tap()

        let row = pickupSummaryRow(app)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the chosen time must reach the sheet")
        attach(app, named: "MYR-361 chosen time on the collapsed sheet")

        // The row quotes exactly what the CTA promised — "Set pickup · X" → "Pickup X".
        let promised = chosen.replacingOccurrences(of: "Set pickup · ", with: "")
        XCTAssertTrue(
            row.label.contains(promised.replacingOccurrences(of: " ", with: " · ")) || row.label.contains(promised.split(separator: " ").first.map(String.init) ?? ""),
            "the summary row must quote the committed slot — CTA said '\(chosen)', row says '\(row.label)'"
        )
        XCTAssertTrue(row.isHittable, "and it must be reachable, not buried under a card or off the sheet")
        XCTAssertTrue(app.buttons[Labels.schedule].isSelected)
    }

    /// The SECOND edit — reopen through the summary row's Edit and pick a different
    /// slot. The draft is one seam, so a re-commit must overwrite rather than
    /// stack, and the row must re-render.
    func testASecondEditOverwritesTheChosenTime() {
        let app = launch("search")
        XCTAssertTrue(app.buttons[Labels.schedule].waitForExistence(timeout: 20))
        app.buttons[Labels.schedule].tap()
        var cta = setPickupCTA(app)
        XCTAssertTrue(cta.waitForExistence(timeout: 10))
        cta.tap()

        let row = pickupSummaryRow(app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let first = row.label

        row.tap()
        XCTAssertTrue(app.staticTexts[Labels.cardTitle].waitForExistence(timeout: 10))
        let later = app.buttons["8:00 PM"]
        XCTAssertTrue(later.waitForExistence(timeout: 5))
        later.tap()
        XCTAssertTrue(later.isSelected, "the tapped time chip is the selected one")
        cta = setPickupCTA(app)
        XCTAssertTrue(cta.label.hasSuffix("8:00 PM"), "the CTA follows the picker — got '\(cta.label)'")
        cta.tap()

        let updated = pickupSummaryRow(app)
        XCTAssertTrue(updated.waitForExistence(timeout: 10))
        attach(app, named: "MYR-361 second edit overwrote the slot")
        XCTAssertNotEqual(updated.label, first, "a second commit must overwrite the first")
        XCTAssertTrue(updated.label.contains("8:00 PM"), "got '\(updated.label)'")
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Pickup ")).count, 1,
            "one draft, one row — a second commit must not stack a second summary"
        )
    }

    // MARK: 4 — the presentation (the client's "a sheet over a sheet")

    /// THE MEASURED GUARD. `RideSlideUpCard` is hosted INSIDE the search sheet
    /// (ride-request.jsx:302 puts the picker at `top:-14 … bottom:-24` of the search
    /// content box), and the prototype can never collide with its own chrome because
    /// its search sheet is pinned at `SHEET_HEIGHTS.search` = 712. Ours is measured
    /// and MYR-216 collapses it once a destination is chosen — so the card could end
    /// up TALLER than the sheet hosting it and slice the segment in half.
    ///
    /// Asserted on every state the card can be opened in, including the collapsed
    /// one the client photographed.
    /// `riderScheduleFloored` LEADS the loop deliberately: it is the collapsed
    /// state the client photographed and the only one that overlapped, so a
    /// `continueAfterFailure = false` run fails on the real defect rather than on a
    /// scene that was already fine.
    func testTheCardNeverCoversTheSegmentThatHostsIt() {
        for scene in ["riderScheduleFloored", "searchSelected", "search"] {
            let app = launch(scene)
            if scene != "riderScheduleFloored" {
                XCTAssertTrue(app.buttons[Labels.schedule].waitForExistence(timeout: 20), scene)
                app.buttons[Labels.schedule].tap()
            }
            XCTAssertTrue(app.staticTexts[Labels.cardTitle].waitForExistence(timeout: 20), scene)
            // Past the 0.34s present curve so both surfaces have settled.
            Thread.sleep(forTimeInterval: 1.0)
            attach(app, named: "MYR-361 card over sheet (\(scene))")

            let card = app.staticTexts[Labels.cardTitle].frame
            let chips = app.buttons[Labels.schedule].frame
            XCTAssertGreaterThan(chips.height, 0, "\(scene): the segment must still be laid out")
            XCTAssertLessThan(
                chips.maxY, card.minY,
                "\(scene): the card's title starts at y=\(card.minY) but the segment runs to y=\(chips.maxY) — the card is covering the sheet's own chrome, which is the client's 'sheet over a sheet'"
            )
            // …and it is genuinely a card INSIDE a sheet, not a second sheet resting
            // on the first: the prototype leaves the whole search list between the
            // two, so anything under ~40pt of clearance reads as two stacked sheets.
            XCTAssertGreaterThan(
                card.minY - chips.maxY, 40,
                "\(scene): only \(card.minY - chips.maxY)pt between the segment and the card"
            )
            app.terminate()
        }
    }

    /// ONE grab handle. The sheet's is decorative and the card deliberately has
    /// none (ride-request.jsx:303-306 gives it a title row + close button instead),
    /// so two handles would be the surest sign the card had become a second sheet.
    func testExactlyOneGrabHandleIsPresentWhileTheCardIsOpen() {
        let app = launch("riderScheduleFloored")
        XCTAssertTrue(app.staticTexts[Labels.cardTitle].waitForExistence(timeout: 20))
        XCTAssertTrue(
            app.buttons["Close"].waitForExistence(timeout: 5),
            "the card dismisses through its own close button, not a handle"
        )
        XCTAssertLessThanOrEqual(
            app.otherElements.matching(identifier: "mrt.riderSheet").count, 1,
            "one sheet surface, one handle"
        )
    }
}
