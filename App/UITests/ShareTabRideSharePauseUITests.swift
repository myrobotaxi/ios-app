import XCTest

// MARK: - MYR-360's pause warning, on the surface MYR-369 moved its switch to
//
// THIS TEST EXISTS BECAUSE THE UNIT TESTS CANNOT SEE THE DEFECT IT GUARDS.
//
// `ShareTabRideShareRelocationTests` drives `RideSharePauseFlow` through
// `ShareServiceRideSharePauseTarget` and proves the seam behaves: a booked ride
// raises the warning, an empty list writes straight through. Every one of those
// assertions passes on the BROKEN build too — because the bug was never in the
// flow or the seam. It was that `InvitesScreen` did not call them at all: MYR-369
// moved the ride-share switch onto the Share tab and wired it directly to
// `shareService.setVehicleRideShareEnabled`, so the pre-flight simply never ran.
//
// A regression that re-points the screen back at the service is invisible to
// every unit test in this repo and produces no compiler error, no failed decode
// and no changed pixel until a real owner strands a real rider. The only thing
// that catches it is asking the actual screen to pause an actual car that has an
// actual reservation on it — which is what this does, through the `MRT_SCENE`
// hook the drift-gate captures already use.
//
// The scene does the tap for us (`flipsRideShareOnBoot`), because headless
// tooling cannot reach a switch; everything after that is the shipping path —
// the real fetch, the real `RideSharePause.decide`, the real dialog copy.
final class ShareTabRideSharePauseUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(scene: String) -> XCUIApplication {
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

    /// **THE GUARD.** An owner pauses ride sharing on a car carrying an ACCEPTED
    /// future reservation, and the warning dialog comes up before anything is
    /// written.
    ///
    /// Asserted on the dialog's own copy rather than on an accessibility id, so it
    /// is the OWNER-FACING sentence that is pinned: a dialog that appeared with
    /// different words would be a different product decision, and a dialog that
    /// did not appear is the regression.
    func testPausingOverAnAcceptedReservationRaisesTheWarningOnTheShareTab() {
        let app = launch(scene: "ownerRideSharePauseWarning")

        let title = app.staticTexts["Pause ride sharing?"]
        XCTAssertTrue(
            title.waitForExistence(timeout: 10),
            """
            The Share tab paused a car with an accepted reservation on it and never \
            asked. This is MYR-360's whole defect, restored: the rider learns nobody \
            is coming 30 minutes AFTER the pickup they planned around. Check that \
            InvitesScreen still commits through RideSharePauseFlow rather than \
            calling shareService.setVehicleRideShareEnabled directly.
            """
        )
        attach(app, named: "share-tab-pause-warning")

        // The reservation itself is in the dialog — the list is the point, not the
        // sentence. "Alex" is the scene's scripted rider.
        XCTAssertTrue(
            app.staticTexts["Alex"].exists,
            "the warning must name what is booked, not just that something is"
        )
        // The singular confirm label: one reservation, one ride to decline.
        XCTAssertTrue(app.buttons["Decline it and pause"].exists)
        // And the way out that keeps the car sharing.
        XCTAssertTrue(app.buttons["Keep sharing"].exists)
    }

    /// The MULTI arm: the confirm label pluralises and the display cap rolls the
    /// fourth reservation up rather than dropping it silently.
    func testTheMultiReservationWarningPluralisesAndRollsUpPastTheCap() {
        let app = launch(scene: "ownerRideSharePauseWarningMulti")

        XCTAssertTrue(
            app.staticTexts["Pause ride sharing?"].waitForExistence(timeout: 10),
            "the multi arm must raise the same warning"
        )
        attach(app, named: "share-tab-pause-warning-multi")

        XCTAssertTrue(
            app.buttons["Decline them and pause"].exists,
            "four reservations take the plural label"
        )
        XCTAssertTrue(
            app.staticTexts["+1 more"].exists,
            "the fourth is rolled up, so the owner still knows the SIZE of what they are deciding"
        )
        // The honest fallback for the row whose wire carried no requester name.
        XCTAssertTrue(
            app.staticTexts["A rider"].exists,
            "a nameless reservation is named honestly, never invented and never dropped"
        )
    }

    /// **THE OTHER HALF OF THE GUARD, AND THE ONE THAT KEEPS IT HONEST.** A car
    /// with NOTHING booked must pause with no dialog at all.
    ///
    /// Without this, the test above could be satisfied by a screen that warned on
    /// every pause — which would "fix" the regression by taxing every owner for a
    /// situation that does not exist. `ownerShareControls` is the same Share tab
    /// with the same relocated card and no reservation source at all.
    func testACarWithNothingBookedRaisesNoDialogAtAll() {
        let app = launch(scene: "ownerShareControls")

        // The tab is up and the relocated card is rendering.
        XCTAssertTrue(
            app.staticTexts["Ride sharing"].waitForExistence(timeout: 10),
            "the relocated ride-share card leads the Share tab"
        )
        // Give the boot sequence the same room the warning scenes get, then assert
        // ABSENCE — a `waitForExistence` cannot express "and it never appeared".
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(
            app.staticTexts["Pause ride sharing?"].exists,
            "nothing is booked — an owner must not be asked about reservations that do not exist"
        )
        attach(app, named: "share-tab-no-warning")
    }
}
