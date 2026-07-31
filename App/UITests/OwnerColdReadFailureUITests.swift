import XCTest

// MARK: - MYR-387 — the honest end state has to be REACHABLE
//
// The defect this guards is not a wrong value; it is a branch that could not be
// entered. MYR-326 built owner Home's cold-read failure state, tested it four
// ways at fleet level, and `HomeScreen` never rendered it: the content branch
// needed only a vehicle ROW, and the fleet LIST — the fast call — had succeeded.
// So every assertion about `ColdSnapshotLoad` stayed green while the product
// showed a black skeleton and then a map on Null Island.
//
// **A pure test cannot catch that class of bug**, which is the whole reason this
// file exists: `OwnerColdLaunchHonestyTests` proves the RULE, and only a real
// launch proves the rule is what the screen consults. Same lesson as MYR-369's
// `VehicleRideShare.display` — a pure function with good tests and no live call
// site is the quietest regression available.
final class OwnerColdReadFailureUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(scene: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MRT_SCENE"] = scene
        app.launch()
        return app
    }

    /// **THE BRANCH IS REACHABLE.** The retries are spent and the screen says so,
    /// naming the car the list told it about — instead of a sheet and a map built
    /// on a snapshot that does not exist.
    func testTheRetriesExhaustedStateRendersItsHonestLine() {
        let app = launch(scene: "ownerColdReadFailed")
        let line = app.staticTexts["Can\u{2019}t reach Lunar right now"]
        XCTAssertTrue(
            line.waitForExistence(timeout: 20),
            "owner Home never rendered the cold-read failure state it publishes"
        )
    }

    /// …and it carries a way out. A client who asks *"Nothing loading, what
    /// happened?"* needs the answer where the question is asked.
    func testTheHonestStateOffersARetryTheOwnerCanReach() {
        let app = launch(scene: "ownerColdReadFailed")
        let retry = app.buttons["ownerHomeRetry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 20), "the honest state must offer a retry")
        XCTAssertTrue(retry.isHittable, "a retry nobody can tap is not an affordance")

        // The 44pt hard rule, asserted on the frame the SYSTEM reports — the
        // MYR-345 lesson that a `contentShape` inset is not a tap target.
        XCTAssertGreaterThanOrEqual(retry.frame.height, 44 - 0.5, "min tap target is 44pt")

        // And it is live: tapping must not crash or leave the screen stranded.
        retry.tap()
        XCTAssertTrue(app.staticTexts["Can\u{2019}t reach Lunar right now"].waitForExistence(timeout: 10))
    }

    /// **NO SHIMMER OVER A SETTLED FAILURE.** The banned state is a skeleton that
    /// never resolves; the guard is that the failure surface carries none of the
    /// loading surface's placeholder furniture.
    func testTheHonestStateIsNotASkeleton() {
        let app = launch(scene: "ownerColdReadFailed")
        XCTAssertTrue(app.staticTexts["Can\u{2019}t reach Lunar right now"].waitForExistence(timeout: 20))
        XCTAssertFalse(
            app.descendants(matching: .any)["Loading your vehicles"].exists,
            "a shimmering placeholder over a settled failure is the eternal skeleton"
        )
    }

    /// The paired LOADING scene must keep shimmering and must NOT grow a retry —
    /// something is genuinely in flight behind it. This is the regression guard on
    /// the other side of `OwnerHomePresentation`'s precedence.
    func testTheLoadingSceneStillShimmersAndOffersNoRetry() {
        let app = launch(scene: "ownerConnecting")
        // The switcher chip is real as soon as the list lands — the client's own
        // state, and what tells this scene apart from `ownerConnectingCold`.
        XCTAssertTrue(app.staticTexts["Lunar"].waitForExistence(timeout: 20))
        XCTAssertFalse(
            app.buttons["ownerHomeRetry"].exists,
            "a retry button over an in-flight fetch offers to restart what is already running"
        )
    }
}
