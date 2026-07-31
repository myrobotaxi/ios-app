import XCTest

// MARK: - MYR-385 — the card CONSULTS the rule, not just holds it
//
// `RideBookedWindowsTests` proves the rule: which slot a window blocks, which edge
// is exclusive, which sentence each `own`/`pending` pair earns, and that a failed
// read dims nothing. None of that says the SCHEDULE CARD reads it.
//
// This repo has been bitten by exactly that gap twice, and both times the pure
// suite stayed green. MYR-369's `VehicleRideShare.display` kept passing every one
// of its own tests while having ZERO call sites in shipping code — "a pure function
// with good tests and no callers is the quietest regression available". MYR-387's
// `ColdSnapshotLoad` published the honest end state correctly and `HomeScreen.body`
// asked a different question, so the branch was unreachable in production. The
// standing conclusion (`OwnerColdReadFailureUITests`) is that the pure suite proves
// the RULE and only a real launch proves the rule is what the screen consults.
//
// So this drives the real app on `riderScheduleBooked`, which injects the §7.22
// WIRE and runs the shipping provider, mapping, store and `RideScheduleFloor`
// against it. Everything asserted below is a thing the r15 rider would have seen —
// or, before this issue, would not have.
//
// FAILING-FIRST against the parent commit: the scene does not exist there, so every
// test fails at launch; with the scene alone but the card unwired, they fail on the
// caption, on the CTA still reporting itself enabled, and on the three noon chips
// still being in the accessibility tree.
final class ScheduleBookedWindowsUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private enum Labels {
        static let cardTitle = "Schedule pickup"
        /// The rider's OWN accepted reservation at Tomorrow · 12:00 PM — the r15
        /// collision itself, worded from `own`.
        static let ownConflict = "You already have a ride around this time"
        /// The slot the scene opens on, and the one the server would refuse.
        static let bookedSlot = "12:00 PM"
        /// Strictly outside the ±45min window around noon, so it stays bookable.
        static let freeSlot = "1:00 PM"
    }

    private func attach(_ app: XCUIApplication, named: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = named
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func launchBookedPicker() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MRT_SCENE"] = "riderScheduleBooked"
        app.launch()
        XCTAssertTrue(
            app.staticTexts[Labels.cardTitle].waitForExistence(timeout: 20),
            "the schedule card should be open — the scene arms it through `opensScheduleOnSearch`"
        )
        return app
    }

    private func setPickupCTA(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Set pickup")).firstMatch
    }

    // THE R15 REPORT, ANSWERED. The picker opens on the rider's own booked noon —
    // the "becomes conflicted" branch, since the read lands after the card is
    // already up — and says so rather than offering the slot and letting the server
    // refuse it two taps later.
    func testTheCardExplainsAConflictItLearnedAboutAfterOpening() {
        let app = launchBookedPicker()

        // Before the read lands the picker is unrestricted — which is also exactly
        // the FAIL-OPEN rendering, and is why this assertion is worth making: the
        // caption has to ARRIVE, not be there from the first frame.
        let caption = app.staticTexts[Labels.ownConflict]
        XCTAssertTrue(caption.waitForExistence(timeout: 10), "the §7.22 read should explain the conflict")
        attach(app, named: "MYR-385 booked picker — own conflict caption")

        // It names the RIDER, not the car. "Lunar is booked around this time" said
        // to somebody looking at their own reservation is the r15 failure restated
        // as copy.
        XCTAssertFalse(app.staticTexts["Lunar is booked around this time"].exists)
    }

    // THE CTA GOES INERT on the conflicted slot. A picker that dims a chip and
    // leaves the button live has moved the refusal by one tap, not removed it.
    //
    // `isHittable` is deliberately NOT the assertion. `allowsHitTesting(false)`
    // makes SwiftUI drop the touch, but XCUITest still reports the element as
    // hittable — which is precisely why MYR-361 had to give `RideChip` an explicit
    // announcement rather than trusting the modifier, and why this CTA is now
    // `.disabled()` as well. So the two things actually worth proving are asserted:
    // the control SAYS it is disabled, and a tap on it commits nothing.
    func testTheCTAIsInertWhileTheSelectedSlotIsBooked() {
        let app = launchBookedPicker()
        XCTAssertTrue(app.staticTexts[Labels.ownConflict].waitForExistence(timeout: 10))

        let cta = setPickupCTA(app)
        XCTAssertTrue(cta.exists, "the CTA stays in the tree, dimmed — it is not hidden")
        XCTAssertTrue(cta.label.contains(Labels.bookedSlot), "it still names the slot the rider chose")
        XCTAssertFalse(cta.isEnabled, "an inert control has to announce it, not only look it")

        // And it genuinely commits nothing: the card would CLOSE on a successful
        // commit (`closeScheduleCard(committed:)`), so a card still standing is the
        // proof that the slot the server would 409 did not reach the draft. The tap
        // is conditional because a disabled element may or may not report itself
        // hittable, and `tap()` on a non-hittable one fails the test for the wrong
        // reason — either way the assertion below is the one that matters.
        if cta.isHittable { cta.tap() }
        XCTAssertTrue(app.staticTexts[Labels.cardTitle].exists, "a booked slot must not commit and close the card")
        attach(app, named: "MYR-385 booked picker — CTA inert after a tap")
    }

    // THE DIMMING IS SCOPED. Three chips go (11:30 / 12:00 / 12:30 — the ones
    // strictly inside the emitted window) and 1:00 PM does not, because a window is
    // an interval and not a floor. A blocked schedule chip is `accessibilityHidden`
    // by MYR-316's rule, so "gone from the accessibility tree" is how a dimmed chip
    // reads to a UI test.
    func testOnlyTheSlotsInsideTheWindowAreWithdrawn() {
        let app = launchBookedPicker()
        XCTAssertTrue(app.staticTexts[Labels.ownConflict].waitForExistence(timeout: 10))

        XCTAssertFalse(app.buttons[Labels.bookedSlot].exists, "noon is inside the window")
        XCTAssertFalse(app.buttons["11:30 AM"].exists)
        XCTAssertFalse(app.buttons["12:30 PM"].exists)
        XCTAssertTrue(app.buttons[Labels.freeSlot].exists, "1:00 PM is clear of a ±45min noon window")
        XCTAssertTrue(app.buttons["11:00 AM"].exists)
    }

    // A DAY IS NOT LOST TO A RESERVATION. Both of the scene's bookings are
    // Tomorrow, and Tomorrow still has a bookable morning and evening — so its chip
    // stays live. The rule mattered for MYR-316's floor; it matters far more for
    // scattered windows.
    func testTheDayChipStaysPickableWithABookedNoon() {
        let app = launchBookedPicker()
        XCTAssertTrue(app.staticTexts[Labels.ownConflict].waitForExistence(timeout: 10))

        let tomorrow = app.buttons["Tomorrow"]
        XCTAssertTrue(tomorrow.exists)
        XCTAssertTrue(tomorrow.isHittable, "one reservation must not withdraw a whole day")
        XCTAssertTrue(app.buttons["Today"].isHittable)
    }

    // NOTHING FLOORS THIS CAR. The scene's vehicle is PARKED with no service
    // window, so MYR-316's caption must be absent — which is what makes every
    // dimmed chip above attributable to §7.22 alone, and what makes this scene the
    // clean pair to `riderScheduleFloored`.
    func testNoServiceWindowCaptionIsShowingOnThisCar() {
        let app = launchBookedPicker()
        XCTAssertTrue(app.staticTexts[Labels.ownConflict].waitForExistence(timeout: 10))

        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "is in service until")).firstMatch.exists
        )
    }
}
