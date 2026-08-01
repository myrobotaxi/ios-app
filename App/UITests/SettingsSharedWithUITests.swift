import XCTest

// MARK: - MYR-392 — owner Settings actually READS the roster it renders
//
// The headline defect is an ABSENCE, and an absence is exactly what a pure test
// cannot see: `SettingsScreen.sharedWithCard` rendered `shareService.viewers`,
// `ShareService.load()` had two call sites and both were on `InvitesScreen`, and
// nothing anywhere disagreed. The card said "No one has access yet." for the
// whole session over a roster nobody had fetched, and every unit test about the
// sharing service stayed green.
//
// So the guard has to be a real launch — this repo's MYR-387 lesson
// (`OwnerColdReadFailureUITests` beside `OwnerColdLaunchHonestyTests`): the pure
// suite proves the RULE, and only a mounted screen proves the rule is what the
// screen consults.
//
// **WHY THE UNREACHABLE SCENE IS THE ONE THAT PROVES IT.** `.idle` and `.loading`
// deliberately render the SAME skeleton, so a read parked in flight looks
// identical whether the screen asked or never did. Only a read that FAILS moves
// the phase somewhere `.idle` cannot go. On the pre-fix screen
// `ownerSettingsShareUnreachable` shimmers for ever; with the `.task` it settles
// on the service's sentence within a second.
final class SettingsSharedWithUITests: XCTestCase {

    /// The skeleton's own VoiceOver label (`SettingsSharedWithSkeleton
    /// .accessibilityLabel`) — the only handle a placeholder has, since it carries
    /// no text.
    private let skeletonLabel = "Loading who this car is shared with"
    /// `LiveShareService.unreadableMessage`.
    private let failureSentence = "Can\u{2019}t load sharing right now"
    private let emptyNotice = "No one has access yet."

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

    /// **THE HEADLINE, FAILING-FIRST.** Without the screen's own
    /// `.task { await shareService.load() }` the phase never leaves `.idle`, this
    /// sentence never appears, and the card shimmers indefinitely.
    func testSettingsAsksForTheRosterAndSaysSoWhenTheReadFails() {
        let app = launch(scene: "ownerSettingsShareUnreachable")
        let sentence = app.staticTexts[failureSentence]
        XCTAssertTrue(
            sentence.waitForExistence(timeout: 20),
            "owner Settings never asked for the roster — the phase stayed .idle (MYR-392)"
        )
        attach(app, named: "ownerSettingsShareUnreachable")

        // A FAILED READ IS NOT AN EMPTY LIST. "No one has access yet." is a claim
        // about the account that a read which did not answer cannot support.
        XCTAssertFalse(
            app.staticTexts[emptyNotice].exists,
            "a failed roster read must never assert that nobody has access"
        )
        // And no shimmer over a settled failure (MYR-326's rule).
        XCTAssertFalse(
            app.descendants(matching: .any)[skeletonLabel].exists,
            "a placeholder over a settled failure is the eternal skeleton"
        )
    }

    /// The failure arm carries NO CTA — MYR-386's grammar, applied to this card.
    /// The "Invite someone" row would route to a Share tab failing the identical
    /// read, and minting a code onto a roster the app cannot see is not an offer
    /// to make. Recovery is the low-friction one: a resume re-asks.
    func testTheFailedCardOffersNoWayToInviteOverARosterItCannotSee() {
        let app = launch(scene: "ownerSettingsShareUnreachable")
        XCTAssertTrue(app.staticTexts[failureSentence].waitForExistence(timeout: 20))
        XCTAssertFalse(
            app.buttons["Invite someone"].exists,
            "the failure arm grew a CTA — MYR-386's grammar says the sentence stands alone"
        )
    }

    /// THE CLIENT'S FRAME, on this surface: the read is genuinely in flight, so
    /// the card is row-shaped placeholders and NOT the definitive notice.
    func testAnInFlightRosterShowsTheSkeletonAndNotTheNotice() {
        let app = launch(scene: "ownerSettingsShareLoading")
        XCTAssertTrue(
            app.descendants(matching: .any)[skeletonLabel].waitForExistence(timeout: 20),
            "the in-flight roster did not render its placeholder rows"
        )
        attach(app, named: "ownerSettingsShareLoading")
        XCTAssertFalse(
            app.staticTexts[emptyNotice].exists,
            "\"No one has access yet.\" over a fetch that has not answered — the MYR-392 defect"
        )
        // The count badge is part of the same claim: "0 people" over a shimmering
        // card is the false statement in three characters.
        XCTAssertFalse(app.staticTexts["0 people"].exists, "a count nobody has been told")
    }

    /// THE OTHER HALF OF THE PAIR — the simulated page, which must be exactly what
    /// it always was: three fixture viewers, the count badge, the invite row, and
    /// no placeholder anywhere.
    func testTheSimulatedSettingsPageIsUnchanged() {
        let app = launch(scene: "ownerSettingsTop")
        XCTAssertTrue(app.staticTexts["Shared with"].waitForExistence(timeout: 20))
        XCTAssertFalse(
            app.descendants(matching: .any)[skeletonLabel].exists,
            "a simulated capture reached a skeleton — the drift gate just moved"
        )
        XCTAssertFalse(app.staticTexts[emptyNotice].exists)
        XCTAssertFalse(app.staticTexts[failureSentence].exists)
        XCTAssertTrue(app.staticTexts["3 people"].exists, "the fixture roster's own count")
    }
}
