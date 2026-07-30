import XCTest

// MARK: - MYR-339 — the 100%-FSD gold wash, driven on the REAL path
//
// The client photographed his PHONE, not a screenshot, because a screenshot of
// this screen looks right: *"When I screenshot the page looks normal with the
// gold for 100% FSD, but on the actual app on my phone it's gold even overlaying
// the map."*
//
// This target's job is the half a unit test cannot do: **reach the celebration
// at all.** The only headless capture route into a Drive Summary
// (`MRT_SCENE=ownerDrives MRT_OPEN_FIRST_DRIVE=1`) opens `DriveFixtures.drives[0]`
// — 14.2 of 14.6 mi, **97%** — so `isFullFSD` is false and not one celebration
// layer is ever constructed. That is CLAUDE.md's own "cold scenes passing while
// real paths fail" trap, in its purest form: the scene that exists for this
// screen cannot render the state this issue is about. The 100% drive is the
// SECOND row, reachable only by tapping it, which is what these tests do — and
// why the drift-gate captures for the celebration come from here rather than
// from a new DEBUG scene (the same precedent as `ExpandedRouteUITests`).
final class DriveSummaryGoldWashUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// `DriveFixtures.drives[1]` — 3.8 of 3.8 mi = 100% FSD, the celebration case.
    private static let fullFSDRow = "Embarcadero Center → Mission · Tartine"
    /// `DriveFixtures.drives[0]` — 14.2 of 14.6 mi = 97%, the control. No
    /// celebration may appear here, and this screen must stay byte-identical.
    private static let partialFSDRow = "Home → Embarcadero Center"

    private func attach(named name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Owner ⇢ Drives ⇢ a drive, by real taps on the real navigation path.
    private func openDrive(_ row: String, reduceMotion: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MRT_SCENE"] = "ownerDrives"
        app.launch()

        let cell = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", row)).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 20), "the drive row \"\(row)\" must be on the Drives tab")
        cell.tap()
        XCTAssertTrue(
            app.staticTexts["FULL SELF-DRIVING"].waitForExistence(timeout: 10),
            "tapping a drive row must push its Drive Summary"
        )
        return app
    }

    // MARK: The client's own surface

    /// The capture his photo corresponds to: the celebration fully settled
    /// (2.7s delay + 1.4s fade) on the real navigation path. Three shots so the
    /// PR can show the wash arriving, not just its end state.
    func testFullFSDDriveSummaryAcrossTheCelebration() {
        _ = openDrive(Self.fullFSDRow)

        attach(named: "myr339-100pct-t0-before-celebration")
        Thread.sleep(forTimeInterval: 3.0)
        attach(named: "myr339-100pct-t3-mid-fade")
        Thread.sleep(forTimeInterval: 3.0)
        attach(named: "myr339-100pct-t6-settled")
    }

    /// The control the pair is read against. A 97% drive never sets `goldMode`,
    /// so this screen has no celebration layer at all and must be unchanged by
    /// this issue.
    func testPartialFSDDriveSummaryStaysUncelebrated() {
        _ = openDrive(Self.partialFSDRow)
        Thread.sleep(forTimeInterval: 6.0)
        attach(named: "myr339-97pct-t6-no-celebration")
    }
}
